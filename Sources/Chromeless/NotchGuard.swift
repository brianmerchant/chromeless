// Notch guard — keeps webpage controls out from under the camera housing
// while leaving every other page full-bleed beside it. Opt-in experiment:
// CHROMELESS_NOTCH_GUARD=1 (FullPanel fullscreen) or CHROMELESS_NOTCH_SIMULATE
// (windowed test mode with a fake housing).
//
// WebKit has no rectangular cutout: the only public way to keep content out of
// a region is obscuredContentInsets, which is a full-width edge inset. So the
// guard makes a per-document yes/no decision instead of moving page elements:
//
//   1. A detector runs in an isolated content world (invisible to the page). It
//      hit-tests the housing rectangle *in viewport coordinates*, so its answer
//      does not depend on whether the inset is currently applied (the inset only
//      changes the viewport's height, never its width or horizontal layout).
//   2. Only essential content counts: a control (link, button, field, ARIA
//      widget, pointer target) the housing hides a meaningful share of, or
//      text/icons inside a fixed or sticky container (they can never be
//      scrolled out). Static text, large cards, ads in iframes do not.
//   3. On a collision the native side sets obscuredContentInsets.top to the
//      housing height: the page lays out in the area below it, exactly as in a
//      slightly shorter window, so no page element is moved or restyled.
//      WebKit draws its top scroll pocket (a gray material, the "gray strip")
//      in an obscured inset and offers no public way to restyle it; the API
//      contract is that the client covers that area. The guard covers it with a
//      band view filled with the page's own top-edge CSS background color,
//      which follows the page as it scrolls. No pixels are sampled.
//   4. Decisions are sticky for the document (no flip-flopping), re-evaluated
//      after user layout changes (zoom, resize, geometry), and remembered per
//      origin so the next visit applies the inset at commit — before the first
//      layout — instead of after the first paint.

import Cocoa
import WebKit

struct NotchGuardEvent {
    let time: Date
    let kind: String
    let detail: [String: Any]
}

/// How the guard treats the housing band.
enum NotchMode: String, CaseIterable {
    /// Every page full-bleed; the housing covers whatever is under it.
    case off
    /// Full-bleed unless essential content is under the housing; such pages
    /// start below the band (iPhone style).
    case hybrid
    /// Every page starts below the band (iPhone style).
    case everywhere

    var title: String {
        switch self {
        case .off: return "Off (Always Full-Bleed)"
        case .hybrid: return "Full-Bleed Unless Needed"
        case .everywhere: return "iPhone Style Everywhere"
        }
    }
}

final class NotchGuard: NSObject, WKScriptMessageHandler {
    static let handlerName = "notchGuard"
    static let world = WKContentWorld.world(name: "ChromelessNotchGuard")
    private static let hintsKey = "NotchGuardHints"
    static let modeKey = "NotchGuardMode"

    private weak var webView: WKWebView?
    private let userContentController: WKUserContentController
    private let persistHints: Bool
    private let useHints: Bool
    private var hints: [String: Bool]

    /// Housing rectangle in web view points, top-left origin. nil = inactive.
    private(set) var housing: CGRect?
    /// Whether the inset is applied for the current document.
    private(set) var engaged = false
    private var engagedReason = ""
    private let band = NotchBandView()
    private var suspendedForElementFullscreen = false
    private var currentKey: String?
    /// iPhone style: with WebKit's top scroll pocket hidden, the obscured band
    /// is transparent at rest (the band view behind the page shows the page
    /// color) and content scrolled into it is drawn crisply on top. Without
    /// it, the band view must sit in front and hide scrolled content.
    private(set) var scrollsUnderBand = false
    var mode: NotchMode { didSet { if mode != oldValue { modeChanged() } } }
    /// Every decision is logged here and to NSLog (prefix CHROMELESS NOTCHGUARD).
    private(set) var events: [NotchGuardEvent] = []
    var onEvent: ((NotchGuardEvent) -> Void)?

    init(configuration: WKWebViewConfiguration, persistHints: Bool, useHints: Bool, mode: NotchMode) {
        userContentController = configuration.userContentController
        self.mode = mode
        self.persistHints = persistHints
        self.useHints = useHints
        hints = persistHints
            ? (UserDefaults.standard.dictionary(forKey: NotchGuard.hintsKey) as? [String: Bool] ?? [:])
            : [:]
        super.init()
        userContentController.add(self, contentWorld: NotchGuard.world, name: NotchGuard.handlerName)
        installScript()
    }

    func attach(to webView: WKWebView) {
        self.webView = webView
        band.webView = webView
        if ProcessInfo.processInfo.environment["CHROMELESS_NOTCH_POCKET"] != "show" {
            scrollsUnderBand = NotchGuard.canSetDrawsBackground && NotchGuard.hideTopScrollPocket(webView)
        }
        log("attach", ["mode": mode.rawValue, "scrollsUnderBand": scrollsUnderBand])
    }

    /// PRIVATE WebKit SPI (macOS 26+): -[WKWebView _addReasonToHideTopScrollPocket:]
    /// (uint8 reason). Tested on macOS 27.0.1: reasons 1 and 4 hide the pocket.
    /// Resolved at runtime; returns false (public-API fallback) when missing.
    /// PRIVATE WebKit SPI -[WKWebView _setDrawsBackground:]. With the pocket hidden,
    /// WebKit still paints its base background (white, or (30,30,30) in dark
    /// appearance) above the document; turning it off lets the band view
    /// behind the page show there. Tested on macOS 27.0.1.
    private static let drawsBackgroundSetter = NSSelectorFromString("_setDrawsBackground:")
    private static var canSetDrawsBackground: Bool {
        guard let m = class_getInstanceMethod(WKWebView.self, drawsBackgroundSetter) else { return false }
        return String(cString: method_getTypeEncoding(m)!) == "v20@0:8B16"
    }
    private static func setDrawsBackground(_ webView: WKWebView, _ on: Bool) {
        guard canSetDrawsBackground,
              let m = class_getInstanceMethod(WKWebView.self, drawsBackgroundSetter) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(m), to: Fn.self)(webView, drawsBackgroundSetter, on)
    }

    private static func hideTopScrollPocket(_ webView: WKWebView) -> Bool {
        let sel = NSSelectorFromString("_addReasonToHideTopScrollPocket:")
        guard let m = class_getInstanceMethod(WKWebView.self, sel),
              String(cString: method_getTypeEncoding(m)!) == "v20@0:8C16" else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt8) -> Void
        unsafeBitCast(method_getImplementation(m), to: Fn.self)(webView, sel, 1)
        return true
    }

    /// Housing present and the mode wants the guard.
    private var isActive: Bool { housing != nil && mode != .off }

    private func modeChanged() {
        log("mode", ["mode": mode.rawValue])
        installScript()
        switch mode {
        case .off: setEngaged(false, reason: "mode-off")
        case .everywhere: setEngaged(isActive, reason: "mode-everywhere")
        case .hybrid: break   // the reset verdict below re-decides
        }
        pushConfig(reset: mode == .hybrid, why: "mode")
    }

    func invalidate() {
        userContentController.removeScriptMessageHandler(
            forName: NotchGuard.handlerName, contentWorld: NotchGuard.world)
    }

    // MARK: Inputs from the window controller

    /// Sets (or clears) the housing rectangle in web view coordinates.
    /// Clearing removes the inset immediately.
    func setHousing(_ rect: CGRect?) {
        let normalized = rect.flatMap { $0.isEmpty ? nil : $0.integral }
        guard normalized != housing else { return }
        housing = normalized
        log("geometry", ["housing": normalized.map { NSStringFromRect($0) } ?? "none"])
        installScript()
        if !isActive {
            setEngaged(false, reason: "inactive")
        } else if mode == .everywhere {
            setEngaged(true, reason: "mode-everywhere")
        } else if let key = currentKey, useHints, hints[key] == true {
            setEngaged(true, reason: "hint")
        }
        pushConfig(reset: mode == .hybrid)
    }

    /// A new main-frame document committed. Applies the remembered decision for
    /// its origin now, which reaches WebKit before the document's first layout.
    func documentCommitted(url: URL?) {
        currentKey = NotchGuard.key(for: url)
        let hinted = isActive && useHints && currentKey.map { hints[$0] == true } == true
        if mode == .everywhere {
            setEngaged(isActive, reason: "mode-everywhere", force: true)
        } else {
            setEngaged(hinted, reason: hinted ? "hint" : "new-document", force: true)
        }
        log("commit", ["url": url?.absoluteString ?? "", "hint": hinted])
        pushConfig(reset: false)
    }

    /// The user changed layout (zoom, window size): allow a fresh decision,
    /// including removing the inset.
    func layoutChanged(_ why: String) {
        guard isActive, mode == .hybrid else { return }
        installScript()
        pushConfig(reset: true, why: why)
    }

    /// Element fullscreen (e.g. a video) takes the web view out of the window;
    /// the band would be meaningless there.
    func elementFullscreenChanged(active: Bool) {
        suspendedForElementFullscreen = active
        applyInset()
    }

    // MARK: Native state

    private func setEngaged(_ on: Bool, reason: String, force: Bool = false) {
        guard force || on != engaged else { return }
        let changed = on != engaged
        engaged = on
        engagedReason = reason
        applyInset()
        if changed || force {
            log(on ? "engage" : "disengage", ["reason": reason])
        }
        if changed || force {
            let js = "window.__chromelessNotchGuard && window.__chromelessNotchGuard.applied(\(on), \(changed))"
            webView?.evaluateJavaScript(js, in: nil, in: NotchGuard.world, completionHandler: nil)
        }
    }

    private var insetTop: CGFloat {
        guard engaged, !suspendedForElementFullscreen, let h = housing else { return 0 }
        return h.maxY
    }

    private func applyInset() {
        guard let webView else { return }
        if #available(macOS 26.0, *) {
            let top = insetTop
            if webView.obscuredContentInsets.top != top {
                webView.obscuredContentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
            }
        }
        layoutBand()
    }

    /// Keeps the band view over the obscured strip (call after layout changes).
    func layoutBand() {
        guard let webView, let container = webView.superview else { return }
        let top = insetTop
        // Behind the page when content may scroll over the band, else in front.
        let behind = scrollsUnderBand
        if behind { NotchGuard.setDrawsBackground(webView, top == 0) }
        let ordered = container.subviews.firstIndex(of: band).map { i in
            container.subviews.firstIndex(of: webView).map { behind ? i < $0 : i > $0 } ?? false
        } ?? false
        if band.superview !== container || !ordered {
            band.removeFromSuperview()
            container.addSubview(band, positioned: behind ? .below : .above, relativeTo: webView)
        }
        band.isHidden = top == 0
        let f = webView.frame
        if behind {
            // Whole page area: canvas color for pages without a background of
            // their own, page-top color in the strip above the document.
            band.frame = f
            band.stripHeight = top
        } else {
            band.frame = container.isFlipped
                ? NSRect(x: f.minX, y: f.minY, width: f.width, height: top)
                : NSRect(x: f.minX, y: f.maxY - top, width: f.width, height: top)
            band.stripHeight = top
        }
    }

    private func remember(_ collide: Bool) {
        guard let key = currentKey else { return }
        guard hints[key] != collide else { return }
        hints[key] = collide
        if persistHints {
            if hints.count > 400 { hints = [key: collide] }
            UserDefaults.standard.set(hints, forKey: NotchGuard.hintsKey)
        }
    }

    static func key(for url: URL?) -> String? {
        guard let url else { return nil }
        if url.isFileURL { return "file:" + url.lastPathComponent }
        guard let host = url.host, !host.isEmpty else { return nil }
        return (url.scheme ?? "https") + "://" + host + (url.port.map { ":\($0)" } ?? "")
    }

    // MARK: Page bridge

    private func configJSON(reset: Bool, why: String = "") -> String {
        var cfg: [String: Any] = ["active": false, "reset": reset, "why": why]
        if isActive, let h = housing, let webView, webView.bounds.width > 0 {
            cfg = ["active": true, "reset": reset, "why": why, "engaged": engaged,
                   "detect": mode == .hybrid, "scrollUnder": scrollsUnderBand,
                   "x": h.minX, "y": h.minY, "w": h.width, "h": h.height,
                   "viewW": webView.bounds.width]
        }
        let data = (try? JSONSerialization.data(withJSONObject: cfg)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The detector for future documents carries the current geometry, so it
    /// can decide during the very first frames without waiting for native.
    private func installScript() {
        // removeAllUserScripts would also drop the app's other scripts, so the
        // guard's script is keyed and replaced selectively.
        let marker = "/*chromeless-notch-guard*/"
        let others = userContentController.userScripts.filter { !$0.source.hasPrefix(marker) }
        userContentController.removeAllUserScripts()
        others.forEach { userContentController.addUserScript($0) }
        let source = marker + NotchGuard.detectorJS.replacingOccurrences(
            of: "__CONFIG__", with: configJSON(reset: false))
        userContentController.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true,
            in: NotchGuard.world))
    }

    private func pushConfig(reset: Bool, why: String = "") {
        let js = "window.__chromelessNotchGuard && window.__chromelessNotchGuard.configure(\(configJSON(reset: reset, why: why)))"
        webView?.evaluateJavaScript(js, in: nil, in: NotchGuard.world, completionHandler: nil)
    }

    /// Runs a snippet in the guard's world (used by the test driver).
    func evaluate(_ js: String, completion: @escaping (Any?) -> Void) {
        webView?.evaluateJavaScript(js, in: nil, in: NotchGuard.world) { result in
            switch result {
            case .success(let value): completion(value)
            case .failure(let error): completion(["error": error.localizedDescription])
            }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        func color(_ key: String) -> NSColor? {
            guard let c = body[key] as? [Double], c.count >= 3 else { return nil }
            return NSColor(srgbRed: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: 1)
        }
        if let c = color("band") { band.setStripColor(c, animated: type == "band" && !scrollsUnderBand) }
        if let c = color("canvas") { band.setBaseColor(c) }
        switch type {
        case "verdict":
            let collide = body["collide"] as? Bool ?? false
            log("verdict", body)
            guard isActive, mode == .hybrid else { return }
            if collide {
                remember(true)
                setEngaged(true, reason: "detected")
            } else if body["reset"] as? Bool == true {
                // Only explicit re-evaluations (zoom, resize, geometry) may
                // remove an inset; otherwise the document keeps its layout.
                setEngaged(false, reason: "re-evaluated")
            }
        case "settled":
            log("settled", body)
            if isActive, mode == .hybrid { remember(body["seen"] as? Bool ?? false) }
        case "band":
            break
        default:
            log(type, body)
        }
    }

    private func log(_ kind: String, _ detail: [String: Any]) {
        let event = NotchGuardEvent(time: Date(), kind: kind, detail: detail)
        events.append(event)
        if events.count > 400 { events.removeFirst(events.count - 400) }
        let json = (try? JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\(detail)"
        NSLog("CHROMELESS NOTCHGUARD %@ %@", kind, json)
        onEvent?(event)
    }

    // MARK: Detector

    // Runs in the guard's isolated world: the page cannot see or break it, and
    // it never writes to the DOM. Work per evaluation: ~33 hit tests, a few
    // getComputedStyle calls on hit elements only. It evaluates every frame
    // while the document loads (in requestAnimationFrame, i.e. against the
    // layout about to be painted), then only on mutations/scroll/viewport
    // changes, and stops entirely once a collision has been seen.
    static let detectorJS = #"""
    (() => {
      'use strict';
      const CONFIG = __CONFIG__;
      if (window.__chromelessNotchGuard) { window.__chromelessNotchGuard.configure(CONFIG); return; }

      const INTERACTIVE = [
        'a[href]', 'button', 'input:not([type="hidden"])', 'select', 'textarea', 'summary',
        'label', '[contenteditable=""]', '[contenteditable="true"]', '[tabindex]:not([tabindex="-1"])',
        '[role="button"]', '[role="link"]', '[role="menuitem"]', '[role="menuitemcheckbox"]',
        '[role="menuitemradio"]', '[role="tab"]', '[role="searchbox"]', '[role="combobox"]',
        '[role="textbox"]', '[role="checkbox"]', '[role="switch"]', '[role="option"]'
      ].join(',');
      const MEDIA = new Set(['IMG', 'svg', 'SVG', 'CANVAS', 'VIDEO', 'PICTURE']);
      const LOAD_SETTLE_MS = 1500, LOAD_MAX_MS = 20000, MIN_GAP_MS = 100;

      const G = {
        cfg: null, seen: false, firstHits: null, evals: 0, evalMs: 0, maxEvalMs: 0,
        loadPhase: true, settled: false, rafPending: false, lastEval: -1e9, timer: 0,
        observers: [], fcp: null, decidedAt: null, appliedAt: null, visibleAt: null,
        heights: [], lastHeight: 0, firstLayoutAt: null, firstLayoutHeight: null, lastPredict: -1e9, predictions: 0
      };
      window.__chromelessNotchGuard = G;

      const post = (m) => { try { webkit.messageHandlers.notchGuard.postMessage(m); } catch (e) {} };
      const now = () => performance.now();

      // Housing in layout-viewport CSS px. Native passes points relative to the
      // web view's top-left with the inset NOT applied; the inset only shortens
      // the viewport, so the same rectangle is valid whether or not it is on.
      function housing() {
        const c = G.cfg;
        if (!c || !c.active || !c.viewW || !innerWidth) return null;
        const vv = window.visualViewport;
        const s = (innerWidth / c.viewW) / (vv ? vv.scale || 1 : 1);
        const ox = vv ? vv.offsetLeft : 0, oy = vv ? vv.offsetTop : 0;
        return { x: ox + c.x * s, y: oy + c.y * s, w: c.w * s, h: c.h * s };
      }

      function deepHit(x, y) {
        let el = document.elementFromPoint(x, y);
        for (let i = 0; el && el.shadowRoot && i < 12; i++) {
          const inner = el.shadowRoot.elementFromPoint(x, y);
          if (!inner || inner === el) break;
          el = inner;
        }
        return el;
      }

      const parentOf = (el) => el.assignedSlot || el.parentElement ||
        (el.parentNode && el.parentNode.host) || null;

      function interactiveAncestor(el) {
        for (let e = el, i = 0; e && i < 30; e = parentOf(e), i++) {
          if (e === document.body || e === document.documentElement) break;
          if (e.matches && e.matches(INTERACTIVE)) return e;
        }
        // cursor:pointer is inherited: climb to the outermost element that
        // still has it, which is the clickable thing the page styled.
        let p = null;
        for (let e = el, i = 0; e && i < 8; e = parentOf(e), i++) {
          if (e === document.body || e === document.documentElement) break;
          if (getComputedStyle(e).cursor !== 'pointer') break;
          p = e;
        }
        return p;
      }

      function persistentAncestor(el, cache) {
        for (let e = el, i = 0; e && i < 40; e = parentOf(e), i++) {
          if (cache.has(e)) return cache.get(e);
          const pos = getComputedStyle(e).position;
          if (pos === 'fixed' || pos === 'sticky') { cache.set(el, pos); return pos; }
        }
        cache.set(el, null);
        return null;
      }

      function glyphAt(x, y) {
        const r = document.caretRangeFromPoint && document.caretRangeFromPoint(x, y);
        if (!r || !r.startContainer || r.startContainer.nodeType !== 3) return false;
        const node = r.startContainer, text = node.data, o = r.startOffset;
        for (const [a, b] of [[o, o + 1], [o - 1, o]]) {
          if (a < 0 || b > text.length || !/\S/.test(text.slice(a, b))) continue;
          const rr = document.createRange();
          rr.setStart(node, a); rr.setEnd(node, b);
          for (const q of rr.getClientRects()) {
            if (x >= q.left - 1 && x <= q.right + 1 && y >= q.top - 1 && y <= q.bottom + 1) return true;
          }
        }
        return false;
      }

      const overlap = (r, n) => Math.max(0, Math.min(r.right, n.x + n.w) - Math.max(r.left, n.x)) *
                                Math.max(0, Math.min(r.bottom, n.y + n.h) - Math.max(r.top, n.y));

      function describe(el, kind, r, extra) {
        const cls = typeof el.className === 'string' ? el.className.trim().split(/\s+/)[0] || '' : '';
        return Object.assign({
          kind, tag: el.tagName.toLowerCase(), id: (el.id || '').slice(0, 32), cls: cls.slice(0, 32),
          role: el.getAttribute('role') || '', position: getComputedStyle(el).position,
          rect: [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)]
        }, extra || {});
      }

      function evaluate() {
        const n = housing();
        if (!n || !document.body) return null;
        const t = now();
        const vpArea = innerWidth * innerHeight;
        const done = new Set(), cache = new Map(), hits = [];
        let soft = 0;
        const cols = 11, rows = [0.25, 0.5, 0.8];
        outer:
        for (const fy of rows) {
          for (let i = 0; i < cols; i++) {
            const x = n.x + (i + 0.5) * n.w / cols, y = n.y + fy * n.h;
            if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) continue;
            const el = deepHit(x, y);
            if (!el || el === document.body || el === document.documentElement || done.has(el)) continue;
            done.add(el);
            if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') { soft++; continue; }
            const c = interactiveAncestor(el);
            if (c) {
              if (c !== el && done.has(c)) continue;
              done.add(c);
              const r = c.getBoundingClientRect();
              const area = r.width * r.height, hidden = overlap(r, n);
              // A control mostly visible elsewhere (big cards, hero links) stays usable.
              if (!area || area > 0.25 * vpArea || hidden / area < 0.08) { soft++; continue; }
              hits.push(describe(c, 'control', r, { hidden: Math.round(100 * hidden / area) }));
            } else {
              const pos = persistentAncestor(el, cache);
              if (!pos) { soft++; continue; }   // in-flow content can be scrolled into view
              const r = el.getBoundingClientRect();
              if (MEDIA.has(el.tagName) || el instanceof SVGElement) {
                if (r.width * r.height <= 6 * n.w * n.h) hits.push(describe(el, pos + '-media', r));
                else soft++;
              } else if (glyphAt(x, y)) {
                hits.push(describe(el, pos + '-text', r));
              } else soft++;
            }
            if (hits.length >= 6) break outer;
          }
        }
        // A sticky bar lower on the page will reach the housing as soon as the
        // user scrolls. Predicting that now, during load, avoids a mid-scroll
        // shift. Costlier (a column of hit tests), so rate-limited.
        if (!hits.length && (G.loadPhase || predictAlways) && t - G.lastPredict > 300 && G.predictions < 6) {
          G.lastPredict = t; G.predictions++;
          predictSticky(n, vpArea, hits);
        }
        const ms = now() - t;
        G.evals++; G.evalMs += ms; G.maxEvalMs = Math.max(G.maxEvalMs, ms);
        return { collide: hits.length > 0, hits, soft, ms };
      }
      let predictAlways = false;

      function predictSticky(n, vpArea, hits) {
        const visited = new Set();
        const xs = [n.x + n.w * 0.15, n.x + n.w / 2, n.x + n.w * 0.85];
        const maxY = Math.min(innerHeight, 1000);
        for (let y = n.y + n.h + 4; y < maxY && !hits.length; y += 32) {
          for (const x of xs) {
            for (let e = deepHit(x, y), i = 0; e && i < 40; e = parentOf(e), i++) {
              if (e === document.body || e === document.documentElement || visited.has(e)) break;
              visited.add(e);
              const cs = getComputedStyle(e);
              if (cs.position !== 'sticky') continue;
              const top = parseFloat(cs.top);   // 'auto' -> NaN: not top-sticky
              if (top < n.y + n.h) stickyHits(e, top, n, vpArea, hits);
              break;
            }
          }
        }
      }

      function stickyHits(s, top, n, vpArea, hits) {
        const sr = s.getBoundingClientRect();
        if (sr.top <= top + 1) return;                       // already stuck: normal path
        const parent = s.parentElement;
        if (!parent || parent.getBoundingClientRect().bottom - sr.bottom < n.h) return;  // can't stick
        for (let a = parent; a && a !== document.body && a !== document.documentElement; a = a.parentElement) {
          const o = getComputedStyle(a).overflowY;
          if (o !== 'visible' && o !== 'clip') return;     // sticks inside another scroller
        }
        const dy = top - sr.top;
        let k = 0;
        for (const c of s.querySelectorAll(INTERACTIVE)) {
          if (++k > 300 || hits.length >= 3) break;
          const r = c.getBoundingClientRect();
          const area = r.width * r.height;
          if (!area || area > 0.25 * vpArea) continue;
          const moved = { left: r.left, right: r.right, top: r.top + dy, bottom: r.bottom + dy };
          const hidden = overlap(moved, n);
          if (hidden / area < 0.08 || getComputedStyle(c).visibility === 'hidden') continue;
          hits.push(describe(c, 'sticky-predicted', r, { hidden: Math.round(100 * hidden / area), stickTop: top }));
        }
      }

      // CSS background at the top edge (for the band above in-flow headers).
      function parseColor(s) {
        const m = /rgba?\(([^)]+)\)/.exec(s || '');
        if (!m) return null;
        const p = m[1].split(/[\s,\/]+/).filter(Boolean).map(Number);
        return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1];
      }
      // Composite the paint stack at the top edge (siblings behind a
      // translucent header count, not just its ancestors).
      // Top color of a vertical linear-gradient background image, if any.
      function gradientTop(img) {
        const m = /^linear-gradient\((.*)\)$/.exec(img || '');
        if (!m) return null;
        const args = [];
        let depth = 0, cur = '';
        for (const ch of m[1]) {
          if (ch === '(') depth++; else if (ch === ')') depth--;
          if (ch === ',' && depth === 0) { args.push(cur.trim()); cur = ''; } else cur += ch;
        }
        args.push(cur.trim());
        let first = args[0];
        if (!/^rgba?\(/.test(first)) {
          if (first !== 'to bottom' && first !== '180deg') return null;
          first = args[1];
        }
        return parseColor(first);
      }
      function canvasColor() {
        for (const el of [document.documentElement, document.body]) {
          const c = el && parseColor(getComputedStyle(el).backgroundColor);
          if (c && c[3] >= 0.99) return c.slice(0, 3);
        }
        const meta = document.querySelector('meta[name="color-scheme"]');
        const scheme = getComputedStyle(document.documentElement).colorScheme + ' ' + (meta ? meta.content : '');
        // WebKit's base background: white, or dark text background for dark-scheme pages.
        return /dark/.test(scheme) && matchMedia('(prefers-color-scheme: dark)').matches ? [30, 30, 30] : [255, 255, 255];
      }
      function topColor(x) {
        const layers = [];
        // A few px down: thin top borders/edges should not decide the band.
        for (const el of document.elementsFromPoint(x, Math.min(6, innerHeight - 1)).slice(0, 40)) {
          const cs = getComputedStyle(el);
          const g = gradientTop(cs.backgroundImage);   // images paint above the color
          if (g && g[3] > 0) { layers.push(g); if (g[3] >= 0.99) break; }
          const c = parseColor(cs.backgroundColor);
          if (c && c[3] > 0) { layers.push(c); if (c[3] >= 0.99) break; }
        }
        // A mostly-opaque translucent header (e.g. rgba(..., .8) + backdrop
        // blur) shows its own tint over whatever images/video lie behind it,
        // which CSS colors cannot describe; its own RGB is the best estimate.
        if (layers.length && layers[0][3] >= 0.5) return layers[0].slice(0, 3).map(Math.round);
        const dark = /dark/.test(getComputedStyle(document.documentElement).colorScheme) &&
                     matchMedia('(prefers-color-scheme: dark)').matches;
        let out = canvasColor();
        for (let i = layers.length - 1; i >= 0; i--) {
          const [r, g, b, a] = layers[i];
          out = [r * a + out[0] * (1 - a), g * a + out[1] * (1 - a), b * a + out[2] * (1 - a)];
        }
        return out.map(Math.round);
      }
      function bandColor() {
        const n = housing();
        if (!n) return null;
        const xs = [Math.max(1, n.x - 40), n.x + n.w / 2, Math.min(innerWidth - 1, n.x + n.w + 40)];
        const cs = xs.map(topColor).map(String);
        const pick = cs.find((c, i) => cs.indexOf(c) !== i) || cs[0];
        return pick.split(',').map(Number);
      }

      function verdict(reset, why) {
        const r = evaluate();
        if (!r) return;
        if (r.collide && !G.seen) {
          G.seen = true; G.firstHits = r.hits; G.decidedAt = now();
          stopWatching();
        }
        if (r.collide) bandLast = '';
        if (r.collide || reset) {
          post({ type: 'verdict', collide: r.collide, reset: !!reset, why: why || '',
                 hits: r.hits, soft: r.soft, t: Math.round(now()), band: r.collide ? bandColor() : null,
                 canvas: r.collide ? canvasColor() : null,
                 url: location.href });
        }
      }

      const detecting = () => !!(G.cfg && G.cfg.active && G.cfg.detect !== false);

      function frame() {
        G.rafPending = false;
        if (!detecting()) { trackHeight(); return; }
        G.lastEval = now();
        trackHeight();
        if (!G.seen) verdict(false, 'frame');
        if (G.loadPhase && !G.seen) { G.rafPending = true; requestAnimationFrame(frame); }
      }

      function schedule() {
        if (G.seen || G.rafPending || G.timer || !detecting()) return;
        const wait = G.lastEval + MIN_GAP_MS - now();
        if (wait > 0) { G.timer = setTimeout(() => { G.timer = 0; schedule(); }, wait); return; }
        G.rafPending = true;
        requestAnimationFrame(frame);
      }

      function startWatching() {
        if (G.observers.length || G.seen) return;
        const mo = new MutationObserver(schedule);
        mo.observe(document, { childList: true, subtree: true, attributes: true,
                               attributeFilter: ['class', 'style', 'hidden', 'open'] });
        const opts = { passive: true, capture: true };
        addEventListener('scroll', schedule, opts);
        addEventListener('resize', schedule, opts);
        if (window.visualViewport) visualViewport.addEventListener('resize', schedule, opts);
        G.observers.push(() => {
          mo.disconnect();
          removeEventListener('scroll', schedule, opts);
          removeEventListener('resize', schedule, opts);
          if (window.visualViewport) visualViewport.removeEventListener('resize', schedule, opts);
        });
      }
      function stopWatching() { G.observers.splice(0).forEach((f) => f()); }

      // Instrumentation for the test driver: viewport height history shows
      // whether (and when) the page visibly shifted relative to first paint.
      function trackHeight() {
        if (!document.body) return;
        const h = innerHeight;
        if (G.firstLayoutAt === null) { G.firstLayoutAt = Math.round(now()); G.firstLayoutHeight = h; G.lastHeight = h; }
        if (h !== G.lastHeight) {
          G.heights.push([Math.round(now()), h]);
          G.lastHeight = h;
          if (G.appliedAt !== null && G.visibleAt === null) G.visibleAt = Math.round(now());
        }
      }
      try {
        new PerformanceObserver((l) => {
          for (const e of l.getEntries()) if (e.name === 'first-contentful-paint') G.fcp = Math.round(e.startTime);
        }).observe({ type: 'paint', buffered: true });
      } catch (e) {}

      function endLoadPhase() {
        if (!G.loadPhase) return;
        G.loadPhase = false;
        if (detecting() && !G.seen) { G.lastPredict = -1e9; G.predictions = 0; predictAlways = true; verdict(false, 'settle'); predictAlways = false; }
        bandSoon();
        if (!G.settled) { G.settled = true; post({ type: 'settled', seen: G.seen, evals: G.evals,
          avgMs: G.evals ? +(G.evalMs / G.evals).toFixed(3) : 0, maxMs: +G.maxEvalMs.toFixed(3) }); }
      }

      G.configure = (c) => {
        G.cfg = Object.assign({}, c);
        if (!c.active) { stopWatching(); return; }
        if (c.engaged) bandSoon();
        if (!detecting()) { stopWatching(); return; }
        if (c.reset) {
          G.seen = false; G.firstHits = null; G.lastPredict = -1e9; G.predictions = 0;
          verdict(true, c.why || 'reset');
        }
        startWatching();
        schedule();
      };
      G.applied = (on, changed) => {
        G.cfg = Object.assign({}, G.cfg, { engaged: on });
        if (on) bandSoon();
        if (!changed) return;
        G.appliedAt = Math.round(now()); G.visibleAt = null; G.appliedOn = on;
        requestAnimationFrame(function watch() { trackHeight(); if (G.visibleAt === null && now() - G.appliedAt < 1000) requestAnimationFrame(watch); });
      };

      // While the inset is on, the band above the page shows the page's top-edge
      // background; keep it current as the page scrolls or re-renders
      // (throttled; 3 hit-test stacks per update).
      let bandPending = false, bandLast = '', bandAt = -1e9, bandObserver = null;
      function bandSoon() {
        if (bandPending || !G.cfg || !G.cfg.active || !G.cfg.engaged) return;
        if (!bandObserver) {
          bandObserver = new MutationObserver(bandSoon);
          bandObserver.observe(document, { childList: true, subtree: true, attributes: true,
                                           attributeFilter: ['class', 'style', 'src'] });
        }
        bandPending = true;
        const wait = Math.max(0, bandAt + 2 * MIN_GAP_MS - now());
        setTimeout(() => requestAnimationFrame(() => {
          bandPending = false; bandAt = now();
          if (!document.body) return;
          if (!G.cfg.engaged) { if (bandObserver) { bandObserver.disconnect(); bandObserver = null; } return; }
          // Scroll-under mode: the band is only visible at the page's top.
          if (G.cfg.scrollUnder && scrollY > 2) return;
          const c = bandColor(), k = canvasColor();
          if (c && String([c, k]) !== bandLast) { bandLast = String([c, k]); post({ type: 'band', band: c, canvas: k }); }
        }), wait);
      }
      addEventListener('scroll', bandSoon, { passive: true, capture: true });
      G.report = () => ({
        url: location.href, active: !!(G.cfg && G.cfg.active), seen: G.seen, firstHits: G.firstHits,
        decidedAt: G.decidedAt === null ? null : Math.round(G.decidedAt), fcp: G.fcp,
        firstLayoutAt: G.firstLayoutAt, firstLayoutHeight: G.firstLayoutHeight, heights: G.heights,
        appliedAt: G.appliedAt, visibleAt: G.visibleAt, innerHeight, innerWidth, scrollY,
        evals: G.evals, avgEvalMs: G.evals ? +(G.evalMs / G.evals).toFixed(3) : 0, maxEvalMs: +G.maxEvalMs.toFixed(3),
        loadPhase: G.loadPhase, watching: G.observers.length > 0, now: Math.round(now()), current: evaluate()
      });

      // Read-only helpers for the test driver.
      Object.assign(G, { _housing: housing, _deepHit: deepHit, _control: interactiveAncestor,
                         _describe: describe, _interactive: INTERACTIVE });

      G.cfg = CONFIG;
      addEventListener('load', bandSoon, { once: true });
      const onLoad = () => setTimeout(endLoadPhase, LOAD_SETTLE_MS);
      if (document.readyState === 'complete') onLoad(); else addEventListener('load', onLoad, { once: true });
      setTimeout(endLoadPhase, LOAD_MAX_MS);
      if (detecting()) { startWatching(); G.rafPending = true; requestAnimationFrame(frame); }
    })();
    """#
}

/// Covers the obscured strip above the page while the guard's inset is on.
/// Solid fill with the page's top-edge CSS color; scrolls go to the page.
final class NotchBandView: NSView {
    weak var webView: WKWebView?
    private let strip = CALayer()
    /// Height of the page-top strip at the top of this view.
    var stripHeight: CGFloat = 0 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        strip.backgroundColor = NSColor.black.cgColor
        strip.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(strip)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: stripHeight)
        CATransaction.commit()
    }

    func setStripColor(_ color: NSColor, animated: Bool) {
        guard strip.backgroundColor != color.cgColor else { return }
        if animated {
            let a = CABasicAnimation(keyPath: "backgroundColor")
            a.fromValue = strip.backgroundColor
            a.duration = 0.18
            strip.add(a, forKey: "color")
        }
        strip.backgroundColor = color.cgColor
    }

    func setBaseColor(_ color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = color.cgColor
        CATransaction.commit()
    }

    override func scrollWheel(with event: NSEvent) { webView?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { webView?.magnify(with: event) }
    override func smartMagnify(with event: NSEvent) { webView?.smartMagnify(with: event) }
    override func mouseDown(with event: NSEvent) {}   // nothing to hit beside the housing
}
