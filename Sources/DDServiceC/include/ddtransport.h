// Transport surface shared by the user-space and kext C transports.

#ifndef DDTRANSPORT_H
#define DDTRANSPORT_H

#include <stddef.h>

#define DD_DIR_NONE 0
#define DD_DIR_IN   1   /* target to initiator */
#define DD_DIR_OUT  2   /* initiator to target */

typedef struct ddus_session ddus_session; /* user-space SCSITaskDeviceInterface */
typedef struct ddk_session ddk_session;   /* TrustedData kext user client       */

/* Last error, valid until the next call in the same thread. */
const char *dd_last_error(void);

/* --- user-space transport (needs the device ejected first) --- */

/* Enumerate Drobo peripheral nubs. Writes up to bsdLen-1 bytes of the BSD
 * name (may be empty) and vendor/product into outVendor/outProduct. Returns
 * the count of matching nubs; 0 opens nothing. */
int ddus_count_drobo_nubs(void);

/* Open by BSD name, e.g. "disk15". Only works while the BSD node exists;
 * a whole-device eject destroys it. */
int ddus_open_bsd_name(const char *bsdName, ddus_session **out);

/* Open the first Drobo peripheral nub by vendor match. Works after a
 * whole-device eject, when the BSD name is gone. */
int ddus_open_first_drobo_nub(ddus_session **out);

/* Send one CDB. On success *transferred holds the realized count and, when
 * senseOut is non-NULL, up to 18 sense bytes are copied with *senseLen set. */
int ddus_send(ddus_session *s, const unsigned char *cdb, int cdbLen,
              unsigned char *buf, unsigned int bufLen, int direction,
              unsigned int *transferred,
              unsigned char *senseOut, unsigned int *senseLen);

void ddus_close(ddus_session *s);

/* --- TrustedData kext transport (needs the kext loaded) --- */

int ddk_open(ddk_session **out, char *bsdName, size_t bsdLen);

int ddk_send(ddk_session *s, const unsigned char *cdb, int cdbLen,
             unsigned char *buf, unsigned int bufLen, int direction,
             unsigned int *transferred);

void ddk_close(ddk_session *s);

#endif /* DDTRANSPORT_H */
