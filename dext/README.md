# DroboDext (DriverKit transport)

A DriverKit USB driver that claims the 5D3's mass-storage interface and
exposes one user client method: send a vendor CDB through BOT. This is the
only transport that works on macOS 27, where both user-space pass-through
paths are measured dead (2026-11-16):

- `IOCreatePlugInInterfaceForService(kIOSCSITaskDeviceUserClientTypeID)`
  returns `kIOReturnUnsupported`: Apple's `SCSITaskUserClient` matches only
  the old-stack `IOSCSIPeripheralDeviceNub`, which the new
  `IOUSBMassStorageDriver` stack never creates.
- libusb interface claims fail with `LIBUSB_ERROR_ACCESS` even unmounted.

Nothing here auto-installs. The dext is built and installed by explicit
commands below, and the first activation needs your approval in System
Settings.

## Thunderbolt

None needed. The 5D3 is USB end to end: the two Thunderbolt ports tunnel
USB, so this one driver covers all three physical ports. Verify by plugging
into a Thunderbolt port and confirming the driver attaches.

## Layout

- `DroboDext/DroboDext.iig` — driver + user client declarations.
- `DroboDext/DroboDext.cpp` — implementation. The BOT pass-through body is a
  documented stub until the USB DriverKit SDK headers are available.
- `DroboDext/Info.plist` — personality: `IOUSBHostInterface`, VID 6585
  (0x19B9), PID 13619 (0x3533), interface 0, probe score 90000.
- `DroboDext/Entitlements.plist` — `com.apple.developer.driverkit.family.usb`.
- `Makefile` — no Xcode project; `iig` + `clang++` by hand.

## Wire protocol with the CLI/daemon

`IOServiceOpen` type 0, then `IOConnectCallStructMethod` selector 0.
Input struct: three u32s (cdbLength, direction, dataLength) + the 16-byte
zero-padded CDB. Output struct: the read data. v0.1 honours reads only.

## Build

Base DriverKit SDK ships with Xcode. The USB family headers come from
Apple's standalone DriverKit SDK download (developer.apple.com/downloads):

    make -f dext/Makefile USB_SDK=~/Downloads/DriverKitSDK IDENTITY="<Developer ID Application: ...>"

An ad-hoc identity (`make -f dext/Makefile`) builds but will not activate;
DriverKit needs a real signing identity with the USB family entitlement.

## Install and activate (manual, once)

    systemextensionsctl developer on     # if the entitlement is not provisioned
    # install via a helper app calling OSSystemExtensionRequest, or for
    # development: appexctl/system_extension install path
    systemextensionsctl list             # check [activated enabled]
    # approve in System Settings > General > Login Items & Extensions when prompted

Then `drobo status` (default transport is dext) needs no eject and no
CoreStorage dance.

## Risk register

- The probe score must beat `IOUSBMassStorageDriverNub` on the same
  interface; if it does not, the Apple driver wins and the dext never
  claims. First install answers this.
- The BOT body is unwritten until the USB SDK lands; the shape is fixed and
  documented in `DroboDext.cpp`.
- 2021-era enclosure with a modern driver stack: mode-page behaviour is
  unverified until the first probe sweep.
