#!/bin/zsh
# Runs the notch-guard test driver against local fixtures or public sites.
#   tests/notch/run.sh fixtures [outdir]
#   tests/notch/run.sh sites [outdir]
#   tests/notch/run.sh one <name> <url> [outdir]
#   tests/notch/run.sh fullscreen [outdir]   REAL FullPanel fullscreen: takes over
#                                            the built-in display ~20 s per page
# Each run opens a real 1800-pt-wide window (simulated 220x38 housing centered
# at its top), drives real scroll/click/key events and screen-captures it.
# Needs: Chromeless-FullPanelKit.app built (./build.sh) and the
# terminal's existing Screen Recording permission (screencapture -l).
set -u
ROOT="${0:a:h:h:h}"
APP="$ROOT/Chromeless-FullPanelKit.app/Contents/MacOS/Chromeless"
FIX="$ROOT/tests/notch/fixtures"
SUITE="${1:-fixtures}"
[[ -x "$APP" ]] || { echo "build first: ./build.sh"; exit 1; }

run() {   # name url outdir [ENV=VAL...]
  local name=$1 url=$2 out=$3; shift 3
  mkdir -p "$out"
  echo "▸ $name"
  env ${=MODE_ENV:-CHROMELESS_NOTCH_SIMULATE=1 CHROMELESS_FULLPANEL=0 CHROMELESS_NOTCH_MODE=hybrid} CHROMELESS_NOTCH_TEST="$out" CHROMELESS_NOTCH_TEST_NAME="$name" "$@" \
    "$APP" "$url" --size 1800x1131 > "$out/$name.log" 2>&1 &
  local pid=$! waited=0
  while kill -0 $pid 2>/dev/null; do
    sleep 1; (( waited++ ))
    if (( waited > 150 )); then kill -9 $pid; echo "  ✗ killed after 150 s"; break; fi
  done
  grep -q "notch-test $name: wrote" "$out/$name.log" && echo "  ✓ ${waited}s" || echo "  ✗ no report (see $out/$name.log)"
}

case "$SUITE" in
  fixtures)
    OUT="${2:-$ROOT/tests/notch/results/fixtures}"
    for f in fixed-centered-nav centered-search no-overlap-header sticky-nav absolute spa \
             shadow-dom hero-link fixed-title iframe-ad late-header; do
      run $f "file://$FIX/$f.html" "$OUT"
    done
    run shadow-dom-closed "file://$FIX/shadow-dom.html?mode=closed" "$OUT"
    run responsive "file://$FIX/responsive.html" "$OUT" CHROMELESS_NOTCH_TEST_ZOOM=1.5 CHROMELESS_NOTCH_TEST_RESIZE=1300
    ;;
  sites)
    OUT="${2:-$ROOT/tests/notch/results/sites}"
    for pair in apple:https://www.apple.com/ youtube:https://www.youtube.com/ github:https://github.com/ \
                wikipedia:https://www.wikipedia.org/ reddit:https://www.reddit.com/ google:https://www.google.com/ \
                duckduckgo:https://duckduckgo.com/ mdn:https://developer.mozilla.org/en-US/ \
                hackernews:https://news.ycombinator.com/ developer-apple:https://developer.apple.com/; do
      run "${pair%%:*}" "${pair#*:}" "$OUT"
    done
    ;;
  one) run "$2" "$3" "${4:-$ROOT/tests/notch/results/one}" ;;
  fullscreen)
    OUT="${2:-$ROOT/tests/notch/results/fullscreen}"
    MODE_ENV="CHROMELESS_FULLPANEL=1 CHROMELESS_NOTCH_GUARD=1 CHROMELESS_NOTCH_MODE=hybrid CHROMELESS_NOTCH_TEST_FULLSCREEN=1"
    run fixed-centered-nav "file://$FIX/fixed-centered-nav.html" "$OUT"
    run no-overlap-header "file://$FIX/no-overlap-header.html" "$OUT"
    run youtube https://www.youtube.com/ "$OUT"
    run github https://github.com/ "$OUT"
    ;;
  *) echo "usage: $0 fixtures|sites|one <name> <url> [outdir]"; exit 2 ;;
esac
