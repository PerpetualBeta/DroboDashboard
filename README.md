# DroboDashboard

A native Apple Silicon replacement for Drobo Dashboard 3.6.1, built from a
reverse-engineering pass over the original x86_64 daemon (DDService64d) with
REA. The original cannot run on macOS 27 because Rosetta is gone and every
Drobo user-space binary is Intel-only.

Protocol facts in this repo were verified against the original daemon's
decompiled code, not guessed. Facts marked "until live data names them" are
still placeholders.

## Layout

- `Sources/DroboKit` — pure protocol layer: the 16-byte `TMSessionHeader`
  frame, the vendor CDB builders, the ESA mode-page parsers, and the
  `ESASession` that runs the protocol over any pass-through pipe. No IOKit.
- `Sources/DDServiceC` — the two C transports: user-space
  `SCSITaskDeviceInterface` (primary) and the TrustedData kext user client
  (secondary).
- `Sources/DroboTransport` — Swift wrappers conforming to `SCSITransport`.
- `Sources/drobo` — the management CLI; the live verification tool.
- `Sources/DDService` — the daemon, listening on 127.0.0.1:4502, answering the
  read-only `eCmd*` text commands the Dashboard UI used.
- `Tests/DroboKitTests` — wire-format tests for the protocol layer.

## Transports

**User-space (primary).** `SCSITaskDeviceInterface` exclusive access through
Apple's SCSI task layer. No kext, no security-policy change. The trade: the
whole device must be ejected first, because exclusive access refuses while any
volume is mounted.

**Kext (secondary).** The `TrustedDataSCSIDriver` user client the original
used. Needs the kext loaded and a Reduced Security policy change, so it stays
dormant until requested. See `kext/README.md`.

## Build and test

    gmake build     # release build
    gmake test      # protocol-layer tests
    gmake daemon    # run DDService
    gmake cli       # run the CLI

## CLI

    drobo list                  registry-only enumeration, no device access
    drobo probe --disk disk15   read-only sweep of every ESA page (hex + parsed)
    drobo status --disk disk15  parsed health, capacity, firmware, bays

Options:

    --disk <bsd name>           device, e.g. disk15 (whole device, not a slice)
    --eject                     eject the device first so exclusive access works
    --transport userspace|kext  default userspace

### The eject dance

A management session holds exclusive access, so the device must be ejected
first. `--eject` does that with `diskutil eject` on the whole device (not just
the CoreStorage volume). After the session:

    diskutil coreStorage list        find the logical volume UUID
    diskutil coreStorage unlockLV <uuid>

The volume (Jupiter in the reference setup) remounts on unlock. Data
protection runs on the device while it is unmounted, so short sessions are
safe.

## Debug logging

Set `DROBO_LOG=off|error|info|debug` before running either binary. Logs go to
`~/Library/Logs/DroboService/ddservice.log`, rotate at 1 MB, and keep 3
generations. Nothing is written while the gate is off.

## v0.1 scope

Read-only. Device identity, slots, capacity, firmware, health. Writes exist in
the protocol layer (MODE SELECT, system-operation commands) but no command
path exercises them yet. The daemon answers only:

    eCmdGetDevices eCmdGetSysInfo eCmdGetCapacity eCmdGetFirmware
    eCmdGetStatus eCmdGetSlotInfo eCmdDoPoll eCmdEmpty

Anything else gets `error unknown command <name>`, like the original router.

## Knobs and placeholders

- `protocolByte` — CDB byte 9 carries the device protocol byte shifted left 6.
  The original sets it from the device session; the value is a knob defaulting
  to 0 until live data names it.
- ESA field names — fields the decompile left unnamed (SystemInfo's three
  u32s, CapacityInfo's four u64s, slot `field2`) stay numbered until live data
  names them.
