import XCTest

/// A string literal that meant to interpolate but lost its backslash still
/// compiles, so the screen and VoiceOver read Swift source to the user:
/// 「記念石(totalAchievementCount.formatted())個以上」 shipped in 1.0.x that way.
/// This reads the shipping sources (the same way the StoreKit catalog test
/// reads the repository) and rejects any literal whose text still looks like
/// an interpolation without its `\`.
final class StringInterpolationLintTests: XCTestCase {
    func testShippingSourcesHaveNoInterpolationWithoutItsBackslash() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var scannedFileCount = 0
        var findings: [String] = []
        for directory in ["PomoGem", "PomoGemWidgets", "PomoGemScreenTimeMonitor", "Shared"] {
            let url = projectRoot.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: nil
            ) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                scannedFileCount += 1
                for literal in SwiftStringLiteralScanner.literals(in: source) {
                    for fragment in SwiftStringLiteralScanner.suspiciousFragments(in: literal.text) {
                        findings.append(
                            "\(directory)/\(fileURL.lastPathComponent):\(literal.line) \(fragment)"
                        )
                    }
                }
            }
        }

        XCTAssertGreaterThan(
            scannedFileCount,
            100,
            "The lint must actually read the app sources from \(projectRoot.path)"
        )
        XCTAssertEqual(
            findings,
            [],
            "These literals print Swift code instead of a value; add the missing backslash"
        )
    }

    func testScannerFindsTheShippedAchievementSubtitleBug() {
        let source = #"""
        let broken = "記念石(totalAchievementCount.formatted())個以上"
        let fine = "記念石\(totalAchievementCount.formatted())個以上"
        let nested = "\(isLowerBound ? "以上(count)件" : "")"
        let text = "記念石(count)個"
        """#
        let fragments = SwiftStringLiteralScanner.literals(in: source)
            .flatMap { SwiftStringLiteralScanner.suspiciousFragments(in: $0.text) }

        XCTAssertEqual(
            fragments,
            ["(totalAchievementCount.formatted())", "(count)", "(count)"]
        )
    }

    func testScannerKeepsOrdinaryParenthesesAndComments() {
        let source = #"""
        // "記念石(totalAchievementCount.formatted())" in a comment is fine.
        /* "(count.formatted())" */
        let unit = "item(s)"
        let language = "(ja)"
        let note = "成果メモ（任意）"
        let raw = #"\(value)"#
        let multiLine = """
            laneStart=\(age(lastLaneIntervalStartAt)) \
            done
            """
        """#
        let fragments = SwiftStringLiteralScanner.literals(in: source)
            .flatMap { SwiftStringLiteralScanner.suspiciousFragments(in: $0.text) }

        XCTAssertEqual(fragments, [])
    }
}

/// A small Swift lexer: enough to find string literals, skip comments and
/// raw strings, and drop interpolation segments (whose own nested literals
/// are still returned).
private enum SwiftStringLiteralScanner {
    struct Literal {
        let text: String
        let line: Int
    }

    private static let placeholder = "\u{FFFC}"
    private static let pattern = try! NSRegularExpression(
        pattern: #"\(([A-Za-z_][A-Za-z0-9_]*)((?:\.[A-Za-z_][A-Za-z0-9_]*|\(\))*)\)"#
    )

    /// Parenthesised text that reads like a lost interpolation: a member
    /// access or call, a lowerCamelCase name, or a name written directly
    /// against Japanese text. Plain words such as "(s)" or "(ja)" pass.
    static func suspiciousFragments(in text: String) -> [String] {
        let nsText = text as NSString
        return pattern.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ).compactMap { match in
            if match.range.location > 0,
               nsText.substring(with: NSRange(location: match.range.location - 1, length: 1)) == "\\" {
                return nil
            }
            let identifier = nsText.substring(with: match.range(at: 1))
            let suffix = nsText.substring(with: match.range(at: 2))
            let isLowerCamel = identifier.first?.isLowercase == true
                && identifier.contains { $0.isUppercase }
            let before = match.range.location > 0
                ? nsText.substring(with: NSRange(location: match.range.location - 1, length: 1))
                : ""
            let afterLocation = match.range.location + match.range.length
            let after = afterLocation < nsText.length
                ? nsText.substring(with: NSRange(location: afterLocation, length: 1))
                : ""
            let touchesNonASCII = [before, after].contains { character in
                character.unicodeScalars.contains { $0.value > 0x7F && $0 != "\u{FFFC}" }
            }
            guard !suffix.isEmpty || isLowerCamel || touchesNonASCII else { return nil }
            return nsText.substring(with: match.range)
        }
    }

    static func literals(in source: String) -> [Literal] {
        var scanner = Cursor(bytes: Array(source.utf8))
        var result: [Literal] = []
        scanner.scanCode(until: nil, into: &result)
        return result
    }

    private struct Cursor {
        let bytes: [UInt8]
        var index = 0
        var line = 1

        private static let quote = UInt8(ascii: "\"")
        private static let backslash = UInt8(ascii: "\\")
        private static let hash = UInt8(ascii: "#")
        private static let slash = UInt8(ascii: "/")
        private static let star = UInt8(ascii: "*")
        private static let newline = UInt8(ascii: "\n")
        private static let open = UInt8(ascii: "(")
        private static let close = UInt8(ascii: ")")

        private func byte(at offset: Int) -> UInt8? {
            let position = index + offset
            return position < bytes.count ? bytes[position] : nil
        }

        private mutating func advance(_ count: Int = 1) {
            for _ in 0 ..< count where index < bytes.count {
                if bytes[index] == Self.newline { line += 1 }
                index += 1
            }
        }

        /// Scans code until the closing parenthesis of an interpolation
        /// (`closingParenthesis`) or the end of the file.
        mutating func scanCode(until closingParenthesis: UInt8?, into result: inout [Literal]) {
            var depth = 0
            while let current = byte(at: 0) {
                if current == Self.slash, byte(at: 1) == Self.slash {
                    while let value = byte(at: 0), value != Self.newline { advance() }
                } else if current == Self.slash, byte(at: 1) == Self.star {
                    skipBlockComment()
                } else if current == Self.hash, isRawStringStart() {
                    skipRawString()
                } else if current == Self.quote {
                    scanString(into: &result)
                } else if closingParenthesis != nil, current == Self.open {
                    depth += 1
                    advance()
                } else if let closingParenthesis, current == closingParenthesis {
                    advance()
                    if depth == 0 { return }
                    depth -= 1
                } else {
                    advance()
                }
            }
        }

        private mutating func skipBlockComment() {
            var depth = 0
            while let current = byte(at: 0) {
                if current == Self.slash, byte(at: 1) == Self.star {
                    depth += 1
                    advance(2)
                } else if current == Self.star, byte(at: 1) == Self.slash {
                    depth -= 1
                    advance(2)
                    if depth == 0 { return }
                } else {
                    advance()
                }
            }
        }

        private func isRawStringStart() -> Bool {
            var offset = 0
            while byte(at: offset) == Self.hash { offset += 1 }
            return byte(at: offset) == Self.quote
        }

        /// Raw strings are skipped: their interpolation is `\#(`, and none of
        /// the shipping user-facing text uses them.
        private mutating func skipRawString() {
            var hashes = 0
            while byte(at: 0) == Self.hash { hashes += 1; advance() }
            let isMultiLine = byte(at: 0) == Self.quote
                && byte(at: 1) == Self.quote
                && byte(at: 2) == Self.quote
            advance(isMultiLine ? 3 : 1)
            while byte(at: 0) != nil {
                let closes = isMultiLine
                    ? byte(at: 0) == Self.quote && byte(at: 1) == Self.quote && byte(at: 2) == Self.quote
                    : byte(at: 0) == Self.quote
                let quoteLength = isMultiLine ? 3 : 1
                if closes, (0 ..< hashes).allSatisfy({ byte(at: quoteLength + $0) == Self.hash }) {
                    advance(quoteLength + hashes)
                    return
                }
                advance()
            }
        }

        private mutating func scanString(into result: inout [Literal]) {
            let startLine = line
            let isMultiLine = byte(at: 1) == Self.quote && byte(at: 2) == Self.quote
            advance(isMultiLine ? 3 : 1)
            var text: [UInt8] = []
            var nested: [Literal] = []
            while let current = byte(at: 0) {
                if current == Self.backslash {
                    if byte(at: 1) == Self.open {
                        advance(2)
                        text.append(contentsOf: Array(SwiftStringLiteralScanner.placeholder.utf8))
                        scanCode(until: Self.close, into: &nested)
                    } else {
                        text.append(current)
                        if let escaped = byte(at: 1) { text.append(escaped) }
                        advance(2)
                    }
                    continue
                }
                if isMultiLine {
                    if current == Self.quote, byte(at: 1) == Self.quote, byte(at: 2) == Self.quote {
                        advance(3)
                        break
                    }
                } else if current == Self.quote || current == Self.newline {
                    advance()
                    break
                }
                text.append(current)
                advance()
            }
            result.append(Literal(text: String(decoding: text, as: UTF8.self), line: startLine))
            result.append(contentsOf: nested)
        }
    }
}
