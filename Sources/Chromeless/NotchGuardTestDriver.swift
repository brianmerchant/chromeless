// Automated notch-guard test run (CHROMELESS_NOTCH_TEST=<dir>). Loads one URL,
// then records, into <dir>/<name>.json and PNGs:
//   cold    first visit, no learned hint: detector verdicts, timeline of the
//           viewport height against first-contentful-paint (a change after FCP
//           is a visible shift), window pixels captured from the screen
//   click   a real NSEvent click on the obscured control (or, if nothing was
//           obscured, on a top-band control beside the housing) and, for a text
//           field, real key events
//   scroll  real scroll-wheel events; checks the page moved and whether the
//           decision changed mid-scroll
//   warm    the same URL again: the learned decision is applied at commit
// With CHROMELESS_NOTCH_TEST_FULLSCREEN=1 (plus CHROMELESS_FULLPANEL=1 and
// CHROMELESS_NOTCH_GUARD=1, no simulation) the run happens in real FullPanel
// fullscreen against the physical housing geometry, then exits fullscreen.
// Nothing here simulates rendering: screenshots are screencapture of the
// actual window; the "-view" variant only paints the (simulated) housing black.

import Cocoa
import WebKit
#if canImport(FullPanelKit)
import FullPanelKit
#endif

final class NotchGuardTestDriver {
    private let controller: BrowserWindowController
    private let url: URL
    private let directory: String
    private let name: String
    private var report: [String: Any] = [:]
    private var started = Date()
    private var retain: NotchGuardTestDriver?
    private let fullscreen = ProcessInfo.processInfo.environment["CHROMELESS_NOTCH_TEST_FULLSCREEN"] == "1"

    init(controller: BrowserWindowController, url: URL, directory: String) {
        self.controller = controller
        self.url = url
        self.directory = directory
        let env = ProcessInfo.processInfo.environment
        name = env["CHROMELESS_NOTCH_TEST_NAME"]
            ?? (url.isFileURL ? url.deletingPathExtension().lastPathComponent : (url.host ?? "page"))
    }

    private var webView: WKWebView { controller.webView }
    private var notchGuard: NotchGuard? { controller.notchGuard }

    func start() {
        retain = self
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        report["name"] = name
        report["url"] = url.absoluteString
        report["date"] = ISO8601DateFormatter().string(from: Date())
        if fullscreen {
            enterFullscreen()
            return
        }
        if let w = controller.window, let screen = w.screen ?? NSScreen.main {
            // Pin the window under the menu bar at the top-left of the screen.
            w.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.maxY))
            report["window"] = NSStringFromRect(w.frame)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            self.report["error"] = "timeout"
            self.finish()
        }
        waitForSettle(minimum: 3.0) { self.phaseCold() }
    }

    // MARK: Phases

    private func phaseCold() {
        // CHROMELESS_NOTCH_TEST_EVAL: extra diagnostic JS (guard world) -> report.eval
        if let probe = ProcessInfo.processInfo.environment["CHROMELESS_NOTCH_TEST_EVAL"], report["eval"] == nil {
            js(probe) { value in
                self.report["eval"] = self.parse(value) ?? NSNull()
                self.phaseCold()
            }
            return
        }
        snapshotState("cold") {
            self.capture("1-cold") {
                self.phaseClick()
            }
        }
    }

    private func phaseClick() {
        pickTarget { target in
            guard let target, let rect = target["viewRect"] as? [Double], rect.count == 4 else {
                self.report["click"] = ["skipped": "no suitable control found"]
                self.phaseScroll()
                return
            }
            let point = NSPoint(x: rect[0] + rect[2] / 2, y: rect[1] + rect[3] / 2)
            self.click(at: point)
            self.after(0.6) {
                self.js("JSON.stringify(window.__ngTest.verifyClick())") { verdict in
                    var result = target
                    result["clickedAt"] = [point.x, point.y]
                    result["result"] = self.parse(verdict)
                    let isText = (target["text"] as? Bool) == true
                    guard isText else {
                        self.report["click"] = result
                        self.phaseScroll()
                        return
                    }
                    self.type("notch")
                    self.after(0.5) {
                        self.js("JSON.stringify(window.__ngTest.verifyTyping('notch'))") { typed in
                            result["typing"] = self.parse(typed)
                            self.report["click"] = result
                            // (No Esc: in Chromeless a bare Esc returns to the start page.)
                            self.js("window.__ngTest.clear()") { _ in
                                self.after(0.3) { self.phaseScroll() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func phaseScroll() {
        let before = notchGuard?.engaged ?? false
        js("scrollY") { y0 in
            self.scroll(by: -120, times: 8)
            self.after(1.2) {
                self.js("JSON.stringify({scrollY, scrollHeight: document.scrollingElement ? document.scrollingElement.scrollHeight : 0, innerHeight, report: window.__chromelessNotchGuard.report()})") { raw in
                    let after = self.parse(raw) as? [String: Any] ?? [:]
                    let y1 = after["scrollY"] as? Double ?? 0
                    self.report["scroll"] = [
                        "scrollYBefore": y0 as? Double ?? 0, "scrollYAfter": y1,
                        "scrolled": y1 > ((y0 as? Double) ?? 0) + 50,
                        "scrollable": (after["scrollHeight"] as? Double ?? 0) > (after["innerHeight"] as? Double ?? 0) + 10,
                        "scrollHeight": after["scrollHeight"] ?? 0,
                        "engagedBefore": before, "engagedAfter": self.notchGuard?.engaged ?? false,
                        "page": after["report"] ?? NSNull(),
                    ]
                    self.capture("2-scrolled") {
                        self.scroll(by: 120, times: 12)
                        self.after(0.8) { self.phaseLayout() }
                    }
                }
            }
        }
    }

    /// Optional: CHROMELESS_NOTCH_TEST_ZOOM=<factor>, CHROMELESS_NOTCH_TEST_RESIZE=<width>.
    private func phaseLayout() {
        let env = ProcessInfo.processInfo.environment
        if let z = env["CHROMELESS_NOTCH_TEST_ZOOM"].flatMap(Double.init), report["zoomFactor"] == nil {
            controller.setPageZoom(CGFloat(z))
            after(1.5) {
                self.snapshotState("zoom") {
                    self.capture("4-zoom") {
                        self.controller.setPageZoom(1.0)
                        self.after(1.5) {
                            self.snapshotState("unzoom") { self.report["zoomFactor"] = z; self.phaseLayout() }
                        }
                    }
                }
            }
            return
        }
        if let w = env["CHROMELESS_NOTCH_TEST_RESIZE"].flatMap(Double.init), report["resizeWidth"] == nil,
           let window = controller.window {
            let original = window.frame
            var f = original
            f.size.width = CGFloat(w)
            window.setFrame(f, display: true)
            after(1.5) {
                self.snapshotState("resized") {
                    self.capture("5-resized") {
                        window.setFrame(original, display: true)
                        self.after(1.5) {
                            self.snapshotState("restored") { self.report["resizeWidth"] = w; self.phaseLayout() }
                        }
                    }
                }
            }
            return
        }
        phaseWarm()
    }

    private func phaseWarm() {
        let mark = notchGuard?.events.count ?? 0
        controller.navigate(to: url)
        started = Date()
        waitForSettle(minimum: 2.5) {
            self.report["warmEvents"] = self.eventsSince(mark)
            self.snapshotState("warm") {
                self.capture("3-warm") { self.finish() }
            }
        }
    }

    private func enterFullscreen() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            self.report["error"] = "timeout"
            self.finish()
        }
        after(1.0) {
            self.controller.window?.toggleFullScreen(nil)
            var waited = 0.0
            func poll() {
                waited += 0.25
                if self.notchGuard?.housing == nil && waited < 12 { self.after(0.25, poll); return }
                self.report["fullscreen"] = self.fullscreenState()
                self.report["window"] = NSStringFromRect(self.controller.window?.frame ?? .zero)
                self.started = Date()
                // Fresh decision against the real geometry: reload the page.
                self.controller.navigate(to: self.url)
                self.waitForSettle(minimum: 2.5) { self.phaseCold() }
            }
            self.after(0.25, poll)
        }
    }

    private func fullscreenState() -> [String: Any] {
        var state: [String: Any] = [
            "styleMaskFullScreen": controller.window?.styleMask.contains(.fullScreen) ?? false,
            "housing": notchGuard?.housing.map { NSStringFromRect($0) } ?? "none",
            "screen": NSStringFromRect(controller.window?.screen?.frame ?? .zero),
            "webViewBounds": NSStringFromRect(webView.bounds),
        ]
        #if canImport(FullPanelKit)
        if let fpk = controller.window as? FullPanelWindow {
            state["fullPanelActive"] = fpk.isFullPanelActive
            state["fullPanelState"] = fpk.fullPanelState.rawValue
            state["fallback"] = fpk.fullPanelFallbackReason.summary
            let layout = fpk.fullPanelLayout
            state["layoutHousing"] = layout.cameraHousing.map { NSStringFromRect($0) } ?? "none"
            state["layoutLeft"] = layout.leftArea.map { NSStringFromRect($0) } ?? "none"
            state["layoutRight"] = layout.rightArea.map { NSStringFromRect($0) } ?? "none"
        }
        #endif
        return state
    }

    private func finish() {
        if fullscreen, controller.window?.styleMask.contains(.fullScreen) == true {
            report["fullscreenBeforeExit"] = fullscreenState()
            controller.window?.toggleFullScreen(nil)
            after(2.5) {
                self.report["afterExit"] = self.fullscreenState()
                if #available(macOS 26.0, *) { self.report["afterExitInsetTop"] = self.webView.obscuredContentInsets.top }
                self.finish()
            }
            return
        }
        report["events"] = eventsSince(0)
        let path = "\(directory)/\(name).json"
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        print("notch-test \(name): wrote \(path)")
        exit(0)
    }

    // MARK: Observation

    private func waitForSettle(minimum: TimeInterval, then: @escaping () -> Void) {
        func poll() {
            let elapsed = Date().timeIntervalSince(started)
            if (webView.isLoading || elapsed < minimum) && elapsed < 40 {
                after(0.25, poll)
                return
            }
            // The detector's load phase ends 1.5 s after the load event.
            after(1.8, then)
        }
        after(0.5, poll)
    }

    private func snapshotState(_ key: String, then: @escaping () -> Void) {
        js("JSON.stringify(window.__chromelessNotchGuard ? window.__chromelessNotchGuard.report() : null)") { raw in
            var state: [String: Any] = ["page": self.parse(raw) ?? NSNull()]
            state["engaged"] = self.notchGuard?.engaged ?? false
            state["housing"] = self.notchGuard?.housing.map { NSStringFromRect($0) } ?? "none"
            if #available(macOS 26.0, *) { state["insetTop"] = self.webView.obscuredContentInsets.top }
            state["underPage"] = self.webView.underPageBackgroundColor.usingColorSpace(.sRGB).map {
                [Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255)]
            } ?? []
            state["themeColor"] = self.webView.themeColor?.usingColorSpace(.sRGB).map {
                [Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255)]
            } ?? NSNull()
            state["finalURL"] = self.webView.url?.absoluteString ?? ""
            state["title"] = self.webView.title ?? ""
            self.report[key] = state
            then()
        }
    }

    private func eventsSince(_ index: Int) -> [[String: Any]] {
        guard let events = notchGuard?.events, index < events.count else { return [] }
        let t0 = events.first?.time ?? Date()
        return events[index...].map { e in
            ["t": Int(e.time.timeIntervalSince(t0) * 1000), "kind": e.kind,
             "detail": JSONSerialization.isValidJSONObject(e.detail) ? e.detail : "\(e.detail)"]
        }
    }

    // MARK: Screen capture (real pixels)

    private func capture(_ suffix: String, then: @escaping () -> Void) {
        guard let window = controller.window else { then(); return }
        let path = "\(directory)/\(name)-\(suffix).png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                self.annotate(path)
                then()
            }
        }
        do { try p.run() } catch { then() }
    }

    /// Writes <shot>-view.png: the capture with the housing painted black, i.e.
    /// what the physical camera housing leaves visible.
    private func annotate(_ path: String) {
        guard let housing = notchGuard?.housing,
              let image = NSImage(contentsOfFile: path),
              let rep = image.representations.first,
              let window = controller.window else { return }
        let scale = CGFloat(rep.pixelsWide) / window.frame.width
        let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide,
                                         pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        image.draw(in: NSRect(origin: .zero, size: size))
        let local = webView.convert(housing, to: nil)
        let r = NSRect(x: local.minX * scale, y: local.minY * scale,
                       width: local.width * scale, height: local.height * scale)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: r, xRadius: 10 * scale, yRadius: 10 * scale).fill()
        NSBezierPath(rect: NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let viewPath = path.replacingOccurrences(of: ".png", with: "-view.png")
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: viewPath))
    }

    // MARK: Real input events

    private func pickTarget(_ done: @escaping ([String: Any]?) -> Void) {
        let engaged = notchGuard?.engaged ?? false
        var inset: CGFloat = 0
        if #available(macOS 26.0, *) { inset = webView.obscuredContentInsets.top }
        let js = Self.helpersJS + "JSON.stringify(window.__ngTest.pick(\(engaged)))"
        self.js(js) { raw in
            guard var t = self.parse(raw) as? [String: Any], let css = t["rect"] as? [Double],
                  let scale = t["ptPerCss"] as? Double else { done(nil); return }
            // Viewport CSS px -> web view points; the viewport starts below the inset.
            t["viewRect"] = [css[0] * scale, css[1] * scale + Double(inset), css[2] * scale, css[3] * scale]
            done(t)
        }
    }

    private func windowPoint(_ viewPoint: NSPoint) -> NSPoint {
        webView.convert(viewPoint, to: nil)
    }

    private func click(at viewPoint: NSPoint) {
        guard let window = controller.window else { return }
        let p = windowPoint(viewPoint)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
                                          pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(e)
            }
        }
    }

    private static let keyCodes: [Character: UInt16] = ["n": 45, "o": 31, "t": 17, "c": 8, "h": 4]

    private func type(_ text: String) {
        for ch in text { key(Self.keyCodes[ch] ?? 0, String(ch)) }
    }

    private func key(_ code: UInt16, _ chars: String) {
        guard let window = controller.window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: code) {
                window.sendEvent(e)
            }
        }
    }

    private func scroll(by delta: Int32, times: Int) {
        guard let window = controller.window else { return }
        let center = NSPoint(x: webView.bounds.midX, y: webView.bounds.midY)
        let inWindow = windowPoint(center)
        let onScreen = window.convertPoint(toScreen: inWindow)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for i in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(i)) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                       wheel1: delta, wheel2: 0, wheel3: 0) else { return }
                cg.location = CGPoint(x: onScreen.x, y: primaryHeight - onScreen.y)
                if let e = NSEvent(cgEvent: cg) { window.sendEvent(e) }
            }
        }
    }

    // MARK: Plumbing

    private func js(_ source: String, _ done: @escaping (Any?) -> Void) {
        guard let g = notchGuard else { done(nil); return }
        g.evaluate(Self.helpersJS + source, completion: done)
    }

    private func parse(_ value: Any?) -> Any? {
        guard let s = value as? String, let d = s.data(using: .utf8) else { return value }
        return try? JSONSerialization.jsonObject(with: d)
    }

    private func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    /// Test helpers living in the guard's isolated world.
    private static let helpersJS = #"""
    window.__ngTest = window.__ngTest || (() => {
      const G = window.__chromelessNotchGuard, T = { clicks: [] };
      addEventListener('click', (e) => {
        const path = e.composedPath();
        T.clicks.push(path);
        // Record the hit but stay on the page.
        if (path.some((n) => n.matches && n.matches('a[href]'))) e.preventDefault();
      }, true);
      const deepActive = () => { let a = document.activeElement;
        while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement; return a; };
      const isText = (el) => el && (el.matches('textarea,[contenteditable=""],[contenteditable="true"],[role="searchbox"],[role="textbox"],[role="combobox"]') ||
        (el.tagName === 'INPUT' && /^(text|search|email|url|tel|password|)$/.test(el.type)));
      T.pick = (engaged) => {
        const n = G._housing(); if (!n) return null;
        const ptPerCss = (G.cfg.viewW / innerWidth) * (window.visualViewport ? visualViewport.scale : 1);
        let el = null, why = '';
        if (G.firstHits && G.firstHits.length) {
          for (const h of G.firstHits) {
            const [x, y, w, hh] = h.rect;
            const c = G._control(G._deepHit(x + w / 2, Math.max(1, y + hh / 2)));
            if (c) { el = c; why = 'obscured control'; break; }
          }
        }
        if (!el) {
          // Nothing obscured: click a control in the top band beside the housing.
          let best = null, bestD = 1e9;
          for (const c of document.querySelectorAll(G._interactive)) {
            const r = c.getBoundingClientRect();
            if (!r.width || !r.height || r.top < 0 || r.top > n.h || r.bottom > n.h + 40) continue;
            if (r.right > n.x && r.left < n.x + n.w) continue;
            const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
            if (cy < 4) continue;
            const top = G._deepHit(cx, cy);
            if (!top || !(c === top || c.contains(top) || (top.getRootNode().host && c.contains(top.getRootNode().host)))) continue;
            const d = Math.min(Math.abs(cx - n.x), Math.abs(cx - n.x - n.w));
            if (d < bestD) { best = c; bestD = d; }
          }
          el = best; why = 'top-band control beside housing';
        }
        if (!el) return null;
        T.expected = el; T.clicks = [];
        const r = el.getBoundingClientRect();
        return { why, engaged, ptPerCss, text: !!isText(el), target: G._describe(el, 'target', r),
                 rect: [r.left, r.top, r.width, r.height] };
      };
      T.verifyClick = () => {
        const hit = T.clicks.some((p) => p.includes(T.expected));
        const a = deepActive();
        const last = T.clicks.length ? T.clicks[T.clicks.length - 1][0] : null;
        return { clickEvents: T.clicks.length, reachedTarget: hit,
                 lastTarget: last && last.tagName ? G._describe(last, 'clicked', last.getBoundingClientRect()) : null,
                 focused: a ? a.tagName.toLowerCase() + (a.id ? '#' + a.id : '') : null };
      };
      T.verifyTyping = (s) => { const a = deepActive();
        const v = a ? (a.value !== undefined ? a.value : a.textContent) : '';
        return { focused: a ? a.tagName.toLowerCase() : null, value: String(v).slice(0, 60), ok: String(v).includes(s) }; };
      T.clear = () => { const a = deepActive(); if (a && a.value !== undefined) a.value = ''; if (a && a.blur) a.blur(); return true; };
      return T;
    })();
    """#
}
