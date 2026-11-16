# DroboDashboard

A native Apple Silicon replacement for Drobo Dashboard 3.6.1, built from a
reverse-engineering pass over the original x86_64 daemon (DDService64d) with
REA. The original cannot run on macOS 27 because Rosetta is gone and every
Drobo user-space binary is Intel-only.

Protocol facts in this repo were verified against the original daemon's
decompiled code and against live hardware, not guessed. Facts marked
"until live data names them" are still placeholders.

## Layout

- `Sources/DroboKit` — pure protocol layer: the 16-byte `TMSessionHeader`
  frame, the vendor CDB builders, the ESA mode-page parsers, and the
  `ESASession` that runs the protocol over any pass-through pipe. No IOKit.
- `Sources/DDServiceC` — the two C transports of the first approach,
  user-space `SCSITaskDeviceInterface` and the TrustedData kext user client.
  Both are dead on macOS 27 (measured; see Transports) and kept only as
  reference.
- `Sources/DroboTransport` — Swift wrappers conforming to `SCSITransport`;
  `DextTransport` is the live one.
- `Sources/drobo` — the management CLI; the live verification tool.
- `Sources/DroboDashboardUI` — the Dashboard window: capacity, slots, health,
  polled read-only. Bundled by `gmake dashboard`.
- `Sources/DroboServiceHost` — the resident host app that installs and
  activates the dext and serves as its extension delegate. Bundled by
  `gmake host`.
- `dext/` — `DroboDext`, the DriverKit system extension subclassing Apple's
  `IOUserSCSIPeripheralDeviceType00`.
- `tools/make-icon.swift` — iconset pipeline from the committed master.
- `Tests/DroboKitTests` — wire-format tests for the protocol layer.

## Transports

**DriverKit dext (the only live route).** `DroboDext` sits on the SCSI LUN as
a subclass of Apple's `IOUserSCSIPeripheralDeviceType00`: Apple's kernel BOT
keeps the wire, our driver passes CDBs through `UserSendCDB`, and
`UserSuspendServices`/`UserResumeServices` are the exclusive-access session
for later write work. No kext, no security-policy change, no eject for reads.
Signed with the team identity; the App ID carries the "DriverKit Allow Any
UserClient" portal permission so any same-team client can open it.

**User-space (dead on macOS 27, measured).** `SCSITaskDeviceInterface`
exclusive access returns `kIOReturnUnsupported`, and a libusb claim of the
device returns access denied: macOS 27 refuses both paths to a non-Rosetta
process. The code stays for reference and for older macOS.

**Kext (unused).** The `TrustedDataSCSIDriver` user client the original used.
Needs a Reduced Security policy change, so it stays dormant. See
`kext/README.md`.

## Build and test

    gmake build       # release build
    gmake test        # protocol-layer tests
    gmake cli         # run the CLI
    gmake daemon      # run DDService
    gmake host        # bundle + sign DroboService.app (embeds the dext)
    gmake dashboard   # bundle + sign DroboDashboard.app
    gmake icon        # rebuild Resources/AppIcon.icns from the master

## CLI

    drobo list                  registry-only enumeration, no device access
    drobo status                parsed health, capacity, firmware, slots
    drobo probe                 read-only sweep of every ESA page (hex + parsed)
    drobo heal                  kill wedged dext servers, wait for a clean state
    drobo matchdebug            dump the IOKit matching candidates

`status` and `probe` take `--disk <bsd name>` and `--transport
userspace|kext|dext` for the older transports; the dext route matches by
vendor and needs no disk name.

## The dashboard

`DroboDashboard.app` shows the pool live: a health pill, the protected
capacity gauge, one card per slot (five bays plus the SSD cache), and the
firmware footer. It polls every five seconds on a private queue; the window
never blocks on the driver. Unpinned protocol values render raw rather than
wearing invented labels. `DROBO_RENDER_PNG=<path> <binary>` renders one live
frame off-screen and exits, for checking UI changes without screen-recording
permission.

## Upgrading the dext

A dext version bump while the device is attached wedges the old server
process, which never exits on its own. The proven loop is: unplug the cable,
install the new `DroboService.app`, `open` it to activate, then plug the
cable back in. No kills needed. `drobo heal` is the recovery tool when a
wedge happens anyway: it kills only servers that started before the active
dext was installed (the healthy provider of the current version is never
touched) and waits for the version state machine to settle.

## Debug logging

Set `DROBO_LOG=off|error|info|debug` before running either binary. Logs go to
`~/Library/Logs/DroboService/ddservice.log`, rotate at 1 MB, and keep 3
generations. Nothing is written while the gate is off.

## v0.1 scope

Read-only. Device identity, slots, capacity, firmware, health. The write side
is surveyed and documented (MODE SELECT for configuration, 0xEA system
operations for actions; see the KB note on ESA page layouts) but no command
path exercises it yet. The daemon answers only:

    eCmdGetDevices eCmdGetSysInfo eCmdGetCapacity eCmdGetFirmware
    eCmdGetStatus eCmdGetSlotInfo eCmdDoPoll eCmdEmpty

Anything else gets `error unknown command <name>`, like the original router.

## Knobs and placeholders

- `protocolByte` — CDB byte 9 carries the device protocol byte shifted left 6.
  The original sets it from the device session; the value is a knob defaulting
  to 0 until live data names it.
- Slot records' 5-byte tail and the state byte meanings beyond 0x03 (present
  and good) stay unfitted until the device reports them.
- Status page relayout/doubleDegraded fields exist only in the 0x14/0x18 page
  generations; the 5D3 declares the 0x10 generation and those fields stay
  unavailable.
