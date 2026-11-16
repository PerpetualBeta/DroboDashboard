// DroboDext implementation on Apple's SCSIPeripheralsDriverKit. Pairs with
// DroboDext.iig; the iig-generated files carry the metaclass registration and
// the RPC dispatch. The subclass implements the framework's pure virtuals and
// exposes a user client with three selectors:
//
//   0  SendCDB      one vendor CDB (reads in v0.1); needs no session for
//                   standard opcodes like MODE SENSE(10) 0x5A
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

struct DroboDextDriver_IVars {
    DroboUserClient* fClient;
};

struct DroboUserClient_IVars {
    DroboDextDriver* fDriver;
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
    ivars->fDriver = OSDynamicCast(DroboDextDriver, provider);
    if (ivars->fDriver == nullptr) return kIOReturnBadArgument;
    ivars->fDriver->retain();
    return kIOReturnSuccess;
}

kern_return_t IMPL(DroboUserClient, Stop)
{
    if (ivars) OSSafeReleaseNULL(ivars->fDriver);
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t DroboUserClient::ExternalMethod(uint64_t selector,
                                              IOUserClientMethodArguments* arguments,
                                              const IOUserClientMethodDispatch* dispatch,
                                              OSObject* target, void* reference)
{
    dlog("ExternalMethod selector %llu", selector);

    if (ivars == nullptr || ivars->fDriver == nullptr) {
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
    if (request->direction != 2) {
        // v0.1 is read-only; the whole survey surface is MODE SENSE reads.
        return kIOReturnUnsupported;
    }
    // struct-method output: structureOutput arrives NULL and the driver
    // CREATES the OSData to return (the OS releases it). Respect the
    // caller's declared maximum.
    uint64_t outputMax = arguments->structureOutputMaximumSize;
    if (outputMax != kIOUserClientVariableStructureSize &&
        request->dataLength > outputMax) {
        return kIOReturnBadArgument;
    }

    // Data + sense buffers for the framework.
    IOBufferMemoryDescriptor* dataBuffer = nullptr;
    uint8_t senseBuffer[22] = {0};
    kern_return_t kr = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionIn, request->dataLength ? request->dataLength : 1, 0, &dataBuffer);
    if (kr != kIOReturnSuccess) return kr;

    SCSIType00OutParameters out = {};
    out.fLogicalUnitNumber = 0;
    out.fTimeoutDuration = 30000;
    SetCommandCDB(&out.fCommandDescriptorBlock,
                  request->cdb[0], request->cdb[1], request->cdb[2], request->cdb[3],
                  request->cdb[4], request->cdb[5], request->cdb[6], request->cdb[7],
                  request->cdb[8], request->cdb[9], request->cdb[10], request->cdb[11],
                  request->cdb[12], request->cdb[13], request->cdb[14], request->cdb[15]);
    out.fRequestedByteCountOfTransfer = request->dataLength;
    out.fBufferDirection = kIOMemoryDirectionIn;
    out.fDataTransferDirection = kSCSIDataTransfer_FromTargetToInitiator;
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

    if (kr != kIOReturnSuccess) {
        dlog("UserSendCDB failed 0x%x (status %u, transferred %llu)",
              kr, in.fCompletionStatus, transferred);
    }
    return kr;
}
