// User-space pass-through over Apple's SCSI task layer (SCSITaskDeviceInterface).
// This is the primary transport: it needs no kext and no security-policy change,
// but it needs exclusive access, which means the device must be ejected first.
//
// Matching and opening follow the classic SCSI architecture family flow:
// find the IOSCSIPeripheralDeviceNub behind the BSD name, create the
// kIOSCSITaskDeviceUserClientTypeID plug-in, obtain exclusive access, then
// run one synchronous task per CDB.

#include "ddtransport.h"

#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <IOKit/IOBSD.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <pthread.h>

extern const char *dd_last_error(void);
extern void dd_set_error(const char *fmt, ...);

struct ddus_session {
    IOCFPlugInInterface **plugIn;
    SCSITaskDeviceInterface **taskDevice;
    io_service_t nub;
};

/* Walk up from an IOMedia to its IOSCSIPeripheralDeviceNub. */
static io_service_t nub_for_bsd_name(const char *bsdName)
{
    CFMutableDictionaryRef match = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName);
    if (!match) return IO_OBJECT_NULL;
    io_service_t media = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!media) return IO_OBJECT_NULL;

    io_service_t candidate = media;
    io_service_t nub = IO_OBJECT_NULL;
    for (int depth = 0; depth < 6 && candidate; depth++) {
        io_name_t className;
        if (IOObjectGetClass(candidate, className) != KERN_SUCCESS) break;
        if (strcmp(className, "IOSCSIPeripheralDeviceNub") == 0) {
            nub = candidate;
            IOObjectRetain(nub);
            break;
        }
        io_service_t parent = IO_OBJECT_NULL;
        if (IORegistryEntryGetParentEntry(candidate, kIOServicePlane, &parent) != KERN_SUCCESS) break;
        IOObjectRelease(candidate);
        candidate = parent;
    }
    if (candidate && candidate != nub) IOObjectRelease(candidate);
    IOObjectRelease(media);
    return nub;
}

int ddus_count_drobo_nubs(void)
{
    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    if (!match) {
        dd_set_error("IOServiceMatching(IOSCSIPeripheralDeviceNub) returned NULL");
        return -1;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator);
    if (kr != KERN_SUCCESS) {
        dd_set_error("IOServiceGetMatchingServices: 0x%x", kr);
        return -1;
    }
    int count = 0;
    io_service_t nub;
    while ((nub = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFTypeRef vendor = IORegistryEntrySearchCFProperty(
            nub, kIOServicePlane, CFSTR("Vendor Identification"), NULL,
            kIORegistryIterateRecursively | kIORegistryIterateParents);
        if (vendor && CFGetTypeID(vendor) == CFStringGetTypeID()) {
            char buf[64] = {0};
            CFStringGetCString(vendor, buf, sizeof(buf), kCFStringEncodingUTF8);
            if (strcasestr(buf, "drobo")) count++;
        }
        if (vendor) CFRelease(vendor);
        IOObjectRelease(nub);
    }
    IOObjectRelease(iterator);
    return count;
}

/* One open routine shared by the BSD-name and nub-match entry points. */
static int open_nub(io_service_t nub, ddus_session **out)
{
    *out = NULL;
    if (!nub) {
        dd_set_error("open_nub: no nub");
        return -1;
    }

    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        nub, kIOSCSITaskDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
        &plugIn, &score);
    if (kr != KERN_SUCCESS || !plugIn) {
        dd_set_error("IOCreatePlugInInterfaceForService: 0x%x", kr);
        IOObjectRelease(nub);
        return -1;
    }

    SCSITaskDeviceInterface **taskDevice = NULL;
    HRESULT hr = (*plugIn)->QueryInterface(
        plugIn, CFUUIDGetUUIDBytes(kSCSITaskDeviceInterfaceID),
        (LPVOID *)&taskDevice);
    (*plugIn)->Release(plugIn);
    if (hr != S_OK || !taskDevice) {
        dd_set_error("QueryInterface(kSCSITaskDeviceInterfaceID): 0x%lx", (unsigned long)hr);
        IOObjectRelease(nub);
        return -1;
    }

    IOReturn rc = (*taskDevice)->ObtainExclusiveAccess(taskDevice);
    if (rc != kIOReturnSuccess) {
        dd_set_error("ObtainExclusiveAccess: 0x%x (is the volume still mounted?)", rc);
        (*taskDevice)->Release(taskDevice);
        IOObjectRelease(nub);
        return -1;
    }

    ddus_session *s = calloc(1, sizeof(*s));
    s->plugIn = NULL;
    s->taskDevice = taskDevice;
    s->nub = nub;
    *out = s;
    return 0;
}

int ddus_open_bsd_name(const char *bsdName, ddus_session **out)
{
    io_service_t nub = nub_for_bsd_name(bsdName);
    if (!nub) {
        dd_set_error("no IOSCSIPeripheralDeviceNub behind %s", bsdName);
        return -1;
    }
    return open_nub(nub, out);
}

/* Open the first Drobo peripheral nub by vendor match. This is the path a
 * management session uses after `diskutil eject`: the whole-device eject
 * destroys the BSD name, but the peripheral nub survives it. */
int ddus_open_first_drobo_nub(ddus_session **out)
{
    *out = NULL;
    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    if (!match) {
        dd_set_error("IOServiceMatching(IOSCSIPeripheralDeviceNub) returned NULL");
        return -1;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator);
    if (kr != KERN_SUCCESS) {
        dd_set_error("IOServiceGetMatchingServices: 0x%x", kr);
        return -1;
    }
    io_service_t nub = IO_OBJECT_NULL;
    io_service_t found = IO_OBJECT_NULL;
    while ((nub = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFTypeRef vendor = IORegistryEntrySearchCFProperty(
            nub, kIOServicePlane, CFSTR("Vendor Identification"), NULL,
            kIORegistryIterateRecursively | kIORegistryIterateParents);
        if (vendor && CFGetTypeID(vendor) == CFStringGetTypeID()) {
            char buf[64] = {0};
            CFStringGetCString(vendor, buf, sizeof(buf), kCFStringEncodingUTF8);
            if (strcasestr(buf, "drobo")) {
                found = nub;   /* retain lives on: open_nub releases it */
            }
        }
        if (vendor) CFRelease(vendor);
        if (found) break;
        IOObjectRelease(nub);
    }
    IOObjectRelease(iterator);
    if (!found) {
        dd_set_error("no Drobo peripheral nub found");
        return -1;
    }
    return open_nub(found, out);
}

int ddus_send(ddus_session *s, const unsigned char *cdb, int cdbLen,
              unsigned char *buf, unsigned int bufLen, int direction,
              unsigned int *transferred,
              unsigned char *senseOut, unsigned int *senseLen)
{
    if (!s || !cdb || cdbLen <= 0 || cdbLen > 32 || !transferred) {
        dd_set_error("ddus_send: bad arguments");
        return -1;
    }
    *transferred = 0;

    IOReturn rc = kIOReturnSuccess;
    SCSITaskInterface **task = (*s->taskDevice)->CreateSCSITask(s->taskDevice);
    if (!task) {
        dd_set_error("CreateSCSITask returned NULL");
        return -1;
    }

    rc = (*task)->SetCommandDescriptorBlock(task, (UInt8 *)cdb, (UInt8)cdbLen);
    if (rc != kIOReturnSuccess) {
        dd_set_error("SetCommandDescriptorBlock: 0x%x", rc);
        (*task)->Release(task);
        return -1;
    }

    UInt8 transferDirection = kSCSIDataTransfer_NoDataTransfer;
    UInt64 transferCount = 0;
    IOAddressRange sgElement = { 0, 0 };
    if (buf && bufLen > 0) {
        switch (direction) {
        case DD_DIR_IN:  transferDirection = kSCSIDataTransfer_FromTargetToInitiator; break;
        case DD_DIR_OUT: transferDirection = kSCSIDataTransfer_FromInitiatorToTarget; break;
        default:         transferDirection = kSCSIDataTransfer_NoDataTransfer; break;
        }
        transferCount = bufLen;
        sgElement.address = (mach_vm_address_t)(uintptr_t)buf;
        sgElement.length = bufLen;
        rc = (*task)->SetScatterGatherEntries(task, &sgElement, 1, transferCount, transferDirection);
        if (rc != kIOReturnSuccess) {
            dd_set_error("SetScatterGatherEntries: 0x%x", rc);
            (*task)->Release(task);
            return -1;
        }
    }

    (*task)->SetTimeoutDuration(task, 30000);

    SCSI_Sense_Data sense;
    memset(&sense, 0, sizeof(sense));
    SCSITaskStatus status = kSCSITaskStatus_GOOD;
    UInt64 realized = 0;

    rc = (*task)->ExecuteTaskSync(task, &sense, &status, &realized);
    (*task)->Release(task);

    if (rc != kIOReturnSuccess) {
        dd_set_error("ExecuteTaskSync: 0x%x", rc);
        return -1;
    }
    if (status != kSCSITaskStatus_GOOD) {
        dd_set_error("SCSI task status %u, sense key 0x%02x", status, sense.SENSE_KEY);
        if (senseOut && senseLen) {
            memcpy(senseOut, &sense, sizeof(sense));
            *senseLen = (unsigned int)sizeof(sense);
        }
        return -1;
    }

    *transferred = (unsigned int)realized;
    return 0;
}

void ddus_close(ddus_session *s)
{
    if (!s) return;
    if (s->taskDevice) {
        (*s->taskDevice)->ReleaseExclusiveAccess(s->taskDevice);
        (*s->taskDevice)->Release(s->taskDevice);
    }
    if (s->nub) IOObjectRelease(s->nub);
    free(s);
}
