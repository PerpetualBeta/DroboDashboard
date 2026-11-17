# DroboDashboard

A native Apple Silicon replacement for Drobo Dashboard 3.6.1, built from a
reverse-engineering pass over the original x86_64 daemon (DDService64d) with
REA. The original cannot run on macOS 27 because Rosetta is gone and every
Drobo user-space binary is Intel-only.

Protocol facts in this repo were verified two ways: against the original
daemon's decompiled code, and against live hardware. Facts marked "until
live data names them" are still placeholders. Unpinned values are always
rendered raw; they are never labelled with invented semantics.

## State of this build

v0.1 is read-only and deployed. The pieces:

- `DroboDext`, a DriverKit system extension that sits on the Drobo's SCSI
  LUN and passes CDBs through to the device. Version 0.1.0, build 10,
  activated and enabled.
- `DroboService.app`, the resident host app that installs and activates the
  dext and acts as its extension delegate. Runs at login, holds no window.
- `DroboDashboard.app`, the window: a health pill, the protected-capacity
  gauge, one card per slot (five bays plus the SSD cache), and the firmware
  footer, polled every five seconds read-only.
- `drobo`, the CLI: the live verification tool and the recovery tool
  (`heal`).

No write command reaches the disk pack. The write path is surveyed and
catalogued (see the end of this file) but nothing exercises it.

## The hardware this was fitted against

A Drobo 5D3, USB VID 0x19B9 PID 0x3533. The pack: three Seagate
ST4000NE0025 4 TB, one WD4003FFBX 4 TB, one WD30EZRX 3 TB, and a Samsung
850 500 GB as the SSD cache slot. Dual-disk protection. Firmware "Feb 21
2020,02:38:38 ArmMarvell v1448 (word 0xbe71)". Known-good live values for
comparison after any change: free 8,293,250,519,040 / used
2,501,661,143,040 / total 10,794,911,662,080 / unprotected 0; status word
0x28000, diskpack 0.

## Layout

- `Sources/DroboKit` — pure protocol layer: the 16-byte `TMSessionHeader`
  frame, the vendor CDB builders, the ESA mode-page parsers, and the
  `ESASession` that runs the protocol over any pass-through pipe. No IOKit.
- `Sources/DDServiceC` — the two C transports of the first approach,
  user-space `SCSITaskDeviceInterface` and the TrustedData kext user
  client. Both are dead on macOS 27 (measured; see Transports) and kept
  only as reference.
- `Sources/DroboTransport` — Swift wrappers conforming to `SCSITransport`;
  `DextTransport` is the live one.
- `Sources/drobo` — the management CLI.
- `Sources/DroboDashboardUI` — the Dashboard window.
- `Sources/DroboServiceHost` — the resident host app.
- `Sources/DroboHealthAgent` — the LaunchAgent-run health check: one
  read-only sweep per run, Notification Center post on a verdict change.
- `Sources/DDService` — the read-only daemon on 127.0.0.1:4502 answering
  the `eCmd*` text commands the original Dashboard UI used. Not part of the
  deployment; kept because the original's wire protocol is documented by it.
- `dext/` — `DroboDext` source, its `Makefile` (no Xcode project), the dext
  and host entitlements.
- `kext/README.md` — the dormant TrustedData kext route.
- `tools/make-icon.swift` — iconset pipeline from the committed master.
- `Tests/DroboKitTests` — wire-format tests for the protocol layer.

## Transports

**DriverKit dext (the only live route).** `DroboDext` subclasses Apple's
`IOUserSCSIPeripheralDeviceType00` (SCSIPeripheralsDriverKit). Apple's
kernel buffer-of-transfers engine keeps the wire; our driver passes CDBs
through `UserSendCDB`; `UserSuspendServices`/`UserResumeServices` are the
built-in exclusive-access session, reserved for future write work. No kext,
no security-policy change, no eject for reads. Clients open the registered
driver node by matching class `IOUserSCSIPeripheralDeviceType00` with
`IOPropertyMatch` on `IOUserClass: DroboDextDriver`. The App ID carries the
"DriverKit Allow Any UserClient" portal permission so any same-team client
can open it.

**User-space (dead on macOS 27, measured).** `SCSITaskDeviceInterface`
exclusive access returns `kIOReturnUnsupported`, and a libusb claim of the
device returns access denied. macOS 27 refuses both paths to a non-Rosetta
process. The code stays for reference and for older macOS.

**Kext (unused).** The `TrustedDataSCSIDriver` user client the original
used. Needs a Reduced Security policy change, so it stays dormant. See
`kext/README.md`.

## Prerequisites for a rebuild

- Xcode with the DriverKit platform installed. The DriverKit SDK at
  `Platforms/DriverKit.platform/Developer/SDKs/DriverKit.sdk` is complete
  (framework headers included); a `27.2`-suffixed SDK next to it is a
  stripped duplicate without the frameworks. The dext Makefile hardcodes
  the correct one.
- An Apple Development signing certificate for the team. The Makefiles
  auto-detect it; override with `IDENTITY="<name>"`.
- Two provisioning profiles in `~/Downloads`, matching the Makefile
  defaults. Regenerate both from the Apple developer portal if expired,
  then update the `PROFILE` / `HOST_PROFILE` defaults or pass them on the
  command line:
  - `ccjorvikdrobodext-6.provisionprofile`, embedded in the dext bundle.
    The App ID `cc.jorvik.drobodext` must carry: DriverKit (development),
    DriverKit Family SCSIController (development), DriverKit Allow Third
    Party UserClients, DriverKit Allow Any UserClient.
  - `ccjorvikdroboservice-2.provisionprofile`, embedded as
    `embedded.provisionprofile` in `DroboService.app`. The App ID
    `cc.jorvik.droboservice` carries only "System Extension Install". The
    host entitlements file mirrors that profile exactly: declaring more
    than the profile grants makes launchd kill the spawn (exit 163).

The dashboard app needs no profile at all; it holds no special
entitlements.

## Build and test

    gmake build       # release build (swift build -c release)
    gmake test        # protocol-layer tests
    gmake cli         # run the CLI in place
    gmake daemon      # run DDService in place
    gmake host        # bundle + sign DroboService.app (embeds the dext)
    gmake dashboard   # bundle + sign DroboDashboard.app
    gmake icon        # rebuild Resources/AppIcon.icns from the master

Overrides: `gmake host IDENTITY="<Developer ID Application: ...>"
PROFILE=... HOST_PROFILE=...`.

One rule that has bitten once: **a dext version bump reaches a bundle only
when `gmake host` runs after the edit.** If you bump
`dext/DroboDext/Info.plist` CFBundleVersion and forget to rebuild, the
"upgrade" ships the old build. Check the result:

    plutil -p .build/DroboService.app/Contents/Library/SystemExtensions/cc.jorvik.drobodext.dext/Contents/Info.plist | grep -A1 CFBundleVersion

## First-time deployment

Installs to /Applications are App Management territory: the user's own
Terminal does them, an agent shell cannot, even as root.

    # build both bundles
    gmake host && gmake dashboard

    # in the USER's Terminal:
    sudo rm -rf /Applications/DroboService.app /Applications/DroboDashboard.app
    cp -R ~/Developer/DroboDashboard/.build/DroboService.app \
          ~/Developer/DroboDashboard/.build/DroboDashboard.app /Applications/
    open /Applications/DroboService.app

Approve the system-extension prompt when macOS shows it. On a Mac with no
prior copy, activation may need the cable unplugged and replugged. Then
verify:

    systemextensionsctl list     # expect: cc.jorvik.drobodext (0.1.0/N) [activated enabled]
    ~/Developer/DroboDashboard/.build/release/drobo status
    open /Applications/DroboDashboard.app

`drobo status` must show the known-good values above. `open` the dashboard
and the window should fill with live numbers within five seconds.

## Upgrading the dext

A dext version bump while the device is attached wedges the old server
process, which never exits on its own. The proven loop needs no kills:

1. Bump `CFBundleVersion` in `dext/DroboDext/Info.plist`.
2. `gmake host` (after the bump; see the staleness rule above).
3. Unplug the Drobo's cable.
4. In the user's Terminal: replace `/Applications/DroboService.app` and
   `open` it. Activation completes while detached.
5. Wait about ten seconds, plug the cable back in.

The new server spawns on device match; the old one is gone. `drobo heal`
is the recovery tool when a wedge happens anyway.

## Recovery: drobo heal

The healthy provider of the active dext runs as a server process just like
a wedged one, so existence is not evidence of wedging. `heal` kills only
servers that started **before** the newest
`/Library/SystemExtensions/*/cc.jorvik.drobodext.dext` bundle modification
date; servers younger than the install are reported and left running. It
sudo-kills, so run it from the user's Terminal when it actually has work
to do. It exits non-zero with a message when the kill needs a password.

## CLI reference

    drobo list                  registry-only enumeration, no device access
    drobo status                parsed health, capacity, firmware, slots
    drobo probe                 read-only sweep of every ESA page (hex + parsed)
    drobo heal                  kill wedged dext servers, wait for a clean state
    drobo matchdebug            dump the IOKit matching candidates

`status` and `probe` take `--disk <bsd name>` and `--transport
userspace|kext|dext` for the older transports; the dext route matches by
vendor and needs no disk name.

## The dashboard

`DroboDashboard.app` shows the pool live. All dext IO runs on a private
serial queue and results land on the main queue, so a slow read never
freezes the window. The transport opens once and stays open across polls.

To check a UI change without popping windows or screen-recording
permission:

    DROBO_RENDER_PNG=/tmp/out.png .build/release/DroboDashboardUI

renders one live frame off-screen and exits (exit 3 on a 15-second
timeout). A failed read renders the failure state the same way. Convert the
capture to sRGB before judging colours; screen captures carry the display
profile.

## Signing: current configuration and the durable path

Currently everything is signed with the Apple Development identity
(auto-detected) plus the two development profiles, both expiring
2027-11-16. What that means in practice: the activated dext and installed
apps keep running past expiry (signatures are timestamped and activation
was validated at install time), but any reinstall, activation, or upgrade
after that date fails until re-signing with a fresh cert.

The durable fix, already proven across the rest of the estate:

1. Portal: create **Developer ID** system-extension provisioning profiles
   for both App IDs (same flow as the development ones).
2. Sign with `IDENTITY="<Developer ID Application: Jonthan Hollin
   (EG86BCGUE7)>"` (the current one expires 2031-03-30).
3. Notarise and staple both bundles:

       xcrun notarytool submit <zip> --keychain-profile <name> --wait
       xcrun stapler staple <bundle>

Only the dext host needs a profile; the dashboard needs none. Timestamped
notarised software keeps running across cert expiry and macOS updates;
only fresh installs on new machines ever need a current certificate.

## Troubleshooting (measured, macOS 27)

- **Dext server wedged after an upgrade**: run the unplugged loop above;
  `drobo heal` as the fallback.
- **`MACH_SEND_INVALID_DEST` after reopening the dext node**: never
  open-close-reopen a dext connection in one process. Open once and keep
  it (the dashboard does).
- **Match dict entries silently ignored**: unknown keys in IOKit matching
  dictionaries are ignored, not rejected. Restrict with `IOPropertyMatch`
  on `IOUserClass`, not invented top-level keys.
- **`IOConnectCallStructMethod` structureOutput arrives NULL**: the driver
  must create and return the `OSData` itself; the caller's buffer is not
  populated.
- **`pgrep -l` truncates names to 15 characters**, and the dext server's
  executable name is not the app name anyway; `pgrep DroboDext` is the
  reliable form.
- **`open` on a running app just focuses it** (error -1712 from scripts);
  quit first when replacing a bundle.
- **App Management blocks bundle changes** even as root from an agent
  shell; `/Applications` installs go through the user's Terminal.
- **Logging**: set `DROBO_LOG=off|error|info|debug` before running either
  binary. Logs go to `~/Library/Logs/DroboService/ddservice.log`, rotate
  at 1 MB, keep 3 generations. Nothing is written while the gate is off.
  Dext-side text logging is a measured dead end (IOLog is privacy-masked
  whole, os_log invisible, no fopen in the dext libc); encode diagnostics
  in distinct return codes instead.
- **x86_64 slices are untestable**: Rosetta is gone on macOS 27, and
  `oah exists` lies about it. arm64 only.

## Protocol notes

ESA MODE SENSE(10) responses carry the raw vendor page with no mode
parameter header; byte 0 is tag 0x7a, byte 1 is the subpage. The page's
declared big-endian length at offset 2 is the full page size and gates
every optional field; never gate on the transport buffer length, because
the firmware returns junk past the page. The capacity page fields at +4,
+0xC, +0x14, +0x1C are free / used / total protected / total unprotected,
all big-endian 64-bit. Slot records start at offset 6 with stride 0x48.

The write side is surveyed, catalogued, and unused: configuration is MODE
SELECT(10) 0x55 through `setESAModePageObject`; actions are 0xEA system
operations (restart 0x03, identify 0x06, command channel 0x0A, power off
0x17, dim 0x18, revert 0x80), the builders byte-verified against the
original daemon's constructors. First candidate when a write is wanted:
identify-blink 0x06, with the volume unmounted via the suspend/resume
session.

## The health agent

`DroboHealth.app` is the persistent check for when the dashboard is not
open. A user LaunchAgent (`Resources/cc.jorvik.drobohealth.plist`, label
`cc.jorvik.drobohealth`) runs it every 15 minutes (RunAtLoad + StartInterval
900). Each run: one read-only sweep through the dext, a verdict from the
shared `PackHealth` evaluator (the same rules as the dashboard pill), and a
Notification Center post ONLY when the verdict changes: into a problem, or
back to healthy. A steady problem stays delivered but does not re-post.

Rules the verdict uses (all measured): diskpack status 0 or 1 healthy,
anything else a problem; relayout or doubleDegraded non-zero a problem;
any slot state other than 0x03 a problem, named by bay or cache slot. Two
consecutive failed polls count as "cannot reach the disk pack"; one
failure is treated as transient.

State: `~/Library/Application Support/DroboHealth/state.json` (verdict,
reason, consecutive failures). Logs: `~/Library/Logs/DroboHealth/health.log`
via the `DROBO_LOG` gate. Set `DROBO_HEALTH_NOTIFY=off` to disable
Notification Center entirely (state machine and logging still run).

Install:

    # app bundle: user's Terminal, App Management territory
    cp -R ~/Developer/DroboDashboard/.build/DroboHealth.app /Applications/
    # agent (agent shell is fine for ~/Library/LaunchAgents):
    cp ~/Developer/DroboDashboard/Resources/cc.jorvik.drobohealth.plist \
       ~/Library/LaunchAgents/
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/cc.jorvik.drobohealth.plist

The first run triggers the one-time notification permission prompt. Change
the cadence by editing StartInterval in the LaunchAgent plist, then
`launchctl bootout gui/$(id -u)/cc.jorvik.drobohealth` and bootstrap again.

## Knobs and placeholders

- `protocolByte` — CDB byte 9 carries the device protocol byte shifted
  left 6. The original sets it from the device session; the value is a
  knob defaulting to 0 until live data names it.
- Slot records' 5-byte tail and the state byte meanings beyond 0x03
  (present and good) stay unfitted until the device reports them.
- Status page relayout/doubleDegraded fields exist only in the 0x14/0x18
  page generations; the 5D3 declares the 0x10 generation and those fields
  stay unavailable.
- Dashboard poll cadence: live `defaults` knob,
  `defaults write cc.jorvik.drobodashboard pollInterval -float <seconds>`
  (default 5, clamped 0.5 to 60). Takes effect within one poll cycle, no
  relaunch.
