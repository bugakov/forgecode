#!/bin/sh
# forge-install — install the latest forge build from the bugakov/forgecode fork.
#
#   curl -fsSL https://raw.githubusercontent.com/bugakov/forgecode/main/forge-install.sh | sh
#
# The official installer (https://forgecode.dev/cli) is currently broken (404),
# and its URL is also hardcoded into forge's built-in `forge update`. This
# script is a drop-in replacement that downloads a release asset from
# github.com/bugakov/forgecode/releases (the fork publishes all three patches:
# herdr integration, non-multimodal crash fix, zsh/TUI rename prefill).
#
# Options:
#   --dir DIR       install into DIR instead of ~/.local/bin
#   --version       print script version and exit
#   --dry-run       resolve target + URL, do not install
#
# POSIX sh. No external deps beyond curl/wget.
#
# v1.1.0: added connect/max timeouts, download retries and progress output so
# a flaky or slow link cannot hang the installer silently.

set -u

REPO="bugakov/forgecode"
BASE_URL="https://github.com/${REPO}/releases/latest/download"

INSTALL_DIR="${FORGE_INSTALL_DIR:-}"
VERSION="1.1.0"
TRIES=3

log() { printf '%s\n' "[forge-install] $*"; }
die() { printf '%s\n' "[forge-install] ERROR: $*" >&2; exit 1; }

# ---- args ----
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
        --version) echo "forge-install $VERSION"; exit 0 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done

# ---- download helper ----
# fetch $1 -> stdout. Bounded by timeouts; diagnostics + progress go to
# stderr so stdout stays a clean binary stream.
fetch() {
    if command -v curl >/dev/null 2>&1; then
        # -f fail on HTTP errors, -L follow redirects, -S show errors;
        # --connect-timeout bounds the TCP handshake (the part that used to
        # hang for minutes), --max-time bounds the whole transfer,
        # --retry/--retry-delay re-attempt transient network failures,
        # --progress-bar shows a live meter so the run never looks dead.
        curl -fL -S \
            --connect-timeout 10 \
            --max-time 120 \
            --retry 1 \
            --retry-delay 2 \
            --progress-bar \
            "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -O- \
            --tries="$TRIES" \
            --timeout=30 \
            --waitretry=3 \
            --progress=dot:meter \
            "$1"
    else
        die "need curl or wget"
    fi
}

# ---- platform detection -> asset name ----
OS="$(uname -s 2>/dev/null || echo unknown)"
ARCH="$(uname -m 2>/dev/null || echo unknown)"

case "$OS" in
    Linux) os="linux" ;;
    Darwin) os="apple-darwin" ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) os="pc-windows-msvc" ;;
    *) die "unsupported OS: $OS" ;;
esac

case "$ARCH" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    armv7l|armv7) arch="armv7l" ;;
    *) die "unsupported architecture: $ARCH" ;;
esac

# asset name: forge-<arch>[-<libc>]-<os>[.exe]
case "$os" in
    apple-darwin)
        ASSET="forge-${arch}-apple-darwin"
        ;;
    pc-windows-msvc)
        ASSET="forge-${arch}-pc-windows-msvc.exe"
        ;;
    linux)
        # prefer gnu; fork publishes x86_64/aarch64 gnu binaries
        ASSET="forge-${arch}-unknown-linux-gnu"
        ;;
    *) die "internal error" ;;
esac

URL="${BASE_URL}/${ASSET}"

# ---- --dry-run ----
if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'OS=%s ARCH=%s\nASSET=%s\nURL=%s\n' "$OS" "$ARCH" "$ASSET" "$URL"
    exit 0
fi

# ---- resolve install dir ----
if [ -z "$INSTALL_DIR" ]; then
    if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
        INSTALL_DIR="/usr/local/bin"
    else
        INSTALL_DIR="$HOME/.local/bin"
    fi
fi

mkdir -p "$INSTALL_DIR" 2>/dev/null || die "cannot create $INSTALL_DIR"
if [ ! -w "$INSTALL_DIR" ]; then
    die "$INSTALL_DIR is not writable (use --dir or run as user with write access)"
fi

log "Downloading $ASSET (about 43 MB)"
log "  from $URL"
log "  each attempt is bounded; progress is shown below"

TMP="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/forge-install.$$")"

n=0
ok=0
while [ "$n" -lt "$TRIES" ]; do
    n=$((n + 1))
    rm -f "$TMP"
    if fetch "$URL" > "$TMP"; then
        ok=1
        break
    fi
    log "download attempt $n/$TRIES failed; retrying..."
    [ "$n" -lt "$TRIES" ] && sleep 3
done

if [ "$ok" != "1" ]; then
    rm -f "$TMP"
    die "download failed after $TRIES attempts (asset '$ASSET' may not exist for ${arch}-${os}; see --dry-run)"
fi

# sanity: reject tiny/HTML responses (404 pages, redirect stubs)
SZ=$(wc -c < "$TMP" 2>/dev/null || echo 0)
if [ "$SZ" -lt 100000 ]; then
    head -c 300 "$TMP" >&2; echo >&2
    rm -f "$TMP"
    die "downloaded file looks wrong (${SZ} bytes); URL may be stale"
fi

chmod +x "$TMP" 2>/dev/null || die "cannot chmod downloaded binary"

TARGET="$INSTALL_DIR/forge"
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    BAK="$TARGET.bak.$(date +%Y%m%d%H%M%S)"
    mv "$TARGET" "$BAK" 2>/dev/null && log "backed up old binary to $BAK"
fi

mv "$TMP" "$TARGET" 2>/dev/null || die "cannot move binary into $INSTALL_DIR"
log "Installed forge to $TARGET"

# ---- PATH check ----
case ":$PATH:" in
    *":$INSTALL_DIR:"*) : ;;
    *) log "NOTE: $INSTALL_DIR is not in PATH."
       case "$INSTALL_DIR" in
           "$HOME/.local/bin")
               log "  add it with:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && exec zsh" ;;
       esac
       ;;
esac

log "Done. Run 'forge --version' to verify."

exit 0
