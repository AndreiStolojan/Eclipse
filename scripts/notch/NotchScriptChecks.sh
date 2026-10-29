#!/bin/bash
# Checks render.sh and check.sh against stub tools in a throwaway copy of the repo, so they run on any Unix without
# Xcode and never touch the real docs/images or .build. Run it directly: scripts/notch/NotchScriptChecks.sh
# Assertions are literal shell expressions evaluated by expect; their variable references are deferred on purpose.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

expect() {
    if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi
}

# A fresh copy of one script in a repo with no .build, plus stub tools first on PATH.
fresh_repo() {
    rm -rf "${work:?}/repo" "${work:?}/bin"
    mkdir -p "$work/repo/scripts" "$work/bin"
    cp "$repo_dir/scripts/$1" "$work/repo/scripts/"
}

stub() {
    printf '#!/bin/bash\n%s\n' "$2" > "$work/bin/$1"
    chmod +x "$work/bin/$1"
}

# render.sh: the stub xcodebuild "builds" an app that writes one PNG per render name into NOTCH_RENDER_DIR.
renders="readme-hero readme-now-playing readme-indicators readme-calendar readme-timer readme-shelf readme-downloads
native-lock-media-glass"
render_setup() {
    fresh_repo render.sh
    stub defaults 'exit 0'
    stub xcodebuild "app=\"$work/repo/.build/RenderData/Build/Products/Debug/Eclipse Render.app/Contents/MacOS\"
mkdir -p \"\$app\"
printf '#!/bin/bash\nfor name in %s; do echo new > \"\$NOTCH_RENDER_DIR/\$name.png\"; done\n' '$1' > \"\$app/Eclipse Render\"
chmod +x \"\$app/Eclipse Render\""
    mkdir -p "$work/repo/docs/images/notifications"
    echo old > "$work/repo/docs/images/hero.png"
    echo keep > "$work/repo/docs/images/sotto-dictation.png"
    echo keep > "$work/repo/docs/images/notifications/alert.png"
}

render_setup "${renders//$'\n'/ }"
status=0
PATH="$work/bin:$PATH" "$work/repo/scripts/render.sh" > "$work/out" 2>&1 || status=$?
expect "render.sh runs in a clone without .build" '[[ $status -eq 0 ]]'
expect "render.sh replaces the README images" '[[ "$(cat "$work/repo/docs/images/hero.png")" == new && -f "$work/repo/docs/images/lock-screen.png" ]]'
expect "render.sh keeps images it does not manage" '[[ -f "$work/repo/docs/images/sotto-dictation.png" && -f "$work/repo/docs/images/notifications/alert.png" ]]'

render_setup "readme-hero"
status=0
PATH="$work/bin:$PATH" "$work/repo/scripts/render.sh" > "$work/out" 2>&1 || status=$?
expect "render.sh fails when a README render is missing" '[[ $status -ne 0 ]]'
expect "render.sh changes no image when one is missing" '[[ "$(cat "$work/repo/docs/images/hero.png")" == old ]]'

# check.sh: the stub swiftc writes the output binary; hover-checks hangs, every other check passes.
check_setup() {
    fresh_repo check.sh
    mkdir -p "$work/repo/scripts/notch"
    echo 'import sys; sys.exit(0)' > "$work/repo/scripts/notch/NotchCLIChecks.py"
    echo 'exit 0' > "$work/repo/scripts/notch/NotchScriptChecks.sh"
    stub swiftc "while [[ \$# -gt 0 && \$1 != -o ]]; do shift; done
case \"\$2\" in */$1) body='sleep 30' ;; *) body='exit 0' ;; esac
printf '#!/bin/bash\n%s\n' \"\$body\" > \"\$2\"; chmod +x \"\$2\""
}

check_setup none
status=0
PATH="$work/bin:$PATH" "$work/repo/scripts/check.sh" > "$work/out" 2>&1 || status=$?
expect "check.sh passes when every check passes" '[[ $status -eq 0 ]]'

check_setup hover-checks
status=0
start=$SECONDS
ECLIPSE_CHECK_LIMIT=1 PATH="$work/bin:$PATH" "$work/repo/scripts/check.sh" > "$work/out" 2>&1 || status=$?
expect "check.sh stops a check at its deadline" '[[ $status -ne 0 && $((SECONDS - start)) -lt 10 ]]'
expect "check.sh names the check that ran out of time" 'grep -q "hover-checks did not finish within 1 s" "$work/out"'

# The deadline must not depend on GNU timeout, which macOS does not ship.
expect "check.sh does not call timeout" '! grep -qE "(^|[^_[:alnum:]])timeout " "$repo_dir/scripts/check.sh"'

[[ $failures -eq 0 ]] || { echo "$failures script checks failed" >&2; exit 1; }
echo "All script checks passed"
