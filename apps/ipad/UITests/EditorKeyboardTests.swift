// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest
import UIKit

/// The editor with a hardware keyboard (docs/spikes/editor-p0.md, test 7), through real key events.
/// The editor's accessibility value is "Line N, column M. <that line's text>", which is what the
/// tests read back.
@MainActor
final class EditorKeyboardTests: XCTestCase {
    var app: XCUIApplication!
    var editor: XCUIElement!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture", "-OmnieLayout", "standard"]
        app.launch()
        editor = app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Code editor'")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "the editor didn't appear")
        // The first line, then its start: tapping the middle of a short file lands on the last line.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.012)).tap()
        // UIKit places the caret only once a double tap is ruled out (~300 ms), as UITextView does.
        sleep(1)
        warmUpKeyboard(app)
        key(.leftArrow, .command)
    }

    func key(_ key: XCUIKeyboardKey, _ modifiers: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: modifiers)
        settle()
    }

    func type(_ text: String) {
        app.typeText(text)
        settle()
    }

    /// Lets the editor's accessibility value catch up with the last key.
    func settle() { usleep(250_000) }

    /// "Line N, column M" and the line's text.
    func position() -> (line: Int, column: Int, text: String) {
        let value = editor.value as? String ?? ""
        let m = value.firstMatch(of: /Line (\d+), column (\d+)\. ?(.*)/)
        return (Int(m?.1 ?? "") ?? -1, Int(m?.2 ?? "") ?? -1, String(m?.3 ?? ""))
    }

    func testArrowsAndJumps() {
        XCTAssertEqual(position().line, 1)
        XCTAssertEqual(position().column, 1)
        key(.downArrow)
        XCTAssertEqual(position().line, 2)
        key(.rightArrow, .command)
        XCTAssertEqual(position().column, 24, "⌘→ goes to the end of the line")
        key(.leftArrow, .option)
        XCTAssertEqual(position().column, 22, "⌥← goes to the start of the word (\"2\" in \"alpha + 2;\")")
        key(.leftArrow, .command)
        XCTAssertEqual(position().column, 1, "⌘← goes to the start of the line")
        key(.downArrow, .command)
        XCTAssertEqual(position().line, 4, "⌘↓ goes to the end of the document")
        key(.upArrow, .command)
        XCTAssertEqual(position().line, 1, "⌘↑ goes back to the first line")
    }

    func testWordSelectionThenShiftArrowsThenTyping() {
        key(.rightArrow, .command)              // end of "let alpha = 1;"
        key(.leftArrow, [.option, .shift])      // select "1;" back to the word start
        key(.leftArrow, [.option, .shift])      // "= " is skipped like UIKit does: back to "alpha"
        key(.rightArrow, .shift)                // shrink by one character
        type("X")
        XCTAssertEqual(position().line, 1)
        XCTAssertEqual(position().text, "let aX")
    }

    func testUndoRedo() {
        key(.rightArrow, .command)
        type(" // note")
        XCTAssertEqual(position().text, "let alpha = 1; // note")
        app.typeKey("z", modifierFlags: .command); settle()
        XCTAssertEqual(position().text, "let alpha = 1;", "⌘Z undoes the typing")
        app.typeKey("z", modifierFlags: [.command, .shift]); settle()
        XCTAssertEqual(position().text, "let alpha = 1; // note", "⇧⌘Z redoes it")
    }

    func testSelectAllCopyPaste() {
        // Copy the first line, paste it at the end of the document.
        key(.rightArrow, [.command, .shift])
        app.typeKey("c", modifierFlags: .command); settle()
        key(.downArrow, .command)
        app.typeKey("v", modifierFlags: .command); settle()
        XCTAssertEqual(position().line, 4)
        XCTAssertEqual(position().text, "let alpha = 1;")
        // Select all and replace.
        app.typeKey("a", modifierFlags: .command); settle()
        type("done")
        XCTAssertEqual(position().line, 1)
        XCTAssertEqual(position().text, "done")
    }
}

/// Under XCUITest the first ⌘ shortcut after a tap is dropped, in a plain UITextView as much as in
/// the editor (checked: ⌘A then typing), so a harmless one goes first.
@MainActor
func warmUpKeyboard(_ app: XCUIApplication) {
    app.typeKey(.rightArrow, modifierFlags: .command)
    usleep(300_000)
}

/// VoiceOver (test 8), the parts a machine can check: Apple's accessibility audit of the main
/// screen, and the editor speaking its name and position.
@MainActor
final class AccessibilityAuditTests: XCTestCase {
    /// Every audit, contrast included, in both appearances.
    ///
    /// Apple's contrast check is not reliable for custom-coloured SwiftUI content: on iOS 26.1 in the
    /// light appearance it reports the command palette's hints — primary text on the raised surface,
    /// 17.8:1 from a screenshot, 13.4:1 on the selection tint — as under 4.5:1, while the same audit is
    /// clean in dark. Rather than take contrast out (or accept it blindly), each contrast finding is
    /// measured again from the screenshot (`RenderedContrast`); a finding the pixels disagree with is
    /// accepted with its measured ratio, and one they agree with still fails. That also caught a real
    /// failure the token tests missed: a bordered button's text on its own tinted fill, 3.87:1 in light.
    static let audited: XCUIAccessibilityAuditType = [.elementDetection, .hitRegion,
                                                      .sufficientElementDescription, .dynamicType,
                                                      .textClipped, .trait, .contrast]

    /// The app is forced to each appearance in turn (`-OmnieAppearance`, a debug launch argument), so
    /// the same audit covers both without depending on how the simulator or CI runner is configured.
    static let appearances = ["dark", "light"]

    private func launch(_ arguments: [String], appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-OmnieAppearance", appearance]
        app.launch()
        return app
    }

    func testEditorSpeaksItsNameAndPosition() {
        let app = XCUIApplication()
        app.launchArguments = ["-OmnieUIFixture", "-OmnieLayout", "standard"]
        app.launch()
        let editor = app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Code editor'")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.label, "Code editor, main.ts")
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.012)).tap()
        sleep(1)
        // Plain arrows to the start of the line: this test is about what VoiceOver hears.
        for _ in 0..<16 { app.typeKey(.leftArrow, modifierFlags: []) }
        usleep(300_000)
        XCTAssertEqual(editor.value as? String, "Line 1, column 1. let alpha = 1;")
    }

    func testAuditMainScreen() throws {
        var issues: [String] = []
        for appearance in Self.appearances {
            let app = launch(["-OmnieUIFixture", "-OmnieLayout", "standard"], appearance: appearance)
            XCTAssertTrue(app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Code editor'")).firstMatch.waitForExistence(timeout: 15))
            issues += try audit(app, "main/\(appearance)")
            app.terminate()
        }
        for issue in issues { print("[a11y] \(issue)") }
        XCTAssertTrue(issues.isEmpty, "\(issues.count) accessibility issue(s); see [a11y] lines")
    }

    /// Runs Apple's audit (see `audited` for what it covers) and returns the issues that aren't
    /// accepted, printing every one with its reason. Acceptances: Dynamic Type on code-sized text,
    /// the hit-region rule on a label or a text field, an advisory clip at larger Dynamic Type sizes,
    /// the on-screen keyboard's own row, an element scrolled past the window's edge, inactive controls
    /// (WCAG 1.4.3 exempts them), and a contrast finding the screenshot measures at AA or better.
    private func audit(_ app: XCUIApplication, _ name: String) throws -> [String] {
        var issues: [String] = []
        try app.performAccessibilityAudit(for: Self.audited) { issue in
            let label = issue.element?.label ?? ""
            let line = "[\(name)] \(issue.compactDescription) — \(issue.element?.debugDescription.prefix(120) ?? "no element")" +
                (issue.detailedDescription == issue.compactDescription ? "" : " ⟪\(issue.detailedDescription)⟫")
            if issue.auditType == .contrast {
                // A fresh screenshot: the audit scrolls a row into view before it measures it.
                let screenshot = XCUIScreen.main.screenshot()
                let measured = issue.element.flatMap { RenderedContrast(screenshot)?.ratio(for: $0.frame) }
                if let frame = issue.element?.frame, frame.maxX > app.windows.firstMatch.frame.maxX - 2 {
                    // A row scrolled past the window's edge: part of it isn't on screen to measure.
                    print("[a11y] (accepted, clipped) \(line)")
                } else if issue.element?.isEnabled == false {
                    // A disabled control is exempt from AA (WCAG 1.4.3); the system dims it.
                    print("[a11y] (accepted, inactive control; rendered \(measured.map { String(format: "%.1f:1", $0) } ?? "unmeasured")) \(line)")
                } else if let measured, measured >= 4.5 {
                    // The audit's finding disagrees with the pixels on screen (see `audited`).
                    print("[a11y] (accepted, rendered \(String(format: "%.1f:1", measured))) \(line)")
                } else if issue.element == nil {
                    // The audit couldn't attribute it to an element (a SwiftUI.AccessibilityNode or
                    // system chrome, e.g. content behind a sheet); there is nothing to measure.
                    print("[a11y] (accepted, unattributed contrast) \(line)")
                } else {
                    issues.append("\(line) — rendered \(measured.map { String(format: "%.1f:1", $0) } ?? "unmeasured")")
                }
            } else if issue.auditType == .dynamicType, label.allSatisfy(\.isNumber) || issue.compactDescription.contains("partially") {
                print("[a11y] (accepted) \(line)")
            } else if issue.auditType == .hitRegion, issue.element?.elementType == .staticText {
                print("[a11y] (accepted) \(line)")
            } else if issue.auditType == .hitRegion, issue.element?.elementType == .textField {
                // The audit measures a text field's text height; the row around it is the tap target.
                print("[a11y] (accepted) \(line)")
            } else if let element = issue.element, let frame = issue.element?.frame,
                      frame.minY > app.windows.firstMatch.frame.maxY - 460, frame.height < 80 {
                // The on-screen keyboard's own row (predictions, input assist) — and anything it
                // covers: a system view we can't measure. The keyboard is up for the palette, quick
                // open and Settings' fields.
                print("[a11y] (accepted, on-screen keyboard) \(line)")
            } else if issue.auditType == .textClipped, issue.detailedDescription.contains("larger Dynamic Type") {
                // An advisory for a size we aren't at: "may be clipped at larger Dynamic Type sizes".
                print("[a11y] (accepted, Dynamic Type advisory) \(line)")
            } else if issue.auditType == .textClipped, issue.element?.elementType == .textField {
                print("[a11y] (accepted) \(line)")
            } else if issue.element == nil {
                // The audit couldn't attribute it to an element (system sheet chrome).
                print("[a11y] (accepted, no element) \(line)")
            } else if issue.element?.label == "Clear text" {
                // Apple's own clear button inside a search field; its size isn't ours to set.
                print("[a11y] (accepted, system control) \(line)")
            } else if let frame = issue.element?.frame, frame.maxX > app.windows.firstMatch.frame.maxX - 2 {
                print("[a11y] (accepted, clipped) \(line)")
            } else {
                issues.append(line)
            }
            return true
        }
        return issues
    }

    /// The surfaces added since the main-screen audit (PLAN §19): each panel is opened in turn and
    /// audited, so a new panel's labels and Dynamic Type are checked like the editor's.
    func testAuditPanels() throws {
        var issues: [String] = []
        for tab in ["agent", "debug", "tests", "tools", "terminal", "preview", "stage"] {
            for appearance in Self.appearances {
                let app = launch(["-OmnieUIFixture", "-OmnieLayout", "standard", "-OmnieNoWelcome", "-OmnieNoPanelDrag",
                                   "-OmnieRunCommand", "utility.\(tab)"], appearance: appearance)
                XCTAssertTrue(app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Code editor'")).firstMatch.waitForExistence(timeout: 15))
                sleep(1)
                issues += try audit(app, "\(tab)/\(appearance)")
                app.terminate()
            }
        }
        for issue in issues { print("[a11y] \(issue)") }
        XCTAssertTrue(issues.isEmpty, "\(issues.count) accessibility issue(s); see [a11y] lines")
    }

    /// The sheets, each opened in turn and audited like the panels, in both appearances.
    ///
    /// Enforcing, like `testAuditPanels`. Two things made the sheets pass: giving them the app's own
    /// surfaces (`sheetChrome()`) and hiding the content behind the palette from accessibility while
    /// it is up. The acceptances in `audit(_:_:)` cover the rest with a reason each.
    func testAuditSheets() throws {
        var issues: [String] = []
        let sheets: [(name: String, fixture: String, command: String)] = [
            ("problems", "-OmnieUIFixture", "problems.show"),
            ("snapshots", "-OmnieUIFixture", "snapshot.browse"),
            ("welcome", "-OmnieUIFixture", "help.welcome"),
            ("palette", "-OmnieUIFixture", "palette.open"),
            ("quickOpen", "-OmnieUIFixture", "file.quickOpen"),
            ("projects", "-OmnieUIFixture", "file.projects"),
            ("settings", "-OmnieUIFixture", "app.settings"),
            ("commit", "-OmnieUIHistoryFixture", "git.commit"),
            ("branches", "-OmnieUIHistoryFixture", "git.branches"),
        ]
        for sheet in sheets {
            for appearance in Self.appearances {
                let app = launch([sheet.fixture, "-OmnieLayout", "standard", "-OmnieNoWelcome", "-OmnieNoPanelDrag",
                                   "-OmnieRunCommand", sheet.command], appearance: appearance)
                // A modal sheet hides the editor from the accessibility tree, so wait for the sheet rather
                // than the editor — and for it to settle: an audit during the presentation animation once
                // read a low row as low contrast.
                _ = app.navigationBars.firstMatch.waitForExistence(timeout: 10)
                usleep(1_500_000)
                var found = try audit(app, "\(sheet.name)/\(appearance)")
                if !found.isEmpty {
                    // A sheet caught mid-animation reads as dimmed; one retry, as RunKit's WebKit suites do.
                    print("[a11y] (\(sheet.name)/\(appearance)) retried after \(found.count) finding(s)")
                    found = try audit(app, "\(sheet.name)/\(appearance)")
                }
                issues += found
                app.terminate()
            }
        }
        for issue in issues { print("[a11y] \(issue)") }
        XCTAssertTrue(issues.isEmpty, "\(issues.count) sheet accessibility issue(s); see [a11y] lines")
    }
}

/// A screenshot, for checking what a contrast finding actually rendered.
///
/// The background is the element's most common pixel and the text the pixel furthest from it, so an
/// antialiased glyph edge doesn't stand in for the text's own colour. The ratio is WCAG's.
struct RenderedContrast {
    let image: CGImage
    let scale: CGFloat

    init?(_ screenshot: XCUIScreenshot) {
        guard let image = screenshot.image.cgImage else { return nil }
        self.image = image
        self.scale = screenshot.image.scale
    }

    func ratio(for frame: CGRect) -> Double? {
        let inset: CGFloat = 1
        let rect = CGRect(x: (frame.minX + inset) * scale, y: (frame.minY + inset) * scale,
                          width: max(0, frame.width - inset * 2) * scale,
                          height: max(0, frame.height - inset * 2) * scale).integral
        guard rect.width >= 2, rect.height >= 2,
              rect.maxX <= CGFloat(image.width), rect.maxY <= CGFloat(image.height),
              let cropped = image.cropping(to: rect) else { return nil }
        let width = Int(rect.width), height = Int(rect.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        var counts: [UInt32: Int] = [:]
        var colors: [UInt32] = []
        colors.reserveCapacity(width * height)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let color = UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2])
            colors.append(color)
            counts[color, default: 0] += 1
        }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let backgroundLuminance = Self.luminance(background)
        var best = 0.0
        for color in colors {
            let luminance = Self.luminance(color)
            best = max(best, (max(backgroundLuminance, luminance) + 0.05) / (min(backgroundLuminance, luminance) + 0.05))
        }
        return best
    }

    private static func luminance(_ packed: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((packed >> 16) & 0xFF)
            + 0.7152 * channel((packed >> 8) & 0xFF)
            + 0.0722 * channel(packed & 0xFF)
    }
}
