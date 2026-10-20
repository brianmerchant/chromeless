# Notch guard — notch-aware page layout for Chromeless + FullPanelKit

Branch `experiment/notch-claude`, built on `1ef9ec6`. FullPanelKit builds now enable FullPanel
fullscreen and the guard by default (iPhone Style Everywhere on a fresh install); see §6.
Machine: MacBook Pro 14" M1 Pro, macOS 27.0.1 (26A434), display 1800×1169 pt, housing
`{{790,0},{220,38}}` (as reported live by FullPanelKit during the tests below).

**Verdict: READY FOR HARDWARE TEST.** The real-fullscreen path already ran automatically
on this machine. Human-eye checks are still needed (see "Manual verification required").

---

## 1. Research: what WebKit/AppKit can and cannot do

Every claim below is marked **TESTED** (I ran it on this machine and the evidence is in
`tests/notch/results` or reproducible with the probe described) or **API/DOCS** (taken
from SDK headers or the runtime and not exercised).

| # | Finding | Status |
|---|---|---|
| R1 | `WKWebView.obscuredContentInsets` (macOS 26+) is an `NSEdgeInsets`: one value per edge. There is no rect/cutout form. | API/DOCS (SDK header) |
| R2 | The WKWebView ObjC runtime has **no** cutout/exclusion-rect SPI. It does have private top-scroll-pocket and color-extension SPI (`_setShouldSuppressTopColorExtensionView:`, `_addReasonToHideTopScrollPocket:`, `_setObscuredContentInsets:immediate:` …). Only `_addReasonToHideTopScrollPocket:` and `_setDrawsBackground:` are used, for the iPhone-style scroll-under band. Both are resolved at runtime with type-encoding checks, and the band falls back to opaque when either is missing; `CHROMELESS_NOTCH_POCKET=show` opts out. The rest is unused. | TESTED (runtime method list) |
| R3 | With `obscuredContentInsets.top = 38` the layout viewport shrinks (`innerHeight` 1000→962), viewport y=0 moves below the inset, and `position:fixed; top:0` lands at the inset edge. Width and horizontal layout are unchanged. | TESTED (probe) |
| R4 | When the inset is set after load, the page sees it about 1 frame (~13 ms) later. When it is set before the document's first layout, the first layout already uses it, so there is no shift. | TESTED (probe; "warm visit" column below) |
| R5 | `env(safe-area-inset-top)` stays `0px` under `obscuredContentInsets`, so CSS safe-area is not a usable channel on macOS. | TESTED (probe) |
| R6 | In the obscured band WebKit color-extends an **opaque fixed/sticky** header (red header → red band). It does **not** extend in-flow headers or a translucent (α .92) fixed header. Those get the top **scroll pocket**: a gray material, (217,217,217) in light appearance and (30,30,30) in Chromeless' dark appearance. That pocket is the "gray strip". Setting `underPageBackgroundColor` to the header color did not change it. | TESTED (on-screen pixels) |
| R7 | Content scrolls under the obscured band and shows through the pocket's blur/fade. | TESTED |
| R8 | No public API hides or tints WebKit's pocket. `NSScrollEdgeEffectStyle` is only for titlebar accessories. The `obscuredContentInsets` doc says the obscured area "should be covered by UI elements managed by the client". | API/DOCS |
| R9 | Shrinking the web view frame by 38 pt gives the same layout as R3. It applies in ~1 ms, and the band shows the window background. | TESTED (probe) |
| R10 | `min/maximumViewportInset` only affect `sv*`/`lv*` units. They do not affect layout. | API/DOCS |

**Is true notch-only avoidance achievable for arbitrary pages without modifying WebKit? No.**
To move only what sits under a 220×38 rect while leaving the rest of the page where it is,
something would have to re-flow the page's own layout around a hole. No WebKit API does that
(R1, R2). No CSS mechanism makes an arbitrary page flow around a viewport rect: safe-area is
edge insets only and needs page cooperation (R5). Even a modified WebKit would only have the
same edge-inset semantics. That is why the previous per-element translation broke YouTube.
What can be done generically is a **per-document yes/no decision**: full-bleed, or the page
laid out in the area below the housing band. A collision-gated inset makes that decision
only for pages that actually need it.

## 2. Strategies evaluated

| Strategy | Result | Why |
|---|---|---|
| A. Unconditional `obscuredContentInsets.top` (existing `CHROMELESS_NOTCH_INSET`) | Rejected as default | Robust, but every page loses full-bleed (GitHub) and gets the gray pocket strip (R6). |
| B. Translate fixed/sticky containers by 38 pt (previous attempt) | Rejected; not re-implemented | Covers the content below, breaks layouts that offset content by header height (YouTube), and fights dynamic headers and existing transforms. |
| C. Inject CSS `env(safe-area-inset-*)` | Rejected | Stays 0 on macOS (R5), and only cooperative pages would react. |
| D. Frame shrink instead of inset | Viable alternative | Same layout (R9) and slightly faster to apply. Not chosen: the inset is WebKit's documented facility for exactly this, keeps the view and scroll geometry stable during FullPanel transitions, and lets WebKit handle fixed/sticky near the edge. |
| E. Modify WebKit for a cutout | Not justified | See the conclusion above. A cutout gives no generic layout semantics, and it would need a full engine build. |
| **F. Collision-gated inset + client band + learned commit-time decision (chosen)** | **Implemented** | Only pages with essential content under the housing get the inset. No DOM is written, nothing is translated. |

## 3. Design (NotchGuard.swift)

1. **Detector** (isolated `WKContentWorld`, so the page can't see or break it, and it is
   read-only on the DOM). It hit-tests the housing rect in *viewport* coordinates: an 11×3
   grid of `elementFromPoint` calls that pierce open shadow roots. The inset only shortens
   the viewport (R3), so the same rect gives the same answer whether or not the inset is
   on, and decisions don't oscillate. It counts as **essential**:
   - interactive controls (links, buttons, fields, ARIA widgets, `cursor:pointer`
     targets) with ≥ 8 % of their area hidden, ignoring controls larger than 25 % of the
     viewport (hero links, cards);
   - glyphs or small icons inside **fixed/sticky** containers, which can never be
     scrolled out.

   It ignores in-flow static text (it can be scrolled into view) and iframes.
2. **Sticky prediction.** During load (≤ 6 passes per document), a column scan finds
   `position:sticky` bars with `top < 38` that are not stuck yet. It computes where their
   controls will land once stuck, so the decision is made at load instead of mid-scroll
   (MDN).
3. **Scheduling.** Evaluation runs in `requestAnimationFrame` every frame while loading,
   against the layout about to be painted. After that it runs only on
   mutation/scroll/viewport change (≥ 100 ms apart), and it stops completely once a
   collision is seen.
4. **Native policy.** On a collision it sets `obscuredContentInsets.top = housing.maxY`.
   The decision is **sticky for the document**. It can only be removed by user layout
   changes (zoom, window resize, geometry change, leaving fullscreen) or by element
   fullscreen (video).
5. **Learned decision per origin** (`UserDefaults` `NotchGuardHints`) is applied at
   `didCommit`, before the document's first layout. On a repeat visit nothing moves (R4).
   This is learned from the detector, not a curated list.
6. **Band view.** A native `NSView` covers the obscured strip, as the API contract asks
   (R8). It is filled with the page's own top-edge CSS background, composited from the
   `elementsFromPoint` paint stack; a translucent header (α ≥ .5) uses its own tint. It
   updates (throttled) as the page scrolls or mutates. It forwards scroll and magnify
   gestures to the page and swallows clicks: nothing is clickable beside the housing
   while the inset is on. No pixels are sampled.

Integration in `main.swift`: geometry from `FullPanelWindow.fullPanelLayout.cameraHousing`
while FullPanel is active; hooks on commit, zoom, resize, fullscreen will/did enter/exit,
`FullPanelWindow.stateDidChangeNotification`, and `fullscreenState` KVO. The legacy
`applyFullPanelWebKitInset` stands down when the guard is on. The guard is on by default, together
with FullPanel fullscreen, unless `CHROMELESS_NOTCH_GUARD=0` or `CHROMELESS_FULLPANEL=0`
turns it off. Without an active FullPanel housing it changes nothing.

## 4. Build and automated tests

- `swift build -c release` (FullPanelKit) and `./build.sh` (no FullPanelKit) both compile.
  All builds were incremental, apart from the unavoidable first build of the fresh worktree.
- Harness: `CHROMELESS_NOTCH_TEST=<dir>` (`NotchGuardTestDriver.swift`), runner
  `tests/notch/run.sh`, matrix `tests/notch/summarize.py`. Each run:
  - opens a **real** window 1800 pt wide, with a simulated 220×38 housing centered at the
    top (`CHROMELESS_NOTCH_SIMULATE=1`) or the real one in fullscreen;
  - loads cold, with no learned decision and a non-persistent data store, so your
    cookies are untouched;
  - records the detector timeline against `first-contentful-paint`;
  - **screen-captures the window** (`screencapture -l`; `*-view.png` additionally paints
    the housing black);
  - sends **real NSEvent** clicks to the obscured control (or, on a clean page, to a
    top-band control beside the housing) and real key events into text fields;
  - sends real scroll-wheel events;
  - optionally zooms and resizes;
  - reloads warm.
- "Shift after FCP" = time from first paint to a viewport-height change caused by the
  guard. That is the visible jump; "none" means the page never painted in the unadjusted
  layout.

### Fixtures (simulated housing, 13 runs; 12 scored PASS, 1 documented limitation)

| fixture | expected | inset | trigger | shift after FCP (cold) | warm | click / keys | scroll | result |
|---|---|---|---|---|---|---|---|---|
| fixed-centered-nav | on | on | links | 16 ms | no shift | ✓ link | ✓ | PASS |
| centered-search (in-flow masthead) | on | on | input | 17 ms | no shift | ✓ input, typed ✓ | ✓ | PASS |
| no-overlap-header (GitHub-like) | off | off | — | none | no shift | ✓ control beside housing | ✓ | PASS |
| sticky-nav (sticks after scroll) | on | on | sticky-predicted | 17 ms | no shift | ✓ | ✓ (no mid-scroll change) | PASS |
| absolute + existing transform | on | on | buttons | 17 ms | no shift | ✓ | ✓ | PASS |
| spa (pushState + DOM insert at 2.5 s) | on after mutation | on @2518 ms | buttons | coincides with the page's own re-render | no shift | ✓ | ✓ | PASS |
| shadow-dom (open) | on | on | input in shadow root | 18 ms | no shift | ✓ typed ✓ | ✓ | PASS |
| shadow-dom (closed) | — | off | — | — | — | — | ✓ | **limitation** (closed roots are opaque) |
| hero-link (1800×640 link + static h1) | off | off | — | none | — | — | ✓ | PASS |
| fixed-title (non-interactive) | on | on | fixed svg/text | 16 ms | no shift | — | ✓ | PASS |
| iframe-ad (centered iframe) | off | off | — | none | — | — | ✓ | PASS (iframes ignored by design) |
| late-header (script inserts search 300 ms after DCL) | on | on @319 ms | input | shift 1 frame after the page's own insert | no shift | ✓ typed ✓ | ✓ | PASS |
| responsive + zoom 150 % + resize 1300 pt | on → off → on → off → on | as expected | links | 17 ms | no shift | ✓ | ✓ | PASS |

Detector cost on fixtures: ≤ 0.5 ms average, ≤ 5 ms max per evaluation.

### Public sites (simulated housing, logged out; captured 2026‑10‑11)

| site | essential content under housing? | adjustment applied | initial jump (cold → warm) | blank/gray strip | scrolling | controls (real events) |
|---|---|---|---|---|---|---|
| apple.com | yes: globalnav links | inset on | 69 ms after FCP → none | no (band = nav tint) | ✓ | ✓ obscured link reached |
| youtube.com | yes: search input | inset on | **none** (decided 712 ms, before FCP 852 ms) → none | no | n/a (logged-out home not scrollable) | ✓ search clicked, typed ✓ |
| github.com | no (header center empty) | none (full-bleed) | none | no | ✓ | ✓ nav link beside housing |
| wikipedia.org | no (wordmark below housing) | none | none | no | n/a (portal not scrollable) | — |
| reddit.com | yes: search box | inset on | 52 ms → none | no | ✓ | ✓ search, typed ✓ |
| google.com | no | none | none | no | n/a (not scrollable) | ✓ link beside housing |
| duckduckgo.com | no (search box starts at ~37 pt) | none | none | no | ✓ | — |
| developer.mozilla.org | not at load; the sticky menu reaches it on scroll | inset on (sticky-predicted at load) | 45 ms → none | no; band is CSS-derived, see K4 | ✓ no mid-scroll change | ✓ menu button |
| news.ycombinator.com | no (links end ~620 pt) | none | none | no | ✓ | ✓ link beside housing |
| developer.apple.com | yes: globalnav links | inset on | 24 ms → none | no | ✓ | ✓ obscured link reached |

Detector cost on sites: averages 0.06–1.5 ms. Worst single evaluation: 16 ms on GitHub,
the first frame of a large DOM where `elementFromPoint` forces the layout WebKit was about
to do anyway.

### Real FullPanel fullscreen (automated, real housing, this machine)

`tests/notch/run.sh fullscreen`: 4/4 runs passed. For each run:
- FullPanel active, no fallback;
- live housing `{{790,0},{220,38}}`, web view 1800×1169;
- fixed-centered-nav and YouTube engaged (`innerHeight` 1131); real clicks reached the
  link; YouTube search took real keystrokes;
- no-overlap fixture and GitHub stayed full-bleed (`innerHeight` 1169); clicks beside the
  housing worked;
- scrolling worked;
- on exit: inset back to 0, housing cleared, window back to 1800×1130.

Note: in these runs the page was already loaded when fullscreen began. The first decision
therefore happened at fullscreen entry, during the transition, and the post-entry reload
reflects the learned ("warm") path.

Evidence: `tests/notch/results/{fixtures,sites,fullscreen}/*.json|*.log` and
`sheet*.png` contact sheets of the real captures. Raw captures are regenerated by the
runner and are git-ignored (≈140 MB).

## 5. Known problems and limitations

- **K1 First visit, cold load: 1–4 frames (16–69 ms) of unadjusted layout** on colliding
  pages whose header is present at first paint. Native→WebProcess inset latency can't be
  hidden with public API. Repeat visits to the origin show no shift. YouTube decided
  before its first paint.
- **K2 The learned decision is per origin.** If an origin mixes pages that collide with
  pages that don't, the previous visit's decision is applied at commit. A wrong "on" stays
  for that document (an unneeded band, but no jump); a wrong "off" costs the K1 shift.
  Reset with `defaults delete com.brianmerchant.chromeless NotchGuardHints`.
- **K3 Late collisions still shift once.** That covers headers that appear on scroll-up
  (headroom-style), sticky bars inside inner scrollers, and content inserted after load.
  The shift coincides with the page's own change. The decision is then kept.
- **K4 Band color is CSS-derived.** A header whose look comes from images, gradients,
  pseudo-elements or a backdrop blur can mismatch. Examples: Apple's nav after scrolling
  (the band keeps the dark nav tint while the nav turns lighter over white content), and
  MDN's ad banner (dark container edge vs. white ad box). No screenshot sampling is used,
  by requirement.
- **K5 Not inspected:** closed shadow roots, cross-origin and same-origin iframes (they
  never trigger the inset), canvas-drawn UI.
- **K6 While engaged, the strip beside the housing is not interactive.** It is band, not
  page.
- **K7 Pinch-zoom** (`visualViewport.scale`) is handled in the math but not tested
  automatically.
- **K8 Element fullscreen** (video) drops the inset and restores it afterwards. Not tested.
- **K9 Tests ran logged out.** Signed-in layouts (YouTube feed, GitHub dashboard) may
  differ.
- **K10 Simulated runs used a 1131 pt tall window** (the screen minus the menu bar), vs
  1169 pt in real fullscreen. Only the height differs, and the real-fullscreen runs cover
  the true size.
- No regressions found. The default app enables the guard (see §6); it has no effect until
  FullPanel fullscreen is active with a housing. The legacy
  `CHROMELESS_NOTCH_INSET` path is unchanged when the guard is off.

## 6. Launch and manual validation

```sh
./build.sh                  # SwiftPM build → ./Chromeless.app (com.brianmerchant.chromeless)
open -n Chromeless.app      # or double-click it in Finder
# Control-Command-F for fullscreen; View ▸ Notch or Option-Command-N cycles modes.
```

No environment variables are needed. Defaults: FullPanel fullscreen on (AppKit's ordinary
fullscreen when FullPanelKit reports a fallback), notch guard on, mode = the last one chosen
in View ▸ Notch, else iPhone Style Everywhere. Optional overrides for a direct launch of
`Contents/MacOS/Chromeless` (`open` does not pass environment variables):
`CHROMELESS_FULLPANEL=0` (plain window; the guard then defaults off too),
`CHROMELESS_NOTCH_GUARD=0|1`, `CHROMELESS_NOTCH_MODE=off|hybrid|everywhere`,
`CHROMELESS_NOTCH_HINTS=0` (no learned decisions). Decisions are logged to stderr as
"CHROMELESS NOTCHGUARD <kind> {json}"; `open -n --stderr FILE` captures them.

### Manual verification required

1. Cold vs warm loads of apple.com, reddit.com, developer.apple.com. Is the 1–4-frame shift
   on the first visit perceptible on the 120 Hz panel?
2. YouTube signed in: search, masthead buttons, play a video, use video fullscreen and
   come back (K8).
3. GitHub signed in (dashboard and a repo page): should stay full-bleed.
4. Band appearance next to the physical housing on dark and light pages (K4).
5. Hover the top edge to reveal the menu bar in FullPanel fullscreen; check the band and
   menu bar coexist.
6. **Mission Control** and Spaces swipes in and out of the FullPanel Space, then
   ⌃⌘F exit and re-enter.
7. Pinch-zoom and ⌘+/⌘− on a guarded page (K7).
8. Keyboard: Tab through Apple's globalnav while the inset is on.

### Re-running the automated suites

```sh
tests/notch/run.sh fixtures          # ~3 min, on-screen windows
tests/notch/run.sh sites             # ~2.5 min, network
tests/notch/run.sh fullscreen        # takes over the built-in display ~20 s per page
python3 tests/notch/summarize.py tests/notch/results/fixtures --expect
```
