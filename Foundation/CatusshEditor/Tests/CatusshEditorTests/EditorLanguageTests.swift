import XCTest
@testable import CatusshEditor

final class EditorLanguageTests: XCTestCase {
    func testLanguageFromNameExtensionAndShebang() {
        XCTAssertEqual(EditorLanguage.detect(fileName: "nginx.conf"), .plain)
        XCTAssertEqual(EditorLanguage.detect(fileName: "compose.YAML"), .yaml)
        XCTAssertEqual(EditorLanguage.detect(fileName: ".bashrc"), .bash)
        XCTAssertEqual(EditorLanguage.detect(fileName: "Cargo.lock"), .toml)
        XCTAssertEqual(EditorLanguage.detect(fileName: "deploy", firstLine: "#!/usr/bin/env python3"), .python)
        XCTAssertEqual(EditorLanguage.detect(fileName: "run", firstLine: "#!/bin/sh"), .bash)
        XCTAssertEqual(EditorLanguage.detect(fileName: "notes", firstLine: "hello"), .plain)
    }

    #if os(iOS)
    func testEveryLanguageButPlainHasAGrammar() {
        for language in EditorLanguage.allCases {
            XCTAssertEqual(language.treeSitter == nil, language == .plain, language.title)
        }
    }
    #endif

    func testIndentationFollowsTheFile() {
        XCTAssertEqual(EditorIndentation.detect(in: "a:\n\tb\n\tc\n"), .tabs)
        XCTAssertEqual(EditorIndentation.detect(in: "a:\n  b:\n    c\n"), .spaces(2))
        XCTAssertEqual(EditorIndentation.detect(in: "def f():\n    pass\n"), .spaces(4))
        XCTAssertEqual(EditorIndentation.detect(in: "flat\nfile\n"), .spaces(4))
    }
}
