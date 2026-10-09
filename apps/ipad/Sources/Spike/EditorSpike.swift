// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import DesignKit
import EditorKit
import LangKit
import QuartzCore
import Runestone
import UIKit

/// The P0 editor spike, tests 1 to 4 (PLAN §5.1.5), run against our engine and against a plain
/// UITextView (the TextKit 2 baseline). The numbers only count from a release build on the iPad;
/// simulator runs check that the harness works.
@MainActor
final class EditorSpike {
    struct Result: Codable {
        var engine: String
        var test: String
        var metrics: [String: Double]
        var pass: Bool?
        var note: String?
    }

    struct Report: Codable {
        var device: String
        var system: String
        var build: String
        var date: Date
        var results: [Result]
    }

    enum Engine: String, CaseIterable {
        case omnie = "Omnie engine, TypeScript highlighting"
        /// The same engine with no language: separates the engine's cost from tree-sitter's.
        case omniePlain = "Omnie engine, plain text"
        /// The TextKit 2 baseline. Note: no syntax highlighting.
        case textKit = "UITextView (TextKit 2)"

        var tag: String { switch self { case .omnie: "omnie"; case .omniePlain: "omnie-plain"; case .textKit: "textkit" } }
    }

    private let host: UIView
    private var results: [Result] = []
    var log: (String) -> Void = { print("[spike]", $0) }

    init(host: UIView) { self.host = host }

    // MARK: Fixtures

    /// ~100k lines of varied, realistic TypeScript.
    static func makeLargeTypeScript(lines target: Int = 100_000) -> String {
        var out = ""
        out.reserveCapacity(target * 40)
        var n = 0, i = 0
        while n < target {
            let block = """
            // Module \(i): order handling
            export interface Order\(i) {
              id: string;
              items: Array<{ sku: string; qty: number; price: number }>;
              createdAt: Date;
            }

            export function total\(i)(order: Order\(i)): number {
              return order.items.reduce((sum, item) => sum + item.qty * item.price, 0);
            }

            export class OrderStore\(i) {
              private readonly orders = new Map<string, Order\(i)>();
              add(order: Order\(i)): void {
                if (this.orders.has(order.id)) throw new Error(`duplicate ${order.id}`);
                this.orders.set(order.id, order);
              }
              get count(): number { return this.orders.size; }
            }

            """
            out += block
            n += 21
            i += 1
        }
        return out
    }

    /// One 20,000-character minified line.
    static func makeMinifiedLine(characters: Int = 20_000) -> String {
        let chunk = "function a(b,c){return b.map(function(d){return d*c+1}).filter(Boolean)};var e=[1,2,3];"
        var line = ""
        while line.count < characters { line += chunk }
        return String(line.prefix(characters)) + "\n"
    }

    // MARK: Running

    func runAll() async -> Report {
        results = []
        let big = Self.makeLargeTypeScript()
        let minified = Self.makeMinifiedLine()
        log("fixtures: \(big.utf8.count / 1024) KB TypeScript, \(minified.count) char line")
        // `-OmnieSpikeEngine <tag>` limits the run to one engine (for profiling).
        let args = ProcessInfo.processInfo.arguments
        let only = args.firstIndex(of: "-OmnieSpikeEngine").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        for engine in Engine.allCases where only == nil || engine.tag == only {
            // `-OmnieSpikeTests 2,3` limits the run to some tests (for profiling).
            let tests = args.firstIndex(of: "-OmnieSpikeTests").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                .map { Set($0.split(separator: ",").map(String.init)) }
            func wants(_ n: String) -> Bool { tests?.contains(n) ?? true }
            if wants("1") { await test1(engine, text: big) }
            if wants("2") { await test2(engine, text: big) }
            if wants("3") { await test3(engine, text: big) }
            if wants("4") { await test4(engine, text: minified) }
        }
        let report = Report(device: UIDevice.current.model + " " + Self.machine(),
                            system: UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
                            build: Self.buildKind, date: .now, results: results)
        save(report)
        return report
    }

    // Test 1: open the 100k-line file. First paint ≤ 300 ms, memory for the file ≤ 150 MB.
    private func test1(_ engine: Engine, text: String) async {
        let before = Self.footprintMB()
        let start = CACurrentMediaTime()
        let view = await makeView(engine, text: text)
        await nextFrame()
        let firstPaint = (CACurrentMediaTime() - start) * 1000
        let memory = Self.footprintMB() - before
        // The engine paints plain text first and highlights when the background parse lands;
        // memory is also measured after that, and the larger figure is the one judged.
        var metrics = ["firstPaintMs": firstPaint, "memoryMB": memory]
        var judgedMemory = memory
        if engine == .omnie, let controller = objc_getAssociatedObject(view, &Self.controllerKey) as? CodeEditorController {
            if !Self.highlighted(controller) {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    controller.onHighlighted = { done.resume() }
                }
            }
            let highlightedMs = (CACurrentMediaTime() - start) * 1000
            let memoryHighlighted = Self.footprintMB() - before
            metrics["highlightedMs"] = highlightedMs
            metrics["memoryHighlightedMB"] = memoryHighlighted
            judgedMemory = max(memory, memoryHighlighted)
        }
        record(engine, "1 open 100k lines", metrics, pass: firstPaint <= 300 && judgedMemory <= 150)
        view.removeFromSuperview()
    }

    // Test 2: fling-scroll, wrap off then on. Hitch ratio < 5 ms/s, no scroller jumps.
    // "fling" moves at 8,000 pt/s (about the top speed of an iOS fling) for 3 s down and 3 s up; that's
    // the pass/fail run. "indicator drag" sweeps the whole file in 4 s, like dragging the scroll indicator;
    // it's recorded for comparison only.
    private func test2(_ engine: Engine, text: String) async {
        for wrap in [false, true] {
            for mode in [ScrollDriver.Mode.fling(pointsPerSecond: 8_000, seconds: 6), .sweep(seconds: 4)] {
                let view = await makeView(engine, text: text, wrap: wrap)
                guard let scroll = view as? UIScrollView else { continue }
                await nextFrame()
                let stats = await drive(scroll, mode)
                let isFling = if case .fling = mode { true } else { false }
                record(engine, "2 scroll \(isFling ? "fling" : "indicator drag") (wrap \(wrap ? "on" : "off"))",
                       ["hitchMsPerS": stats.hitchRatio, "worstFrameMs": stats.worstFrame, "scrollerJumps": Double(stats.jumps),
                        "contentHeightChanges": Double(stats.heightChanges)],
                       pass: isFling ? (stats.hitchRatio < 5 && stats.jumps == 0) : nil,
                       note: stats.longFrames.isEmpty ? nil : "long frames (s, ms, y): " + stats.longFrames
                        .map { String(format: "%.2f/%.0f/%.0f", $0.0, $0.1, $0.2) }.joined(separator: " "))
                view.removeFromSuperview()
            }
        }
    }

    // Test 3: type 200 characters mid-file. Main-thread work per keystroke ≤ 4 ms at p95.
    // Run twice: with the on-screen keyboard (info: UIKit's keyboard bookkeeping runs on every change,
    // for any text view) and with no on-screen keyboard, like typing on a Magic Keyboard (pass/fail).
    private func test3(_ engine: Engine, text: String) async {
        for onScreenKeyboard in [false, true] {
            let view = await makeView(engine, text: text)
            await nextFrame()
            // Runestone's TextView hosts an inner UITextInput view; type through it, the real keyboard path.
            guard let input = (view as? (UIView & UITextInput))
                    ?? (view.subviews.first { $0 is UITextInput } as? (UIView & UITextInput)) else {
                record(engine, "3 type 200 chars mid-file", [:], pass: false, note: "not run: no UITextInput found")
                view.removeFromSuperview()
                return
            }
            if !onScreenKeyboard {
                // An empty input view: no software keyboard, as with a hardware keyboard attached.
                (view as? Runestone.TextView)?.inputView = UIView()
                (view as? UITextView)?.inputView = UIView()
            }
            _ = view.becomeFirstResponder()
            setCaret(view, at: (text as NSString).length / 2)
            await nextFrame()
            var durations: [Double] = []
            let typed = Array("const typed = items.filter((x) => x.qty > 0).map((x) => x.sku);\n")
            for k in 0..<200 {
                let t0 = CACurrentMediaTime()
                input.insertText(String(typed[k % typed.count]))
                view.layoutIfNeeded()
                durations.append((CACurrentMediaTime() - t0) * 1000)
                await Task.yield()
            }
            durations.sort()
            let p95 = durations[Int(Double(durations.count) * 0.95)]
            record(engine, "3 type 200 chars mid-file (\(onScreenKeyboard ? "on-screen keyboard" : "no on-screen keyboard"))",
                   ["p50Ms": durations[durations.count / 2], "p95Ms": p95, "maxMs": durations.last ?? 0],
                   pass: onScreenKeyboard ? nil : p95 <= 4)
            view.resignFirstResponder()
            view.removeFromSuperview()
            await nextFrame()
        }
    }

    // Test 4: a single 20k-character line. No main-thread stall > 100 ms placing the caret or scrolling.
    private func test4(_ engine: Engine, text: String) async {
        let start = CACurrentMediaTime()
        let view = await makeView(engine, text: text, wrap: false, language: .javascript)
        await nextFrame()
        let open = (CACurrentMediaTime() - start) * 1000
        var worst = 0.0
        for location in [10_000, 19_990, 5, 15_000] {
            let t0 = CACurrentMediaTime()
            setCaret(view, at: location)
            if let scroll = view as? UIScrollView {
                scroll.setContentOffset(CGPoint(x: max(0, scroll.contentSize.width * Double(location) / 20_000 - 200), y: 0), animated: false)
            }
            view.layoutIfNeeded()
            worst = max(worst, (CACurrentMediaTime() - t0) * 1000)
            await nextFrame()
        }
        record(engine, "4 one 20k-char line", ["openMs": open, "worstStallMs": worst], pass: worst <= 100)
        view.removeFromSuperview()
    }

    // MARK: Helpers

    private func makeView(_ engine: Engine, text: String, wrap: Bool = false, language: Language = .typescript) async -> UIView {
        let frame = host.bounds
        switch engine {
        case .omnie, .omniePlain:
            let controller = CodeEditorController(theme: EditorTheme(palette: .dark, density: .regular))
            controller.textView.isLineWrappingEnabled = wrap
            controller.textView.frame = frame
            host.addSubview(controller.textView)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                controller.onLoaded = { done.resume() }
                controller.onHighlighted = { Self.markHighlighted(controller) }
                controller.load(text, language: engine == .omnie ? language : nil)
            }
            controller.textView.layoutIfNeeded()
            objc_setAssociatedObject(controller.textView, &Self.controllerKey, controller, .OBJC_ASSOCIATION_RETAIN)
            return controller.textView
        case .textKit:
            let view = UITextView(frame: frame, textContainer: nil)
            view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            view.autocorrectionType = .no
            view.textContainer.widthTracksTextView = wrap
            if !wrap { view.textContainer.size = CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude) }
            view.text = text
            host.addSubview(view)
            view.layoutIfNeeded()
            return view
        }
    }

    private static var controllerKey: UInt8 = 0
    private static var highlightedKey: UInt8 = 0
    private static func markHighlighted(_ c: CodeEditorController) { objc_setAssociatedObject(c, &highlightedKey, true, .OBJC_ASSOCIATION_RETAIN) }
    private static func highlighted(_ c: CodeEditorController) -> Bool { objc_getAssociatedObject(c, &highlightedKey) as? Bool ?? false }

    private func setCaret(_ view: UIView, at location: Int) {
        if let tv = view as? Runestone.TextView { tv.selectedRange = NSRange(location: location, length: 0) }
        if let tv = view as? UITextView { tv.selectedRange = NSRange(location: location, length: 0) }
    }

    private struct ScrollStats {
        var hitchRatio: Double; var worstFrame: Double; var jumps: Int; var heightChanges: Int
        /// (seconds into the scroll, frame ms, contentOffset.y) for each long frame.
        var longFrames: [(Double, Double, Double)] = []
    }

    /// Drives contentOffset with a display link and measures late frames.
    private func drive(_ scroll: UIScrollView, _ mode: ScrollDriver.Mode) async -> ScrollStats {
        await withCheckedContinuation { (done: CheckedContinuation<ScrollStats, Never>) in
            let driver = ScrollDriver(scroll: scroll, mode: mode) { done.resume(returning: $0) }
            driver.begin()
        }
    }

    private final class ScrollDriver: NSObject {
        enum Mode {
            case fling(pointsPerSecond: Double, seconds: Double)
            case sweep(seconds: Double)
            var seconds: Double { switch self { case .fling(_, let s), .sweep(let s): s } }
        }
        let scroll: UIScrollView
        let mode: Mode
        var seconds: Double { mode.seconds }
        let finish: (ScrollStats) -> Void
        var link: CADisplayLink?
        var start = 0.0, last = 0.0, hitch = 0.0, worst = 0.0
        var lastHeight = 0.0, heightChanges = 0, jumps = 0
        var lastIndicatorFraction = 0.0
        var longFrames: [(Double, Double, Double)] = []

        init(scroll: UIScrollView, mode: Mode, finish: @escaping (ScrollStats) -> Void) {
            self.scroll = scroll; self.mode = mode; self.finish = finish
        }

        func begin() {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc func tick(_ link: CADisplayLink) {
            let now = link.timestamp
            if start == 0 { start = now; last = now; lastHeight = scroll.contentSize.height; return }
            let expected = link.targetTimestamp - link.timestamp
            let frame = now - last
            if frame > expected * 1.5 {
                hitch += (frame - expected) * 1000
                if longFrames.count < 12 { longFrames.append((now - start, frame * 1000, scroll.contentOffset.y)) }
            }
            worst = max(worst, frame * 1000)
            last = now
            let t = (now - start) / seconds
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            switch mode {
            case .sweep:
                let fraction = t < 0.5 ? t * 2 : max(0, 2 - t * 2)
                scroll.contentOffset.y = maxY * fraction
            case .fling(let speed, let total):
                let elapsed = now - start
                let distance = elapsed < total / 2 ? speed * elapsed : max(0, speed * (total - elapsed))
                scroll.contentOffset.y = min(maxY, distance)
            }
            let height = scroll.contentSize.height
            if abs(height - lastHeight) > 0.5 { heightChanges += 1 }
            // A scroller jump: the indicator's relative position moves against the scroll direction.
            let indicator = maxY > 0 ? scroll.contentOffset.y / maxY : 0
            // Only meaningful when the indicator should move monotonically within each half.
            let goingDown = t < 0.5
            if goingDown ? indicator < lastIndicatorFraction - 0.02 : indicator > lastIndicatorFraction + 0.02 { jumps += 1 }
            lastIndicatorFraction = indicator
            lastHeight = height
            if t >= 1 {
                link.invalidate()
                let elapsed = now - start
                finish(ScrollStats(hitchRatio: hitch / elapsed, worstFrame: worst, jumps: jumps, heightChanges: heightChanges,
                                   longFrames: longFrames))
            }
        }
    }

    /// Lets pending layout and rendering happen. (A CATransaction completion block never fires when
    /// there's nothing to commit, which hung a run, so this flushes and sleeps for two frames instead.)
    private func nextFrame() async {
        CATransaction.flush()
        try? await Task.sleep(for: .milliseconds(34))
    }

    private func record(_ engine: Engine, _ test: String, _ metrics: [String: Double], pass: Bool?, note: String? = nil) {
        results.append(Result(engine: engine.rawValue, test: test, metrics: metrics, pass: pass, note: note))
        let numbers = metrics.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.1f", $0.value))" }.joined(separator: " ")
        let verdict = switch pass { case true?: "PASS"; case false?: "FAIL"; case nil: "INFO" }
        log("\(verdict) [\(engine.tag)] \(test): \(numbers)\(note.map { " — \($0)" } ?? "")")
    }

    private func save(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let name = "editor-spike-\(Self.buildKind)-\(Int(Date().timeIntervalSince1970)).json"
        let url = URL.documentsDirectory.appendingPathComponent(name)
        try? encoder.encode(report).write(to: url)
        log("saved \(url.path)")
    }

    static var buildKind: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// The app's physical memory footprint, as jetsam counts it.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
