// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "MSPChatUIAppleHost",
  platforms: [
    .iOS(.v15),
    .macOS(.v12)
  ],
  products: [
    .library(name: "MSPChatUIAppleHost", targets: ["MSPChatUIAppleHost"])
  ],
  targets: [
    .target(name: "MSPChatUIAppleHost")
  ]
)
