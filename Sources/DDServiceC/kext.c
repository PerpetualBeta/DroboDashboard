// Pass-through through the TrustedDataSCSIDriver kext user client
// (com_TrustedData_UserClient_SCSIType00). Kept as the secondary transport for
// a day the reduced-security policy change is wanted; the primary transport is
// the user-space route in userspace.c.
//
// Session open follows DDService64d PNPManager::ServiceOpen: match the driver
// class, open with type 0, then send selector 0 to open the user client.
// Every command is one 32-byte ESAVendorSpecificCDBStruct through
// IOConnectCallStructMethod: selector 7 reads, selector 6 writes.

#include "ddtransport.h"

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern const char *dd_last_error(void);
extern void dd_set_error(const char *fmt, ...);
#include <stdlib.h>
#include <string.h>
#include <pthread.h>


struct ddk_session {
    io_connect_t connect;
    io_service_t service;
};

int ddk_open(ddk_session **out, char *bsdName, size_t bsdLen)
{
    *out = NULL;
    if (bsdName && bsdLen) bsdName[0] = '\0';

    CFMutableDictionaryRef match =
        IOServiceMatching("com_TrustedData_driver_VendorSpecificType00");
    if (!match) {
        dd_set_error("IOServiceMatching(TrustedData driver) returned NULL (kext loaded?)");
        return -1;
    }
    /* Full match, as the original does with its Whole flag. */
    CFDictionarySetValue(match, CFSTR("Whole"), kCFBooleanTrue);

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator);
    if (kr != KERN_SUCCESS) {
        dd_set_error("IOServiceGetMatchingServices: 0x%x", kr);
        return -1;
    }

    io_service_t service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (!service) {
        dd_set_error("no TrustedData driver instance found (kext loaded?)");
        return -1;
    }

    io_connect_t connect = IO_OBJECT_NULL;
    kr = IOServiceOpen(service, mach_task_self(), 0, &connect);
    if (kr != KERN_SUCCESS) {
        dd_set_error("IOServiceOpen: 0x%x", kr);
        IOObjectRelease(service);
        return -1;
    }

    /* Selector 0 opens the user client, as IOCSCSISession::reopen does. */
    kr = IOConnectCallScalarMethod(connect, 0, NULL, 0, NULL, NULL);
    if (kr != KERN_SUCCESS) {
        dd_set_error("user client open (selector 0): 0x%x", kr);
        IOServiceClose(connect);
        IOObjectRelease(service);
        return -1;
    }

    ddk_session *s = calloc(1, sizeof(*s));
    s->connect = connect;
    s->service = service;
    *out = s;
    return 0;
}

int ddk_send(ddk_session *s, const unsigned char *cdb, int cdbLen,
             unsigned char *buf, unsigned int bufLen, int direction,
             unsigned int *transferred)
{
    if (!s || !cdb || cdbLen <= 0 || cdbLen > 16 || !transferred) {
        dd_set_error("ddk_send: bad arguments");
        return -1;
    }
    *transferred = 0;

    unsigned char st[32];
    memset(st, 0, sizeof(st));
    st[0] = cdbLen >= 3 ? cdb[2] : 0;   /* page code, telemetry */
    st[1] = cdbLen >= 4 ? cdb[3] : 0;   /* subpage, telemetry   */
    memcpy(&st[2], cdb, (size_t)cdbLen);
    st[18] = (unsigned char)cdbLen;

    /* The kext requires a non-NULL buffer and a non-zero size on both paths,
     * so zero-length commands carry a one-byte scratch buffer. */
    unsigned char scratch = 0;
    unsigned char *data = buf ? buf : &scratch;
    unsigned int len = bufLen ? bufLen : 1;
    memcpy(&st[20], &len, sizeof(len));
    memcpy(&st[24], &data, sizeof(data));

    kern_return_t kr;
    if (direction == DD_DIR_IN) {
        uint32_t outStruct[1] = {0};
        size_t outStructSize = sizeof(outStruct);
        kr = IOConnectCallStructMethod(s->connect, 7, st, sizeof(st),
                                       outStruct, &outStructSize);
        if (kr == KERN_SUCCESS) *transferred = outStruct[0];
    } else {
        kr = IOConnectCallStructMethod(s->connect, 6, st, sizeof(st), NULL, NULL);
        if (kr == KERN_SUCCESS) *transferred = bufLen;
    }
    if (kr != KERN_SUCCESS) {
        dd_set_error("IOConnectCallStructMethod(selector %d): 0x%x",
               direction == DD_DIR_IN ? 7 : 6, kr);
        return -1;
    }
    return 0;
}

void ddk_close(ddk_session *s)
{
    if (!s) return;
    if (s->connect != IO_OBJECT_NULL) IOServiceClose(s->connect);
    if (s->service != IO_OBJECT_NULL) IOObjectRelease(s->service);
    free(s);
}
