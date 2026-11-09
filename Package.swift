// swift-tools-version: 6.2
import PackageDescription

var packageDependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = []
#if os(Linux)
// CryptoKit and CommonCrypto are Apple-only. On Linux the core builds against swift-crypto, which has
// the same API, so the protocol tests run on any host.
packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"))
coreDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
#endif

let package = Package(
    name: "LumaRemoteKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LumaRemoteCore", targets: ["LumaRemoteCore"]),
        .library(name: "LumaRemoteKit", targets: ["LumaRemoteKit"]),
        // A loopback LumaTV for tests: the real protocol, a fixed pairing code, and a log of what arrived.
        .library(name: "LumaRemoteFakeTV", targets: ["LumaRemoteFakeTV"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(name: "LumaRemoteCore", dependencies: coreDependencies),
        .target(name: "LumaRemoteKit", dependencies: ["LumaRemoteCore"]),
        .target(name: "LumaRemoteFakeTV", dependencies: ["LumaRemoteCore"]),
        .testTarget(
            name: "LumaRemoteCoreTests",
            dependencies: ["LumaRemoteCore", "LumaRemoteFakeTV"],
            resources: [.copy("vectors.json")]
        ),
        .testTarget(name: "LumaRemoteKitTests", dependencies: ["LumaRemoteKit", "LumaRemoteCore", "LumaRemoteFakeTV"]),
    ]
)
