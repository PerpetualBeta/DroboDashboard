// DroboDext main driver: a DriverKit USB driver that claims the Drobo's
// mass-storage interface and offers a pass-through user client, because both
// user-space transports are dead on macOS 27 (measured 2026-11-16):
// - IOCreatePlugInInterfaceForService(kIOSCSITaskDeviceUserClientTypeID)
//   returns kIOReturnUnsupported: Apple's SCSITaskUserClient matches only the
//   old IOSCSIPeripheralDeviceNub, which the new IOUSBMassStorageDriver stack
//   never creates.
// - libusb interface claims fail with LIBUSB_ERROR_ACCESS even unmounted.
//
// The 5D3 is USB end to end: its Thunderbolt ports just tunnel USB, so this
// one driver covers all three physical ports.
//
// NOTE: written against the published USBDriverKit API. It compiles once the
// standalone DriverKit SDK (USBDriverKit.framework headers) is in place; see
// dext/Makefile.

#include <DriverKit/IOService.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOUserClient.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <USBDriverKit/IOUserUSBHostInterface.h>
#include <USBDriverKit/IOUserUSBHostRequest.h>

#include "DroboDext.h"

#define super IOService
OSDefineMetaclassAndStructors(DroboDextDriver, IOService)

// The device: VID 0x19B9 PID 0x3533, interface 0, BOT, bulk OUT 0x01 / IN 0x81.
static const UInt16 kDroboVendorID  = 0x19B9;
static const UInt16 kDroboProductID = 0x3533;

bool DroboDextDriver::init(void)
{
    if (!super::init()) return false;
    fInterface = nullptr;
    return true;
}

void DroboDextDriver::free(void)
{
    OSSafeReleaseNULL(fInterface);
    super::free();
}

bool DroboDextDriver::Start(IOService* provider)
{
    if (!super::Start(provider)) return false;

    // The personality matched the kernel IOUSBHostInterface. Ask the family
    // for the user-side interface object that runs in this dext.
    kern_return_t kr = IOUserUSBHostInterface::Create(
        this, provider->getRegistryEntryID(), &fInterface);
    if (kr != kIOReturnSuccess || fInterface == nullptr) {
        IOLog("DroboDext: IOUserUSBHostInterface::Create failed 0x%x\n", kr);
        Stop(provider);
        return false;
    }

    // Take the interface from the kernel mass-storage driver: exclusive by
    // definition in DriverKit, the personality's probe score decides.
    kr = fInterface->Open(this, 0);
    if (kr != kIOReturnSuccess) {
        IOLog("DroboDext: interface open failed 0x%x\n", kr);
        Stop(provider);
        return false;
    }

    IOLog("DroboDext: interface claimed\n");
    RegisterService();
    return true;
}

void DroboDextDriver::Stop(IOService* provider)
{
    if (fInterface != nullptr) {
        fInterface->Close(this, 0);
        OSSafeReleaseNULL(fInterface);
    }
    super::Stop(provider);
}

kern_return_t IMPL(DroboDextDriver, NewUserClient)
{
    IOService* client;
    kern_return_t kr = Create(this, "UserClient", type, reinterpret_cast<IOUserClient**>(&client));
    if (kr != kIOReturnSuccess) return kr;
    *userClient = OSDynamicCast(IOUserClient, client);
    if (*userClient == nullptr) {
        client->release();
        return kIOReturnUnsupported;
    }
    return kIOReturnSuccess;
}

// MARK: - User client

#define super IOUserClient
OSDefineMetaclassAndStructors(DroboUserClient, IOUserClient)

bool DroboUserClient::init(void)
{
    if (!super::init()) return false;
    fDriver = nullptr;
    return true;
}

void DroboUserClient::free(void)
{
    OSSafeReleaseNULL(fDriver);
    super::free();
}

bool DroboUserClient::Start(IOService* provider)
{
    fDriver = OSDynamicCast(DroboDextDriver, provider);
    if (fDriver == nullptr) return false;
    fDriver->retain();
    return super::Start(provider);
}

kern_return_t IMPL(DroboUserClient, SendCDB)
{
    // One vendor CDB through BOT. The data buffer direction follows the CDB:
    // reads fill the buffer, writes consume it, zero-length commands pass
    // through with no data stage.
    if (cdbIn == nullptr || cdbInSize == 0 || cdbInSize > 16) {
        return kIOReturnBadArgument;
    }
    return fDriver->PassThrough(cdbIn, cdbInSize, data, dataLength, direction, transferredOut);
}
