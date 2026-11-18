/*
 * usb-bot-probe: DECISIVE probe for the DroboDashboard vendor-op route.
 *
 * Question 1 (policy): can USER SPACE open this mass-storage device's
 * interface at all on macOS 27, or does the kernel's IOUSBMassStorageDriver
 * hold it exclusively? libusb_claim_interface answers this in one call.
 *
 * Question 2 (wire): if the claim succeeds, does a raw USB BOT transaction
 * reach the device? A standard INQUIRY (read, harmless) proves the wire.
 *
 * Question 3 (the blink): only with --confirm, only from HIS Terminal:
 * the mined vendor 0xEA op 0x06 blink (one zero byte, DataOut) over raw
 * BOT — the exact command Apple's SCSI stack refused to deliver.
 *
 * Build:
 *   cc -I/opt/homebrew/include tools/usb-bot-probe.c \
 *      -L/opt/homebrew/lib -lusb-1.0 -o .build/usb-bot-probe
 */

#include <libusb-1.0/libusb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DROBO_VID 0x19b9
#define DROBO_PID 0x3533

static const char *usberr(int rc) {
    switch (rc) {
    case LIBUSB_ERROR_IO: return "IO error";
    case LIBUSB_ERROR_INVALID_PARAM: return "invalid param";
    case LIBUSB_ERROR_ACCESS: return "ACCESS DENIED (permission)";
    case LIBUSB_ERROR_NO_DEVICE: return "no device";
    case LIBUSB_ERROR_NOT_FOUND: return "not found";
    case LIBUSB_ERROR_BUSY: return "BUSY (kernel driver holds it)";
    case LIBUSB_ERROR_TIMEOUT: return "timeout";
    case LIBUSB_ERROR_OVERFLOW: return "overflow";
    case LIBUSB_ERROR_PIPE: return "PIPE (endpoint stalled)";
    case LIBUSB_ERROR_INTERRUPTED: return "interrupted";
    case LIBUSB_ERROR_NO_MEM: return "no memory";
    case LIBUSB_ERROR_NOT_SUPPORTED: return "NOT SUPPORTED";
    default: return "other";
    }
}

/* BOT Command Block Wrapper: 31 bytes, LE fields. */
static void make_cbw(unsigned char *cbw, unsigned tag, unsigned datalen,
                     unsigned char flags, const unsigned char *cdb, unsigned char cdblen) {
    memset(cbw, 0, 31);
    cbw[0] = 'U'; cbw[1] = 'S'; cbw[2] = 'B'; cbw[3] = 'C';   /* 0x43425355 */
    cbw[4] = tag & 0xff; cbw[5] = (tag >> 8) & 0xff;
    cbw[6] = (tag >> 16) & 0xff; cbw[7] = (tag >> 24) & 0xff;
    cbw[8] = datalen & 0xff; cbw[9] = (datalen >> 8) & 0xff;
    cbw[10] = (datalen >> 16) & 0xff; cbw[11] = (datalen >> 24) & 0xff;
    cbw[12] = flags;      /* 0x80 = data-in */
    cbw[13] = 0;          /* LUN 0 */
    cbw[14] = cdblen;
    memcpy(cbw + 15, cdb, cdblen);
}

/* BOT Command Status Wrapper: 13 bytes. Returns the CSW status byte or -1. */
static int read_csw(libusb_device_handle *h, unsigned char *ep_in, unsigned tag) {
    unsigned char csw[13] = {0};
    int transferred = 0;
    int rc = libusb_bulk_transfer(h, *ep_in, csw, 13, &transferred, 10000);
    if (rc != 0) {
        printf("  CSW: bulk-in failed: %s\n", usberr(rc));
        return -1;
    }
    if (transferred != 13 || memcmp(csw, "USBS", 4) != 0) {
        printf("  CSW: bad (%d bytes, sig %02x%02x%02x%02x)\n",
               transferred, csw[0], csw[1], csw[2], csw[3]);
        return -1;
    }
    unsigned status = csw[12];
    printf("  CSW: status %u, residue %u\n", status,
           csw[8] | (csw[9] << 8) | (csw[10] << 16) | ((unsigned)csw[11] << 24));
    return (int)status;
}

int main(int argc, char **argv) {
    int confirm = (argc > 1 && strcmp(argv[1], "--confirm") == 0);

    libusb_context *ctx = NULL;
    int rc = libusb_init(&ctx);
    if (rc != 0) { printf("libusb_init: %s\n", usberr(rc)); return 1; }

    libusb_device **list = NULL;
    ssize_t n = libusb_get_device_list(ctx, &list);
    libusb_device *drobo = NULL;
    for (ssize_t i = 0; i < n; i++) {
        struct libusb_device_descriptor d;
        if (libusb_get_device_descriptor(list[i], &d) == 0 &&
            d.idVendor == DROBO_VID && d.idProduct == DROBO_PID) {
            drobo = list[i];
            break;
        }
    }
    if (!drobo) { printf("no Drobo 5D3 on the bus\n"); return 1; }
    printf("found Drobo 5D3 at bus %03x port %03x\n",
           libusb_get_bus_number(drobo), libusb_get_port_number(drobo));

    struct libusb_config_descriptor *cfg = NULL;
    libusb_get_active_config_descriptor(drobo, &cfg);
    if (cfg) {
        printf("config: %u interface(s)\n", cfg->bNumInterfaces);
        for (unsigned i = 0; i < cfg->bNumInterfaces; i++) {
            const struct libusb_interface *ifp = &cfg->interface[i];
            for (int a = 0; a < ifp->num_altsetting; a++) {
                const struct libusb_interface_descriptor *alt = &ifp->altsetting[a];
                printf("  interface %u: class 0x%02x subclass 0x%02x protocol 0x%02x, %u endpoints\n",
                       alt->bInterfaceNumber, alt->bInterfaceClass,
                       alt->bInterfaceSubClass, alt->bInterfaceProtocol,
                       alt->bNumEndpoints);
                for (unsigned e = 0; e < alt->bNumEndpoints; e++) {
                    const struct libusb_endpoint_descriptor *ep = &alt->endpoint[e];
                    printf("    endpoint 0x%02x: %s bulk=%d maxpacketsize %u\n",
                           ep->bEndpointAddress,
                           (ep->bEndpointAddress & 0x80) ? "IN" : "OUT",
                           (ep->bmAttributes & 3) == 2,
                           ep->wMaxPacketSize);
                }
            }
        }
    }

    libusb_device_handle *h = NULL;
    rc = libusb_open(drobo, &h);
    if (rc != 0) {
        printf("libusb_open: %s — user space cannot open the DEVICE\n", usberr(rc));
        return 1;
    }
    printf("libusb_open: OK (device handle acquired)\n");

    int iface = cfg ? cfg->interface[0].altsetting[0].bInterfaceNumber : 0;
    unsigned char ep_in = 0x81, ep_out = 0x01;
    if (cfg) {
        const struct libusb_interface_descriptor *alt = &cfg->interface[0].altsetting[0];
        for (unsigned e = 0; e < alt->bNumEndpoints; e++) {
            unsigned char addr = alt->endpoint[e].bEndpointAddress;
            if (addr & 0x80) ep_in = addr; else ep_out = addr;
        }
    }

    rc = libusb_claim_interface(h, iface);
    if (rc != 0) {
        printf("claim interface %d: %s — THE WALL: the kernel driver holds the\n", iface, usberr(rc));
        printf("interface; user space never gets the wire on this OS.\n");
        return 1;
    }
    printf("claim interface %d: OK — USER SPACE HAS THE WIRE\n", iface);

    /* Q2: standard INQUIRY over raw BOT (read, harmless). */
    {
        unsigned char cbw[31], data[36];
        unsigned char cdb[6] = {0x12, 0x00, 0x00, 0x00, 0x24, 0x00};
        make_cbw(cbw, 1, 36, 0x80, cdb, 6);
        int transferred = 0;
        int rc2 = libusb_bulk_transfer(h, ep_out, cbw, 31, &transferred, 10000);
        if (rc2 != 0) { printf("INQUIRY: CBW failed: %s\n", usberr(rc2)); goto detach; }
        printf("INQUIRY: CBW sent\n");
        rc2 = libusb_bulk_transfer(h, ep_in, data, 36, &transferred, 10000);
        if (rc2 != 0) { printf("INQUIRY: data-in failed: %s\n", usberr(rc2)); goto detach; }
        printf("INQUIRY: %d bytes in: vendor \"%.8s\" product \"%.16s\"\n",
               transferred, (char *)data + 8, (char *)data + 16);
        read_csw(h, &ep_in, 1);
    }

    /* Q3: THE BLINK over raw BOT — vendor 0xEA op 0x06, one zero byte.
     * The exact command Apple's stack refused. HIS --confirm run only. */
    if (confirm) {
        unsigned char cbw[31];
        unsigned char cdb[10] = {0xea, 0x10, 0x00, 0x06, 0x01, 0x00, 0x21, 0x00, 0x01, 0x00};
        unsigned char one_zero = 0x00;
        make_cbw(cbw, 2, 1, 0x00, cdb, 10);   /* flags 0 = data-out */
        int transferred = 0;
        printf("BLINK: CBW (0xEA op 0x06, 1-byte data-out)...\n");
        int rc2 = libusb_bulk_transfer(h, ep_out, cbw, 31, &transferred, 10000);
        if (rc2 != 0) { printf("BLINK: CBW failed: %s\n", usberr(rc2)); goto detach; }
        rc2 = libusb_bulk_transfer(h, ep_out, &one_zero, 1, &transferred, 10000);
        if (rc2 != 0) { printf("BLINK: data-out failed: %s\n", usberr(rc2)); goto detach; }
        printf("BLINK: data-out sent (%d bytes)\n", transferred);
        int status = read_csw(h, &ep_in, 2);
        if (status == 0)
            printf("BLINK: DEVICE SAID GOOD — watch the drive lights!\n");
        else
            printf("BLINK: device status %d\n", status);
    } else {
        printf("(blink not sent: run with --confirm from your Terminal)\n");
    }

detach:
    libusb_release_interface(h, iface);
    libusb_close(h);
    libusb_free_device_list(list, 1);
    libusb_exit(ctx);
    return 0;
}
