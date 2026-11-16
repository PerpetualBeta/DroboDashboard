// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DroboDashboard",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure protocol layer: TM wire codec, CDB builders, ESA page parsers.
        .target(name: "DroboKit"),
        // C transports: user-space SCSITaskDeviceInterface and TrustedData kext user client.
        .target(
            name: "DDServiceC",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        // Swift wrappers around the C transports, conforming to SCSITransport.
        .target(
            name: "DroboTransport",
            dependencies: ["DroboKit", "DDServiceC"]
        ),
        // Root daemon listening on 127.0.0.1:4502.
        .executableTarget(
            name: "DDService",
            dependencies: ["DroboKit", "DroboTransport", "DDServiceC"]
        ),
        // Management CLI; the live verification tool.
        .executableTarget(
            name: "drobo",
            dependencies: ["DroboKit", "DroboTransport", "DDServiceC"]
        ),
        // Minimal host app that installs and activates the DroboDext system
        // extension. Bundled by the `host` Makefile target.
        .executableTarget(name: "DroboServiceHost"),
        // The Dashboard window: live pool read-only through the dext.
        .executableTarget(
            name: "DroboDashboardUI",
            dependencies: ["DroboKit", "DroboTransport", "DDServiceC"]
        ),
        .testTarget(name: "DroboKitTests", dependencies: ["DroboKit"])
    ]
)
