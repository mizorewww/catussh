// swift-tools-version: 5.9
import PackageDescription

/// The remote file editor: Runestone on iOS, native NSTextView with line numbers and syntax highlighting on macOS.
let package = Package(
    name: "CatusshEditor",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "CatusshEditor", targets: ["CatusshEditor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/simonbs/Runestone", exact: "0.5.2"),
        .package(url: "https://github.com/simonbs/TreeSitterLanguages", exact: "0.1.10"),
        .package(name: "CatusshDesign", path: "../CatusshDesign"),
    ],
    targets: [
        .target(
            name: "CatusshEditor",
            dependencies: [
                .product(name: "CatusshDesign", package: "CatusshDesign"),
                .product(name: "Runestone", package: "Runestone", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterBashRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterJSONRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterYAMLRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterTOMLRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterPythonRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterJavaScriptRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterTypeScriptRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterGoRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterRustRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterCRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterCPPRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterLuaRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterRubyRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterPHPRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterPerlRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterHTMLRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterCSSRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterMarkdownRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterSQLRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterJavaRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
                .product(name: "TreeSitterSwiftRunestone", package: "TreeSitterLanguages", condition: .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(name: "CatusshEditorTests", dependencies: ["CatusshEditor"]),
    ]
)
