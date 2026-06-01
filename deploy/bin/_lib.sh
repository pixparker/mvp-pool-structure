# shellcheck shell=bash
# mvpool-local — framework-level shell helpers shared by per-project deploy
# scripts (e.g., digital-menu/deploy/_lib.sh, future MVP-2/deploy/_lib.sh).
#
# Sourced, not executed. Lifted from digital-menu/deploy/_lib.sh on
# 2026-06-01 per MVP-E28-F07 (deploy-framework-lift report §2 surgical
# Move 1). Only fully-generic helpers live here — project-specific bits
# (apps.tsv reader, lab-pool constants, project endpoint lists, smoke
# manifests) stay project-side.
#
# Each project's _lib.sh sources this file first, then layers project
# helpers on top. The shim resolves the path via `mvpool-local`'s symlink
# (typically ~/.local/bin/mvpool-local → mvp-pool/deploy/bin/mvpool-local).
#
# Adding a helper here: must be project-agnostic. If it references a
# project slug, app list, or hostname, it belongs in the project shim,
# not here. When in doubt, leave it project-side and lift later (per
# the "build twice before abstracting" rule).

# Exit non-zero if sourced into a non-bash shell (helpers use arrays).
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "mvpool-local/_lib.sh: requires bash" >&2
    return 1 2>/dev/null || exit 1
fi

# Guard against double-sourcing. Distinct from the project-side guard
# (MIZRO_LIB_SOURCED etc.) so the shim can layer on top safely.
if [[ -n "${MVPOOL_LIB_SOURCED:-}" ]]; then
    return 0
fi
MVPOOL_LIB_SOURCED=1

# ─── colors ───────────────────────────────────────────────────────────────────
# ANSI colors only when stdout is a TTY.
if [[ -t 1 ]]; then
    LIB_C_DIM="\033[2m"
    LIB_C_RED="\033[31m"
    LIB_C_GREEN="\033[32m"
    LIB_C_YELLOW="\033[33m"
    LIB_C_RESET="\033[0m"
else
    LIB_C_DIM="" LIB_C_RED="" LIB_C_GREEN="" LIB_C_YELLOW="" LIB_C_RESET=""
fi

# ─── logging ──────────────────────────────────────────────────────────────────

# log <level> <msg...> — formatted line to stderr (so script stdout stays parseable).
lib::log() {
    local level="$1"; shift
    local color=""
    case "$level" in
        info)  color="$LIB_C_DIM" ;;
        ok)    color="$LIB_C_GREEN" ;;
        warn)  color="$LIB_C_YELLOW" ;;
        error) color="$LIB_C_RED" ;;
    esac
    printf '%b[%s]%b %s\n' "$color" "$level" "$LIB_C_RESET" "$*" >&2
}

# ─── env + flags ──────────────────────────────────────────────────────────────

# require_env <var> [<var> ...] — exit 2 with a clear message if any unset.
lib::require_env() {
    local missing=()
    for v in "$@"; do
        if [[ -z "${!v:-}" ]]; then
            missing+=("$v")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        lib::log error "missing required env: ${missing[*]}"
        exit 2
    fi
}

# arg_has <needle> <args...> — utility to check if a flag is present.
lib::arg_has() {
    local needle="$1"; shift
    for a in "$@"; do
        [[ "$a" == "$needle" ]] && return 0
    done
    return 1
}

# ─── interaction ──────────────────────────────────────────────────────────────

# confirm <prompt> — interactive y/N. Returns 0 on yes, 1 otherwise.
# Honors --confirm flag passed elsewhere (caller decides).
lib::confirm() {
    local prompt="${1:-Continue?}"
    local reply
    printf '%s [y/N] ' "$prompt" >&2
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ─── smoke checks ─────────────────────────────────────────────────────────────

# smoke_check_one <host> <path> <expected_status>
# Curl the URL, follow redirects (-L), check HTTP code. Echoes a status line and
# returns 0 (pass) or 1 (fail). 8s timeout to tolerate Iran-network jitter.
lib::smoke_check_one() {
    local host="$1" path="$2" expected="$3"
    local url="https://${host}${path}"
    local got
    got="$(curl -sS -o /dev/null -L --max-time 8 \
            -w '%{http_code}' "$url" 2>/dev/null || echo '000')"
    if [[ "$got" == "$expected" ]]; then
        lib::log ok "smoke ${url} → ${got}"
        return 0
    else
        lib::log error "smoke ${url} → ${got} (expected ${expected})"
        return 1
    fi
}

# ─── templating ───────────────────────────────────────────────────────────────

# lib::render_template <template-path> <KEY=value> ... — read a `.tmpl`
# file, replace every `@@KEY@@` placeholder with the matching value, and
# print to stdout. Errors out if any `@@…@@` placeholder remains unfilled
# (catches typos in the template or missing vars in the caller).
#
# We deliberately use `@@VAR@@` not `${VAR}` so docker-compose runtime
# variables (`${REGISTRY}`, `${SLUG}`, `${IMAGE_TAG}`) pass through
# untouched — the rendered compose.yaml still has them for `docker compose
# up` to resolve from .env on the pool.
lib::render_template() {
    local tmpl="$1"; shift
    [[ -f "$tmpl" ]] || { lib::log error "template not found: $tmpl"; return 1; }
    local -a sed_args=()
    while [[ $# -gt 0 ]]; do
        local pair="$1"; shift
        local k="${pair%%=*}" v="${pair#*=}"
        sed_args+=( -e "s|@@${k}@@|${v}|g" )
    done
    local rendered
    rendered="$(sed "${sed_args[@]}" "$tmpl")"
    if [[ "$rendered" =~ @@[A-Z_]+@@ ]]; then
        lib::log error "unfilled placeholders in rendered template: $tmpl"
        printf '%s\n' "$rendered" | grep -oE '@@[A-Z_]+@@' | sort -u >&2
        return 1
    fi
    printf '%s\n' "$rendered"
}

# ─── retry ────────────────────────────────────────────────────────────────────

# lib::retry <attempts> <label> <cmd...> — run <cmd...>, retry up to
# <attempts>-1 times on non-zero exit, with linear backoff between tries.
#
# Why: today the Iran ↔ Hetzner rsync drops with "unexpected end of file"
# at random points (we hit this twice on 2026-05-31). mvpool-local doesn't
# auto-resume, so we wrap the whole `mvpool-local deploy --load-only` call.
# rsync's `--inplace --append --timeout=120` (already set in mvpool-local)
# resumes from the partial file on the next attempt, so retry is cheap.
#
# Exits with the last attempt's exit code on permanent failure.
#
# Note: we capture `$?` BEFORE the `if cmd; then ...; fi` falls through —
# bash sets `$?` to 0 after a no-branch-executed if, which once caused
# lib::retry to silently report success after 3 failures (2026-05-31).
lib::retry() {
    local attempts="$1" label="$2"; shift 2
    local n=1 rc=0 backoff
    while (( n <= attempts )); do
        if (( n > 1 )); then
            # LIB_RETRY_BACKOFF_BASE overrides the 10s/attempt linear sleep.
            # Tests set it to 0 to keep the suite fast; real deploys leave
            # it alone so flaky Iran ↔ Hetzner rsync gets breathing room.
            backoff=$(( (n - 1) * ${LIB_RETRY_BACKOFF_BASE:-10} ))
            if (( backoff > 0 )); then
                lib::log warn "${label}: attempt ${n}/${attempts} after ${backoff}s sleep"
                sleep "$backoff"
            fi
        fi
        "$@"
        rc=$?
        if (( rc == 0 )); then
            (( n > 1 )) && lib::log ok "${label}: succeeded on attempt ${n}"
            return 0
        fi
        lib::log warn "${label}: attempt ${n}/${attempts} failed (exit ${rc})"
        n=$(( n + 1 ))
    done
    lib::log error "${label}: giving up after ${attempts} attempts (last exit ${rc})"
    return "$rc"
}

# ─── formatters ───────────────────────────────────────────────────────────────

# fmt_size <bytes> — human-friendly: MiB up to 1024, then GiB with 2 decimals.
# All our images are >= a few MB so we don't bother with KiB.
#   189792256 → "181 MiB"
#   1131267317 → "1.05 GiB"
lib::fmt_size() {
    local bytes=$1
    local mib=$(( bytes / 1024 / 1024 ))
    if (( mib < 1024 )); then
        printf '%d MiB' "$mib"
    else
        printf '%d.%02d GiB' "$(( mib / 1024 ))" "$(( (mib * 100 / 1024) % 100 ))"
    fi
}

# fmt_size_mib <mib> — same as fmt_size but takes MiB-int input directly,
# saving a divide when the caller already has MiB.
lib::fmt_size_mib() {
    local mib=$1
    if (( mib < 1024 )); then
        printf '%d MiB' "$mib"
    else
        printf '%d.%02d GiB' "$(( mib / 1024 ))" "$(( (mib * 100 / 1024) % 100 ))"
    fi
}

# fmt_duration <seconds> — human-friendly time.
#    33 → "33s"
#   192 → "3m 12s"
#  3661 → "1h 01m 01s"
lib::fmt_duration() {
    local s=$1
    if (( s < 60 )); then
        printf '%ds' "$s"
    elif (( s < 3600 )); then
        printf '%dm %02ds' "$(( s / 60 ))" "$(( s % 60 ))"
    else
        printf '%dh %02dm %02ds' \
            "$(( s / 3600 ))" "$(( (s / 60) % 60 ))" "$(( s % 60 ))"
    fi
}

# ─── terminal hyperlinks ──────────────────────────────────────────────────────

# _hyperlink <url> [text] — emit an ANSI/OSC-8 terminal hyperlink that is
# cmd-clickable in iTerm2, Terminal.app (macOS 11+), VSCode integrated terminal,
# kitty, gnome-terminal, etc. Falls back to a plain colored URL on terminals
# that don't recognize OSC-8 (they ignore the escapes silently).
lib::_hyperlink() {
    local url="$1"
    local text="${2:-$url}"
    if [[ -n "$LIB_C_RESET" ]]; then
        # OSC 8 hyperlink + cyan-bold-underlined text + close hyperlink.
        printf '\033]8;;%s\033\\\033[36;1;4m%s\033[0m\033]8;;\033\\' "$url" "$text"
    else
        printf '%s' "$url"
    fi
}
