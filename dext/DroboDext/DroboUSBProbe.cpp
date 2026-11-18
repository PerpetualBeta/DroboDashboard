/*
 * DroboUSBProbe v20: THE BLINK, over the dext's OWN USB BOT pipes.
 *
 * v18 proved the takeover: this personality instantiates under the Drobo's
 * IOUSBHostInterface (the entitlement must mirror the profile grant exactly:
 * [{'idVendor': '*'}]). v20 adds the payload: CopyPipe the bulk pair and run
 * the mined identify (vendor 0xEA op 0x06, ONE zero byte) as a raw BOT
 * transaction — CBW out, data out, CSW in — using the pipe's SYNCHRONOUS IO.
 * Apple's SCSI stack never sees the CDB, so its vendor-opcode refusal cannot
 * touch this path.
 *
 * The user client (DroboUserClient, selector 3) calls Blink() in-process and
 * returns the CSW verdict to the CLI. dext logging is invisible (IOLog AND
 * os_log both vanish), so the user client is the report channel.
 *
 * Safety: the CLI ejects first and settles 3 s so the kernel's attach probes
 * are done; the volume is clean before any raw traffic touches the wire.
 */

#include "DroboUSBProbe.h"
#include <DriverKit/IOLib.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <USBDriverKit/IOUSBHostPipe.h>

struct DroboUSBProbe_IVars {
    IOUSBHostPipe* pipeOut;
    IOUSBHostPipe* pipeIn;
    // v21: the auto-blink result, readable through the user client.
    uint32_t lastKr;
    uint32_t lastCsw;
    uint32_t lastResidue;
    bool hasBlinked;
};

bool DroboUSBProbe::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(DroboUSBProbe_IVars, 1);
    if (ivars == nullptr) return false;
    ivars->lastCsw = 0xFFFFFFFF;
    // v23: the probe is a PURE DISPLACER. It matches the interface with a
    // high probe score so the kernel's IOUSBMassStorageDriver lets go, and
    // it does NOT open the interface or do any IO itself. That leaves the
    // wire claimable from user space (the libusb BOT tool), which sends the
    // blink and reports the CSW cleanly. No auto-blink here.
    return true;
}

void DroboUSBProbe::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->pipeOut);
        OSSafeReleaseNULL(ivars->pipeIn);
        IOSafeDeleteNULL(ivars, DroboUSBProbe_IVars, 1);
    }
    super::free();
}

// One synchronous bulk transfer. Returns the pipe's kern_return_t; on
// success *transferred holds the byte count. The buffer is filled (out)
// or read (in) through GetAddressRange — LOCALONLY dext buffers are
// directly dereferenceable (the established v12 pattern).
static kern_return_t pipeIO(IOUSBHostPipe* pipe, bool isIn,
                            const void* bytes, uint32_t length,
                            void* readBack, uint32_t* transferred)
{
    IOBufferMemoryDescriptor* md = nullptr;
    kern_return_t kr = IOBufferMemoryDescriptor::Create(
        isIn ? kIOMemoryDirectionIn : kIOMemoryDirectionOut,
        length, 0, &md);
    if (kr != kIOReturnSuccess) return kr;

    IOAddressSegment range;
    if (md->GetAddressRange(&range) != kIOReturnSuccess) {
        md->release();
        return kIOReturnError;
    }
    if (!isIn && bytes != nullptr) {
        memcpy(reinterpret_cast<void*>(range.address), bytes, length);
    }
    kr = pipe->IO(md, length, transferred, 5000);
    if (kr == kIOReturnSuccess && isIn && readBack != nullptr) {
        memcpy(readBack, reinterpret_cast<void*>(range.address),
               *transferred < length ? *transferred : length);
    }
    md->release();
    return kr;
}

kern_return_t IMPL(DroboUSBProbe, Blink)
{
    *krOut = 0;
    *cswStatus = 0xFFFFFFFF;   // no valid CSW yet
    *residue = 0;

    // The bulk pair, measured by the libusb probe: OUT 0x01, IN 0x82.
    if (ivars->pipeOut == nullptr) {
        kern_return_t kr = CopyPipe(0x01, &ivars->pipeOut);
        if (kr != kIOReturnSuccess) { *krOut = (uint32_t)kr; return kr; }
    }
    if (ivars->pipeIn == nullptr) {
        kern_return_t kr = CopyPipe(0x82, &ivars->pipeIn);
        if (kr != kIOReturnSuccess) { *krOut = (uint32_t)kr; return kr; }
    }

    // CBW: 'USBC', tag 1, one byte out, LUN 0, the mined 10-byte CDB.
    uint8_t cbw[31] = {0};
    cbw[0] = 'U'; cbw[1] = 'S'; cbw[2] = 'B'; cbw[3] = 'C';
    cbw[4] = 1;                          // tag
    cbw[8] = 1;                          // dCBWDataTransferLength = 1
    cbw[12] = 0x00;                      // flags: data OUT
    cbw[13] = 0;                         // LUN 0
    cbw[14] = 10;                        // CDB length
    cbw[15] = 0xEA; cbw[16] = 0x10; cbw[17] = 0x00; cbw[18] = 0x06;
    cbw[19] = (uint8_t)sequence; cbw[20] = 0x00; cbw[21] = 0x21;
    cbw[22] = 0x00; cbw[23] = 0x01; cbw[24] = 0x00;

    uint32_t transferred = 0;
    kern_return_t kr = pipeIO(ivars->pipeOut, false, cbw, 31, nullptr, &transferred);
    if (kr != kIOReturnSuccess) { *krOut = (uint32_t)kr; return kr; }

    // The payload: one zero byte (the mined identify shape).
    uint8_t zero = 0x00;
    kr = pipeIO(ivars->pipeOut, false, &zero, 1, nullptr, &transferred);
    if (kr != kIOReturnSuccess) { *krOut = (uint32_t)kr; return kr; }

    // CSW: 'USBS', tag, residue, status.
    uint8_t csw[13] = {0};
    kr = pipeIO(ivars->pipeIn, true, nullptr, 13, csw, &transferred);
    if (kr != kIOReturnSuccess) { *krOut = (uint32_t)kr; return kr; }
    if (transferred != 13 || csw[0] != 'U' || csw[1] != 'S' ||
        csw[2] != 'B' || csw[3] != 'S') {
        *krOut = (uint32_t)kIOReturnIOError;
        return kIOReturnIOError;
    }
    *residue = (uint32_t)csw[8] | ((uint32_t)csw[9] << 8) |
               ((uint32_t)csw[10] << 16) | ((uint32_t)csw[11] << 24);
    *cswStatus = csw[12];
    return kIOReturnSuccess;
}
