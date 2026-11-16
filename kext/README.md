# TrustedData kext transport (secondary)

This is the pass-through the original DDService64d used: the
`TrustedDataSCSIDriver.kext` user client (`com_TrustedData_UserClient_SCSIType00`),
written to through a 32-byte struct via `IOConnectCallStructMethod`.

Nothing here auto-runs. The kext is NOT loaded by anything in this repo, and
this transport is only exercised when `--transport kext` or
`--transport=kext` is passed.

## Why it is secondary

Loading the kext requires a Reduced Security policy change (Allow user
management of kernel extensions) and a reboot. The user-space transport in
`Sources/DDServiceC/userspace.c` needs neither, so it is the primary route and
the default.

## If you want it

1. Extract the kext from the Drobo Dashboard package
   (`Drobo Dashboard.app/Contents/Library/Extensions/TrustedDataSCSIDriver.kext`
   in the reference install).
2. Grant the policy in System Recovery, then:
       sudo kmutil install -v volume / -s /System/Volumes/Preboot \
           --bundled-system-third-party-kexts
   or `sudo kextload` on the kext copy.
3. Reboot, then confirm with:
       kextstat | grep TrustedData
4. Run the CLI with `--transport kext`. No eject is needed: the kext client
   coexists with the mounted volume.

## User client contract (verified from the arm64e slice)

- 11-entry selector table: 0 open, 1 close, 2/3 Get/SetESAModePage, 4/5
  VendorSpecificOut/In (24-byte struct), 6/7 PassThroughOut/In (32-byte
  struct), 8 logging, 9/10 SATA (40-byte struct).
- 32-byte pass-through struct: page code at +0, subpage at +1, CDB bytes at
  +2..+0x11, CDB length at +0x12, buffer length (u32) at +0x14, buffer
  pointer at +0x18.
- Opcode allowlist: 0x28, 0x2A, 0x55, 0x5A, plus 0x12 and 0xEA.
- CDB length must be 6 or 10.
- Selector 7 (read) returns a 4-byte out-struct holding the transferred count.
- Zero-length commands still need a non-NULL buffer with a non-zero size; the
  implementation carries a 1-byte scratch buffer for those.
- Open path: `IOServiceMatching("com_TrustedData_driver_VendorSpecificType00")`
  with the Whole flag, `IOServiceOpen(..., type 0)`, then selector 0 to open
  the user client.
