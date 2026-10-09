// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "QingShot", defaultLocalization: "en", platforms: [.macOS("15.0")], products: [.executable(name: "QingShot", targets: ["QingShot"])], targets: [.executableTarget(name: "QingShot", resources: [.process("Resources")])])
