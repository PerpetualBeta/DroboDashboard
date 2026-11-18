// DroboDext implementation on Apple's SCSIPeripheralsDriverKit. Pairs with
// DroboDext.iig; the iig-generated files carry the metaclass registration and
// the RPC dispatch. The subclass implements the framework's pure virtuals and
// exposes a user client with three selectors:
//
//   0  SendCDB      one vendor CDB; reads (2) need no session, writes (1)
//                   and no-data (0) carry the vendor system ops (0xEA)
//   1  Suspend      UserSuspendServices: exclusive access for vendor
//                   opcodes (0xEA); the volume must be unmounted first
//   2  Resume       UserResumeServices: release + remount
//
// The v0.1 survey surface is MODE SENSE reads, which we attempt WITHOUT the
// suspend session first; the eject dance becomes explicit only for 0xEA ops.

#include "DroboDext.h"
#include <DriverKit/IOLib.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/OSData.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <SCSIPeripheralsDriverKit/IOUserSCSIPeripheralDeviceType00.h>
#include <SCSIPeripheralsDriverKit/IOUserSCSIPeripheralDeviceHelper.h>

// IOLog from the dext routes into the kernel log tagged with subsystem
// cc.jorvik.drobodext.dext, but privacy-masked. Unmask once with:
//   sudo log config --subsystem cc.jorvik.drobodext.dext --mode "private_data:on"
#define dlog(...) IOLog("DroboDext: " __VA_ARGS__)

#define super IOUserSCSIPeripheralDeviceType00

// The input struct: three u32s, then the CDB bytes.
struct SendCDBInput {
    uint32_t cdbLength;
    uint32_t direction;      // 2 = read (target to initiator), 1 = write
    uint32_t dataLength;     // expected transfer size
    uint8_t  cdb[16];
};

// ExternalMethod selectors.
static const uint64_t kSelectorSendCDB = 0;
static const uint64_t kSelectorSuspend = 1;
static const uint64_t kSelectorResume  = 2;
static const uint64_t kSelectorBlink   = 3;   // the USB probe's raw-BOT identify

struct DroboDextDriver_IVars {
    DroboUserClient* fClient;
};

struct DroboUserClient_IVars {
    DroboDextDriver* fDriver;
    DroboUSBProbe*   fProbe;    // set when the client opens on the USB probe node
};

// MARK: - Driver

bool DroboDextDriver::init()
{
    if (!IOUserSCSIPeripheralDeviceType00::init()) return false;
    ivars = IONewZero(DroboDextDriver_IVars, 1);
    return ivars != nullptr;
}

void DroboDextDriver::free()
{
    IOSafeDeleteNULL(ivars, DroboDextDriver_IVars, 1);
    IOUserSCSIPeripheralDeviceType00::free();
}

kern_return_t IMPL(DroboDextDriver, UserDetermineDeviceCharacteristics)
{
    // Enumeration-time hook. Nothing special to declare for the Drobo's
    // LUN: block limits stay at the framework defaults.
    *result = true;
    return kIOReturnSuccess;
}

kern_return_t IMPL(DroboDextDriver, Start)
{
    // The framework's node is left unregistered (the storage stack consumes
    // it internally), so clients can never match it. Chain to the framework,
    // then publish this service for client matching and user-client opens.
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        dlog("framework Start failed 0x%x", ret);
        return ret;
    }
    ret = RegisterService();
    dlog("RegisterService -> 0x%x", ret);
    return ret;
}

kern_return_t IMPL(DroboDextDriver, NewUserClient)
{
    IOService* ucService = nullptr;
    // Instantiates DroboUserClient from the "UserClientProperties" dict in
    // Info.plist.
    kern_return_t ret = Create(this, "UserClientProperties", &ucService);
    if (ret != kIOReturnSuccess || ucService == nullptr) {
        dlog("user client Create failed 0x%x", ret);
        return (ret != kIOReturnSuccess) ? ret : kIOReturnError;
    }
    *userClient = OSDynamicCast(IOUserClient, ucService);
    if (*userClient == nullptr) {
        ucService->release();
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

// MARK: - User client

bool DroboUserClient::init()
{
    if (!IOUserClient::init()) return false;
    ivars = IONewZero(DroboUserClient_IVars, 1);
    return ivars != nullptr;
}

void DroboUserClient::free()
{
    IOSafeDeleteNULL(ivars, DroboUserClient_IVars, 1);
    IOUserClient::free();
}

kern_return_t IMPL(DroboUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;
    // The client opens on EITHER the SCSI driver node (the LUN) or the
    // USB probe node (the interface). v20: the probe path carries the
    // blink; the SCSI path carries the survey + the exclusive session.
    ivars->fDriver = OSDynamicCast(DroboDextDriver, provider);
    ivars->fProbe  = OSDynamicCast(DroboUSBProbe, provider);
    if (ivars->fDriver == nullptr && ivars->fProbe == nullptr) return kIOReturnBadArgument;
    if (ivars->fDriver) ivars->fDriver->retain();
    if (ivars->fProbe)  ivars->fProbe->retain();
    return kIOReturnSuccess;
}

kern_return_t IMPL(DroboUserClient, Stop)
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->fDriver);
        OSSafeReleaseNULL(ivars->fProbe);
    }
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t DroboUserClient::ExternalMethod(uint64_t selector,
                                              IOUserClientMethodArguments* arguments,
                                              const IOUserClientMethodDispatch* dispatch,
                                              OSObject* target, void* reference)
{
    dlog("ExternalMethod selector %llu", selector);

    if (ivars == nullptr) {
        dlog("reject: no ivars");
        return kIOReturnNotOpen;
    }

    // v20: the blink over the dext's own USB BOT pipes. Input: u32 sequence.
    // Output: three u32s — the pipe kr, the CSW status (0 = GOOD), residue.
    if (selector == kSelectorBlink) {
        if (ivars->fProbe == nullptr) return kIOReturnNotOpen;
        uint32_t seq = 1;
        OSData* input = arguments->structureInput;
        if (input != nullptr && input->getLength() >= sizeof(uint32_t)) {
            seq = *reinterpret_cast<const uint32_t*>(input->getBytesNoCopy());
        }
        uint32_t krOut = 0, csw = 0xFFFFFFFF, residue = 0;
        ivars->fProbe->Blink(seq, &krOut, &csw, &residue);
        uint32_t out[3] = {krOut, csw, residue};
        arguments->structureOutput = OSData::withBytes(out, sizeof(out));
        return kIOReturnSuccess;
    }

    if (ivars->fDriver == nullptr) {
        dlog("reject: no driver ivars");
        return kIOReturnNotOpen;
    }

    // Session selectors: the exclusive-access dance, one call each.
    if (selector == kSelectorSuspend) return ivars->fDriver->UserSuspendServices();
    if (selector == kSelectorResume)  return ivars->fDriver->UserResumeServices();

    if (selector != kSelectorSendCDB) {
        return kIOReturnUnsupported;
    }

    OSData* input = arguments->structureInput;
    dlog("ExternalMethod: input len %u, outputMax %llu",
         input ? (uint32_t)input->getLength() : 0,
         arguments->structureOutputMaximumSize);
    if (input == nullptr || input->getLength() < sizeof(SendCDBInput)) {
        return kIOReturnBadArgument;
    }
    const SendCDBInput* request =
        reinterpret_cast<const SendCDBInput*>(input->getBytesNoCopy());
    if (request->cdbLength == 0 || request->cdbLength > 16) {
        return kIOReturnBadArgument;
    }
    if (request->direction > 2) {
        return kIOReturnUnsupported;
    }
    if (request->direction != 2) {
        // v0.2: write (1) and no-data (0) pass through for the vendor
        // system operations (0xEA identify et al). Reads (2) stay the
        // survey path. The write payload, when present, follows the CDB
        // in the input struct.
    }
    if (request->dataLength > 0 && request->direction == 2) {
        // reads declare an allocation length; nothing extra to validate
    }
    const uint32_t inputHeader = sizeof(SendCDBInput);
    const uint32_t payloadLength =
        (request->direction == 1) ? request->dataLength : 0;
    if (request->direction == 1) {
        // A write must carry its payload inline.
        if (input == nullptr || input->getLength() < inputHeader + payloadLength) {
            return kIOReturnBadArgument;
        }
    }
    // struct-method output: structureOutput arrives NULL and the driver
    // CREATES the OSData to return (the OS releases it). Respect the
    // caller's declared maximum.
    uint64_t outputMax = arguments->structureOutputMaximumSize;
    if (outputMax != kIOUserClientVariableStructureSize &&
        request->dataLength > outputMax) {
        return kIOReturnBadArgument;
    }

    // Data + sense buffers for the framework. Reads allocate an IN buffer
    // the target fills; writes allocate an OUT buffer prefilled from the
    // caller's payload (LOCALONLY buffers are directly dereferenceable);
    // no-data ops allocate a 1-byte placeholder.
    IOBufferMemoryDescriptor* dataBuffer = nullptr;
    uint8_t senseBuffer[22] = {0};
    const uint32_t bufferLength = request->dataLength ? request->dataLength : 1;
    const bool isWrite = (request->direction == 1);
    const bool isRead = (request->direction == 2);
    kern_return_t kr = IOBufferMemoryDescriptor::Create(
        isWrite ? kIOMemoryDirectionOut : kIOMemoryDirectionIn,
        bufferLength, 0, &dataBuffer);
    if (kr != kIOReturnSuccess) return kr;

    if (isWrite && payloadLength > 0) {
        const uint8_t* payload =
            reinterpret_cast<const uint8_t*>(input->getBytesNoCopy()) + inputHeader;
        void* dest = nullptr;
        IOAddressSegment range;
        if (dataBuffer->GetAddressRange(&range) == kIOReturnSuccess) {
            dest = reinterpret_cast<void*>(range.address);
            memcpy(dest, payload, payloadLength);
            kr = kIOReturnSuccess;
        } else {
            dataBuffer->release();
            return kIOReturnError;
        }
    }

    SCSIType00OutParameters out = {};
    out.fLogicalUnitNumber = 0;
    out.fTimeoutDuration = 30000;
    SetCommandCDB(&out.fCommandDescriptorBlock,
                  request->cdb[0], request->cdb[1], request->cdb[2], request->cdb[3],
                  request->cdb[4], request->cdb[5], request->cdb[6], request->cdb[7],
                  request->cdb[8], request->cdb[9], request->cdb[10], request->cdb[11],
                  request->cdb[12], request->cdb[13], request->cdb[14], request->cdb[15]);
    out.fRequestedByteCountOfTransfer = request->dataLength;
    out.fBufferDirection = isWrite ? kIOMemoryDirectionOut : kIOMemoryDirectionIn;
    out.fDataTransferDirection = isWrite
        ? kSCSIDataTransfer_FromInitiatorToTarget
        : (isRead ? kSCSIDataTransfer_FromTargetToInitiator
                  : kSCSIDataTransfer_NoDataTransfer);
    out.fSenseLengthRequested = 18;   // fixed-format sense
    IOAddressSegment range;
    if (dataBuffer->GetAddressRange(&range) == kIOReturnSuccess) {
        out.fDataBufferAddr = range.address;
        dlog("buffer addr 0x%llx for %u bytes", range.address, request->dataLength);
    } else {
        dlog("GetAddressRange failed");
    }
    out.fSenseBufferAddr = reinterpret_cast<uint64_t>(senseBuffer);

    SCSIType00InParameters in = {};
    kr = ivars->fDriver->UserSendCDB(out, &in);
    dlog("UserSendCDB returned 0x%x status %u realized %llu",
         kr, in.fCompletionStatus, in.fRealizedByteCountOfTransfer);

    uint64_t transferred = 0;
    if (kr == kIOReturnSuccess) {
        transferred = in.fRealizedByteCountOfTransfer;
        if (transferred > request->dataLength) transferred = request->dataLength;
        if (transferred > 0) {
            // DriverKit buffers are allocated in-process: GetAddressRange
            // (LOCALONLY) yields a directly dereferenceable address.
            void* data = nullptr;
            if (dataBuffer->GetAddressRange(&range) == kIOReturnSuccess) {
                data = reinterpret_cast<void*>(range.address);
                OSData* result = OSData::withBytes(data, transferred);
                if (result != nullptr) {
                    // Ownership passes to the OS: it is returned to the
                    // caller and released there.
                    arguments->structureOutput = result;
                } else {
                    kr = kIOReturnNoMemory;
                }
            } else {
                kr = kIOReturnError;
            }
        }
    }
    dataBuffer->release();

    // v12: append a fixed result trailer so the client sees what the
    // DEVICE said, not just that the transport worked: u32 magic, u32
    // completion status, u32 realized, u8 sense length, 22 bytes of
    // sense. The magic makes the trailer unambiguous for a client that
    // may also talk to a pre-v12 dext (whose whole output is data).
    {
        uint8_t trailer[4 + 4 + 4 + 1 + 22] = {0};
        const uint32_t magic = 0x44443132;   // 'DD12'
        uint32_t completion = in.fCompletionStatus;
        // The trailer's realized field is u32; every survey/vendor transfer
        // here is far below 4 GiB, so the narrowing is intentional.
        uint32_t realizedCount = (uint32_t)in.fRealizedByteCountOfTransfer;
        memcpy(trailer, &magic, 4);
        memcpy(trailer + 4, &completion, 4);
        memcpy(trailer + 8, &realizedCount, 4);
        trailer[12] = (uint8_t)sizeof(senseBuffer);
        memcpy(trailer + 13, senseBuffer, sizeof(senseBuffer));
        if (arguments->structureOutput != nullptr) {
            arguments->structureOutput->appendBytes(trailer, sizeof(trailer));
        } else {
            // No data phase output: the trailer IS the output.
            arguments->structureOutput = OSData::withBytes(trailer, sizeof(trailer));
        }
    }

    if (kr != kIOReturnSuccess) {
        dlog("UserSendCDB failed 0x%x (status %u, transferred %llu)",
              kr, in.fCompletionStatus, transferred);
    }
    return kr;
}
