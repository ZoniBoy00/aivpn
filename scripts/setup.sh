#!/bin/bash
# ============================================================================
#  AiVPN — setup.sh
# ----------------------------------------------------------------------------
#  One-time setup: validates prerequisites, provisions a Proton WireGuard
#  config as config/<location>.conf and builds the image.
#
#  Usage:
#    ./scripts/setup.sh                                  interactive (location "fi")
#    ./scripts/setup.sh --location us                    interactive, config/us.conf
#    ./scripts/setup.sh --location us --config path/to/proton-wg.conf
#    ./scripts/setup.sh --build-only                     skip config provisioning
# ============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_NAME="${AIVPN_IMAGE:-aivpn:latest}"
MODE="interactive"
CONFIG_SRC=""
LOCATION="fi"

while [ $# -gt 0 ]; do
    case "$1" in
        --config)     shift; CONFIG_SRC="${1:-}"; MODE="noninteractive" ;;
        --location)   shift; LOCATION="${1:-}" ;;
        --build-only) MODE="build-only" ;;
        -h|--help)    sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

banner() {
cat <<'EOF'
  █████╗ ██╗██╗   ██╗██████╗ ███╗   ██╗
  ██╔══██╗██║██║   ██║██╔══██╗████╗  ██║
  ███████║██║██║   ██║██████╔╝██╔██╗ ██║
  ██╔══██║██║╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║
  ██║  ██║██║ ╚████╔╝  ██║     ██║ ╚████║
  ╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝     ╚═╝  ╚═══╝
   Agent-Grade WireGuard Relay for Proton VPN
EOF
}

echo_info() { echo "[setup] $*"; }
echo_err()  { echo "[setup][error] $*" >&2; }

[[ "$LOCATION" =~ ^[a-z0-9_-]+$ ]] || { echo_err "invalid --location '$LOCATION' (use a-z, 0-9, _ and -)"; exit 1; }
CONFIG_DEST="$ROOT/config/${LOCATION}.conf"

banner
echo

# --- Prerequisites -----------------------------------------------------------

command -v docker >/dev/null 2>&1 || { echo_err "docker not found in PATH"; exit 1; }
command -v wg     >/dev/null 2>&1 || echo_info "wg not installed on host (not required — container handles it)"

# --- Proton WireGuard config provisioning -------------------------------------

if [ "$MODE" != "build-only" ]; then
    if [ -f "$CONFIG_DEST" ]; then
        echo_info "Config already exists at $CONFIG_DEST — keeping it."
        echo_info "Delete it and re-run to re-provision."
    else
        echo "┌──────────────────────────────────────────────────────────────────┐"
        echo "│  1. Sign in at  https://account.protonvpn.com/downloads          │"
        echo "│  2. WireGuard configuration → Create config (GNU/Linux)          │"
        echo "│  3. Pick a server + options, download the .conf file             │"
        echo "└──────────────────────────────────────────────────────────────────┘"
        echo

        if [ "$MODE" = "noninteractive" ]; then
            [ -n "$CONFIG_SRC" ] || { echo_err "--config requires a path"; exit 1; }
            [ -f "$CONFIG_SRC" ] || { echo_err "config not found: $CONFIG_SRC"; exit 1; }
        else
            read -r -p "  Path to the downloaded Proton .conf file: " CONFIG_SRC
            [ -n "$CONFIG_SRC" ] || { echo_err "no path given"; exit 1; }
            [ -f "$CONFIG_SRC" ] || { echo_err "file not found: $CONFIG_SRC"; exit 1; }
        fi

        # Sanity checks on the config before accepting it
        grep -q '^\[Interface\]' "$CONFIG_SRC" || { echo_err "not a WireGuard config (no [Interface])"; exit 1; }
        grep -q '^\[Peer\]' "$CONFIG_SRC"      || { echo_err "config has no [Peer] section"; exit 1; }
        grep -Eq '^PrivateKey[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{42,43}=' "$CONFIG_SRC" \
            || { echo_err "config has no valid PrivateKey — did Proton generate it?"; exit 1; }
        grep -q 'REPLACE_WITH' "$CONFIG_SRC" && { echo_err "config still contains REPLACE_WITH placeholders"; exit 1; }
        grep -Eq '^Endpoint[[:space:]]*=' "$CONFIG_SRC" || { echo_err "config has no Endpoint"; exit 1; }
        grep -Eq '^DNS[[:space:]]*=' "$CONFIG_SRC" || { echo_err "config has no DNS line (AiVPN refuses to run without tunnel DNS)"; exit 1; }

        mkdir -p "$ROOT/config"
        (umask 077 && tr -d '\r' < "$CONFIG_SRC" > "$CONFIG_DEST")
        chmod 600 "$CONFIG_DEST"
        echo_info "Config provisioned → $CONFIG_DEST (mode 600)"
        if [ "$(id -u)" -ne 0 ]; then
            echo_info "The hardened container can only read a mode-600 config owned by root:"
            echo_info "  sudo chown root:root $CONFIG_DEST     (not needed with rootless Docker)"
        fi
    fi
fi

# --- Build ---------------------------------------------------------------------

echo_info "Building image: $IMAGE_NAME"
docker build -t "$IMAGE_NAME" "$ROOT"

echo
echo "✓ Setup complete!"
echo
echo "  Start the relay:   ./scripts/aivpn up $LOCATION      (or: make up LOCATION=$LOCATION)"
echo "  Wait for tunnel:   ./scripts/aivpn wait"
echo "  Check egress IP:   ./scripts/aivpn ip"
echo "  SOCKS5 endpoint:   ./scripts/aivpn socks"
