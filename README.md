# chromeless

**The browser that isn't there.** The window *is* the webpage — no tabs, no toolbar, no address bar, no chrome at all. Made for clean screenshots, fullscreen YouTube, dashboards, and anything else that deserves the whole window.

A native macOS app built on WKWebView (the Safari engine). No Electron, ~1 MB built.

> **This fork** ([brianmerchant/chromeless](https://github.com/brianmerchant/chromeless)) adds [FullPanelKit](https://github.com/brianmerchant/FullPanelKit) fullscreen, which uses the whole MacBook display beside the camera housing, and iPhone-style page scrolling around the housing. Upstream: [antiwork/chromeless](https://github.com/antiwork/chromeless).

![chromeless start page](docs/chromeless.png)

## Build

```sh
./build.sh                                          # → ./Chromeless.app
./build.sh ~/Downloads/Chromeless-Build/Chromeless.app  # or any output path ending in .app
open Chromeless.app
```

Requires the Xcode Command Line Tools (`xcode-select --install`, Swift 5.9+). `build.sh` runs `swift build -c release` (Swift Package Manager) and packages the executable, icon and Info.plist into the app.

- **Dependency:** `https://github.com/brianmerchant/FullPanelKit.git`, `exact: "0.1.0"` (tag `v0.1.0`, commit `1911fa2146b383b9b8fe76570d530075bb838935`, recorded in `Package.resolved`). The build passes `--force-resolved-versions`, so it never re-resolves silently. No local path dependency, no vendored source.
- **App name and bundle identifier:** `Chromeless.app`, `com.brianmerchant.chromeless`, separate from upstream Chromeless (`com.chromeless.app`). It has its own preferences, cookies (`~/Library/WebKit/<id>`) and install. Override with `BUNDLE_ID=…`. `build.sh` refuses to replace an existing bundle that has a different identifier.

## Fullscreen beside the camera housing (FullPanelKit)

Windows are `FullPanelWindow`s with FullPanel enabled at creation, before any fullscreen entry. `⌃⌘F` (or the green button) enters a real AppKit fullscreen Space: Mission Control, Spaces swipes, menu-bar reveal at the top edge and normal exit all work. On a MacBook with a camera housing, the window covers the whole display. If FullPanel isn't possible (external display, Split View, "Always show menu bar in full screen", changed private macOS interfaces), you get ordinary fullscreen. To get plain AppKit fullscreen, launch the binary with `CHROMELESS_FULLPANEL=0`.

### Notch area modes

**View ▸ Notch** (or `⌥⌘N` to cycle). The choice is remembered. These modes only take effect while FullPanel fullscreen is actually active with a housing:

| Mode | Behavior |
| --- | --- |
| **iPhone Style Everywhere** (default) | Every page starts below the housing band. Scrolled content moves up through the strip beside the housing, like Safari under an iPhone's status bar. |
| **Full-Bleed Unless Needed** (Hybrid) | Pages stay full-bleed beside the housing unless a detector finds essential content under it, such as a link, button or field, or fixed/sticky text. Those pages get the iPhone-style layout. The decision is remembered per site. |
| **Off (Always Full-Bleed)** | No WebKit changes. The housing covers whatever is under it. |

The mechanism is WebKit's `obscuredContentInsets` (macOS 26+), plus a band view in the page's own top-edge colour and a collision detector running in an isolated script world. Design, measurements and known limitations are in [docs/notch-guard.md](docs/notch-guard.md). The crisp scroll-under look relies on two **private** WebKit methods (`_addReasonToHideTopScrollPocket:`, `_setDrawsBackground:`). They are checked at runtime; if they're missing, the band is opaque instead. Launch the binary with `CHROMELESS_NOTCH_POCKET=show` to opt out.

Overrides for a direct launch of `Contents/MacOS/Chromeless` (`open` doesn't pass environment variables): `CHROMELESS_FULLPANEL=0`, `CHROMELESS_NOTCH_GUARD=0|1`, `CHROMELESS_NOTCH_MODE=off|hybrid|everywhere`, `CHROMELESS_NOTCH_HINTS=0`. Reset the learned per-site decisions with `defaults delete com.brianmerchant.chromeless NotchGuardHints`.

### macOS support caveats

- FullPanelKit 0.1.0 is a developer preview built on private AppKit/SkyLight interfaces. Not suitable for the Mac App Store. It has only been hardware-verified on macOS 27.0.1 (MacBook Pro 14-inch, M1 Pro). The notch modes need macOS 26+ (`obscuredContentInsets`). The app builds for macOS 13+.
- On a first visit to a site that needs it, Hybrid can shift the layout for a few frames. Repeat visits don't.
- A window that's already fullscreen when FullPanel is enabled gets FullPanel on its next entry.

## Testing

```sh
./build.sh                                   # the harness uses ./Chromeless.app
tests/notch/run.sh fixtures                  # Hybrid detector on the fixtures (simulated housing, real windows)
tests/notch/run.sh fullscreen                # REAL FullPanel fullscreen on the built-in display
python3 tests/notch/summarize.py tests/notch/results/fixtures --expect
```

Test runs use a non-persistent website data store, so your cookies are untouched. They need Screen Recording permission for the terminal. Results land in `tests/notch/results/` (git-ignored).

## Use

Everything is a keystroke (also listed on the start page and in the menu bar):

| Keys | Action |
| --- | --- |
| `⌘L` | Search or enter a URL (floating HUD) |
| `⌘drag` | Move the window from anywhere |
| `⌃⌘F` | Fullscreen (YouTube's own ⛶ button works too) |
| `⇧⌘S` | Snapshot the page as PNG → Desktop |
| `⌘P` | Pin the window above everything |
| `⌘[` / `⌘]` | Back / forward (two-finger swipe also works) |
| `Esc` | Bail out — back to the start page (`⌘[` returns) |
| `⌘=` `⌘-` `⌘0` | Zoom in / out / reset (pinch works too) |
| `⇧⌘C` | Copy the current URL |
| `⌘R` / `⇧⌘R` | Reload / reload ignoring cache |
| `⌘N` / `⌘W` | New window / close window |

The traffic-light buttons exist but stay invisible — hover the top-left corner to reveal them. The window remembers its frame and reopens your last page.

## CLI screenshot mode

Chromeless doubles as a webpage-to-PNG tool:

```sh
./Chromeless.app/Contents/MacOS/Chromeless https://example.com --snap shot.png --size 1440x900
./Chromeless.app/Contents/MacOS/Chromeless localhost:3000 --snap dev.png --wait 3
```

It loads the page, waits for it to settle, writes a Retina PNG, and exits.

## Notes

- Cookies and logins persist (kept in `~/Library/WebKit/<bundle id>/`), so YouTube stays signed in.

## Passkeys

Apple gates WebAuthn in WKWebView behind the restricted `com.apple.developer.web-browser.public-key-credential` entitlement, and macOS kills ad-hoc builds that claim it without an Apple-issued provisioning profile (verified: instant SIGKILL). Chromeless checks its own signature at runtime:

- **Default build (no entitlement):** the WebAuthn API is hidden, so sites feature-detect the absence and offer their fallbacks instead of a doomed passkey prompt. For Google, "Try another way" → **"Get a prompt on your phone"** signs you in with no password and no passkey — it's Google's own push approval, not WebAuthn.
- **Entitled build:** passkeys work natively via iCloud Keychain + Touch ID. To get there: join the Apple Developer Program, request the *Web Browser Public Key Credential* capability for your App ID (developer.apple.com → Certificates, Identifiers & Profiles → your identifier → Additional Capabilities, or Apple's capability request form), download a provisioning profile containing it, then:

  ```sh
  PROVISIONING_PROFILE=chromeless.provisionprofile \
  CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" BUNDLE_ID=<your App ID> ./build.sh
  ```

  The same binary detects the entitlement and stops hiding WebAuthn. macOS may show a one-time consent (System Settings → Privacy & Security lists passkey access for web browsers).
- Presents a Safari user agent; element fullscreen, autoplay, and AirPlay are enabled.
- First `⇧⌘S` may trigger the standard macOS prompt to allow Desktop access.
- Deliberately absent: tabs, find-in-page, downloads, history UI, extensions. That's the point.

## License and attribution

[MIT](LICENSE). Chromeless © 2026 Antiwork, Inc. ([antiwork/chromeless](https://github.com/antiwork/chromeless)).
The FullPanelKit integration and notch modes in this fork are by Brian Merchant, also under MIT. FullPanelKit is a separate MIT-licensed package ([brianmerchant/FullPanelKit](https://github.com/brianmerchant/FullPanelKit)), fetched by SwiftPM and not included in this repository.
