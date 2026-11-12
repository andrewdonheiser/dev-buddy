// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MarkdownViewer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MarkdownViewer", targets: ["MarkdownViewer"]),
        .library(name: "MarkdownViewerKit", targets: ["MarkdownViewerKit"]),
        .library(name: "MarkdownViewerChat", targets: ["MarkdownViewerChat"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.4.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3")
    ],
    targets: [
        .target(
            name: "MarkdownViewerKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ]
        ),
        .target(name: "MarkdownViewerChat"),
        .executableTarget(
            name: "MarkdownViewer",
            dependencies: [
                "MarkdownViewerKit",
                "MarkdownViewerChat",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .testTarget(
            name: "MarkdownViewerKitTests",
            dependencies: ["MarkdownViewerKit"]
        ),
        .testTarget(
            name: "MarkdownViewerChatTests",
            dependencies: ["MarkdownViewerChat"]
        ),
        .testTarget(
            name: "MarkdownViewerAppTests",
            dependencies: ["MarkdownViewer"]
        )
    ],
    swiftLanguageModes: [.v5]
)
