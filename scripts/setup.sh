#!/bin/bash
# ============================================================================
#  AiVPN — setup.sh
# ----------------------------------------------------------------------------
#  One-time setup: validates prerequisites, provisions the Proton WireGuard
#  config and builds the image.
#
#  Usage:
#    ./scripts/setup.sh              interactive (asks for config path)
#    ./scripts/setup.sh --config path/to/proton-wg.conf
#    ./scripts/setup.sh --build-only  (skip config provisioning)
# ============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DEST="$ROOT/config/wg0.conf"
IMAGE_NAME="${AIVPN_IMAGE:-aivpn}"
MODE="interactive"
CONFIG_SRC=""

while [ $# -gt 0 ]; do
    case "$1" in
        --config)   shift; CONFIG_SRC="${1:-}"; MODE="noninteractive" ;;
        --build-only) MODE="build-only" ;;
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

# --- Prerequisites -----------------------------------------------------------

command -v docker >/dev/null 2>&1 || { echo_err "docker not found in PATH"; exit 1; }
command -v wg     >/dev/null 2>&1 || echo_info "wg not installed on host (not required — container handles it)"

# --- Proton WireGuard config provisioning -------------------------------------

if [ "$MODE" != "build-only" ]; then
    if [ -f "$CONFIG_DEST" ]; then
        echo_info "Config already exists at $CONFIG_DEST — keeping it."
        echo_info "Delete it and re-run to re-provision."
    else
        echo
        echo "┌──────────────────────────────────────────────────────────────────┐"
        echo "│  1. Sign in at  https://account.protonvpn.com                    │"
        echo "│  2. Go to  Downloads → WireGuard configuration                   │"
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
        grep -q 'PrivateKey' "$CONFIG_SRC"    || { echo_err "config has no PrivateKey — did Proton generate it?"; exit 1; }
        grep -q '^\[Peer\]' "$CONFIG_SRC"     || { echo_err "config has no [Peer] section"; exit 1; }
        grep -q '^PrivateKey = ' "$CONFIG_SRC" && echo_err "!! config still contains a placeholder PrivateKey" || true

        mkdir -p "$ROOT/config"
        umask 077
        cp "$CONFIG_SRC" "$CONFIG_DEST"
        echo_info "Config provisioned → $CONFIG_DEST (chmod 600 recommended: chmod 600 $CONFIG_DEST)"
    fi
fi

# --- Build ---------------------------------------------------------------------

echo_info "Building image: $IMAGE_NAME"
docker build -t "$IMAGE_NAME" "$ROOT"

echo
echo "✓ Setup complete!"
echo
echo "  Start the relay:"
echo "    docker run -d --name vpn-proton --cap-add=NET_ADMIN --device=/dev/net/tun \\"
echo "      -v $CONFIG_DEST:/etc/wireguard/wg0.conf:ro \\"
echo "      -p 127.0.0.1::1080 \\"
echo "      $IMAGE_NAME daemon"
echo
echo "  Test it:"
echo "    docker exec vpn-proton curl -s https://ip-api.com/json"
