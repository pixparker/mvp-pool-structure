#!/usr/bin/env bash
# _lib.test.sh — smoke test for the framework-level helpers in _lib.sh.
#
# Exercises every public function so that lifting/relifting helpers
# doesn't silently break the contract project shims rely on.
#
# Run: bash deploy/bin/_lib.test.sh

set -u  # do not set -e — we *want* to test failure paths

# Disable lib::retry's linear backoff for the test suite (would push
# runtime to ~10s otherwise; we still exercise the same code path).
export LIB_RETRY_BACKOFF_BASE=0

HERE="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

fails=0
assert_fail() { echo "FAIL: $*" >&2; fails=$(( fails + 1 )); }

# ─── lib::log ─────────────────────────────────────────────────────────────────
# Goes to stderr; capture both streams and verify the line lands on stderr.
out_file="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "$out_file" "$err_file"' EXIT
lib::log info "test-message" >"$out_file" 2>"$err_file"
[[ -s "$out_file" ]] && assert_fail "lib::log wrote to stdout (must be stderr-only)"
grep -q "test-message" "$err_file" || assert_fail "lib::log did not emit message"

# ─── lib::require_env ─────────────────────────────────────────────────────────
# Set var present → no exit.
export PRESENT_VAR=ok
( lib::require_env PRESENT_VAR ) || assert_fail "lib::require_env exited on present var"

# ─── lib::arg_has ─────────────────────────────────────────────────────────────
lib::arg_has --foo --foo --bar || assert_fail "lib::arg_has missed --foo"
if lib::arg_has --baz --foo --bar; then
    assert_fail "lib::arg_has falsely matched --baz"
fi

# ─── lib::retry ───────────────────────────────────────────────────────────────
# Persistent failure → non-zero.
if lib::retry 2 "t" false 2>/dev/null; then
    assert_fail "lib::retry returned 0 for persistent failure"
fi

# Immediate success → 0.
if ! lib::retry 2 "t" true 2>/dev/null; then
    assert_fail "lib::retry returned non-zero for immediate success"
fi

# Exit-code propagation.
exit42() { return 42; }
lib::retry 1 "t" exit42 2>/dev/null
rc=$?
if [[ "$rc" != "42" ]]; then
    assert_fail "lib::retry didn't propagate exit code (expected 42, got $rc)"
fi

# Eventual success.
attempt_counter=0
flaky() { attempt_counter=$(( attempt_counter + 1 )); (( attempt_counter >= 3 )); }
if ! lib::retry 3 "t" flaky 2>/dev/null; then
    assert_fail "lib::retry didn't recover when 3rd attempt succeeded"
fi

# ─── lib::render_template ─────────────────────────────────────────────────────
tmp_tmpl="$(mktemp)"
trap 'rm -f "$out_file" "$err_file" "$tmp_tmpl"' EXIT

# Happy path.
printf 'host=@@HOST@@\nctn=@@CT@@\n' > "$tmp_tmpl"
got="$(lib::render_template "$tmp_tmpl" "HOST=example.com" "CT=app" 2>/dev/null)"
expected=$'host=example.com\nctn=app'
[[ "$got" == "$expected" ]] || assert_fail "lib::render_template happy-path mismatch: got=$got"

# Unfilled placeholder → error.
printf 'x=@@MISSING@@\n' > "$tmp_tmpl"
if lib::render_template "$tmp_tmpl" "OTHER=y" >/dev/null 2>&1; then
    assert_fail "lib::render_template accepted unfilled placeholder"
fi

# docker-compose ${VAR} must pass through.
printf 'image: ${REG}/@@APP@@:${TAG}\n' > "$tmp_tmpl"
got="$(lib::render_template "$tmp_tmpl" "APP=my-app" 2>/dev/null)"
[[ "$got" == 'image: ${REG}/my-app:${TAG}' ]] \
    || assert_fail "lib::render_template clobbered \${VAR}: got=$got"

# Missing file → error.
if lib::render_template /nonexistent/x.tmpl "K=v" >/dev/null 2>&1; then
    assert_fail "lib::render_template didn't error on missing file"
fi

# ─── lib::fmt_size / fmt_size_mib / fmt_duration ──────────────────────────────
[[ "$(lib::fmt_size 189792256)" == "181 MiB" ]] || assert_fail "fmt_size 189792256"
[[ "$(lib::fmt_size_mib 2048)" == "2.00 GiB" ]] || assert_fail "fmt_size_mib 2048"
[[ "$(lib::fmt_duration 33)" == "33s" ]]       || assert_fail "fmt_duration 33"
[[ "$(lib::fmt_duration 192)" == "3m 12s" ]]   || assert_fail "fmt_duration 192"
[[ "$(lib::fmt_duration 3661)" == "1h 01m 01s" ]] || assert_fail "fmt_duration 3661"

# ─── lib::_hyperlink ──────────────────────────────────────────────────────────
# Hard to assert OSC8 escapes without a TTY; just check it produces *some*
# output containing the URL.
got="$(lib::_hyperlink 'https://example.com' 'click me' 2>&1)"
echo "$got" | grep -q "https://example.com" || assert_fail "_hyperlink missed URL"

# ─── lib::smoke_check_one ─────────────────────────────────────────────────────
# Quickly assert the 3-arg signature works + returns non-zero on failure.
# Use localhost:1 which connection-refuses instantly (no DNS or 8s timeout).
if lib::smoke_check_one '127.0.0.1:1' /healthz 200 2>/dev/null; then
    assert_fail "lib::smoke_check_one returned 0 for unreachable host"
fi

# ─── lib::confirm ─────────────────────────────────────────────────────────────
# Feed 'y' to stdin → returns 0; feed 'n' → returns 1.
echo y | lib::confirm "OK?" 2>/dev/null || assert_fail "lib::confirm rejected 'y'"
if echo n | lib::confirm "OK?" 2>/dev/null; then
    assert_fail "lib::confirm accepted 'n'"
fi

# ─── double-source guard ──────────────────────────────────────────────────────
# Sourcing again is a no-op (MVPOOL_LIB_SOURCED guard).
[[ "${MVPOOL_LIB_SOURCED:-}" == "1" ]] || assert_fail "MVPOOL_LIB_SOURCED not set after source"

# ─── summary ──────────────────────────────────────────────────────────────────
if (( fails > 0 )); then
    echo "mvpool-local/_lib.sh: ${fails} test(s) failed" >&2
    exit 1
fi
exit 0
