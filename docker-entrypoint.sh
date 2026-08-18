#!/bin/bash
# ============================================================================
#  AiVPN — docker-entrypoint.sh
# ----------------------------------------------------------------------------
#  Brings up a WireGuard tunnel inside the container using a Proton VPN
#  config, enforces an iptables kill switch (no leak outside the tunnel),
#  runs a SOCKS5 proxy (microsocks) and exposes helper commands for agents.
#
#  Commands:
#    daemon     persistent mode with health checks + auto-reconnect (default)
#    connect    one-shot connect, print egress IP, exit
#    status     show tunnel + recent logs
#    stop       tear down cleanly
#    curl       run curl inside the container (goes through the tunnel)
#    safefetch  fetch URL through tunnel with prompt-injection scanning
#    version    print AiVPN banner + version
#    help       this usage text
#
#  Environment:
#    WG_CONF                    path to WireGuard config (default /etc/wireguard/wg0.conf)
#    HEALTH_INTERVAL            seconds between health checks (default 60)
#    HEALTHCHECK_URL            URL used to verify real egress (default api.ipify.org)
#    RECONNECT_BACKOFF_INITIAL  seconds (default 10)
#    RECONNECT_BACKOFF_MAX      seconds (default 300)
#    MAX_INITIAL_CONNECT_ATTEMPTS  fail-fast cap on first connect (default 10)
#    SOCKS_PORT                 SOCKS5 listen port inside container (default 1080)
#    SAFEFETCH_TIMEOUT          curl timeout for safefetch in seconds (default 30)
#    FORCE_USERSPACE_WG         force wireguard-go for testing (default 0)
# ============================================================================

VERSION="1.0.0"
WG_CONF="${WG_CONF:-/etc/wireguard/wg0.conf}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-60}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://api.ipify.org}"
RECONNECT_BACKOFF_INITIAL="${RECONNECT_BACKOFF_INITIAL:-10}"
RECONNECT_BACKOFF_MAX="${RECONNECT_BACKOFF_MAX:-300}"
MAX_INITIAL_CONNECT_ATTEMPTS="${MAX_INITIAL_CONNECT_ATTEMPTS:-10}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
SAFEFETCH_TIMEOUT="${SAFEFETCH_TIMEOUT:-30}"
FORCE_USERSPACE_WG="${FORCE_USERSPACE_WG:-0}"
USE_USERSPACE_WG=0
WG_GO_PID=""

TUNNEL_UP_FLAG="/var/run/vpn-up"
RESOLV_CONF="/etc/resolv.conf"

log()  { echo "[aivpn] $*"; }
warn() { echo "[aivpn][warn] $*" >&2; }
die()  { echo "[aivpn][fatal] $*" >&2; exit 1; }

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

# --- Preflight ---------------------------------------------------------------

preflight() {
    [ -f "$WG_CONF" ] || die "WireGuard config not found at $WG_CONF (mount it read-only: -v \$(pwd)/config/wg0.conf:$WG_CONF:ro)"
    command -v wg     >/dev/null 2>&1 || die "wg not found (wireguard-tools missing)"
    command -v wg-quick >/dev/null 2>&1 || die "wg-quick not found"
    command -v iptables >/dev/null 2>&1 || warn "iptables not found — kill switch will be DISABLED"
    command -v ip     >/dev/null 2>&1 || die "ip not found (iproute2 missing)"
    # Kernel WireGuard module? If missing, use wireguard-go.
    if [ "$FORCE_USERSPACE_WG" = "1" ]; then
        log "Userspace WireGuard backend forced by configuration"
        USE_USERSPACE_WG=1
    elif ! ip link add wg-probe type wireguard 2>/dev/null; then
        if command -v wireguard-go >/dev/null 2>&1; then
            log "Kernel wireguard module unavailable — will use wireguard-go (userspace)"
            USE_USERSPACE_WG=1
        else
            warn "No kernel wireguard module and no wireguard-go — tunnel may fail"
        fi
    else
        ip link del wg-probe 2>/dev/null || true
        log "Kernel wireguard module available"
    fi
}

# --- Tunnel setup -------------------------------------------------------------

# Alpine has no resolvconf, so wg-quick's DNS directive would fail.
# We strip it and write /etc/resolv.conf ourselves.
setup_dns() {
    # Work on a writable copy — the mounted config may be read-only (:ro).
    # wg-quick is invoked with this path, so the DNS strip survives.
    local work_conf="/tmp/wg0.conf"
    if [ "$WG_CONF" != "$work_conf" ]; then
        cp "$WG_CONF" "$work_conf" 2>/dev/null || { warn "cannot copy $WG_CONF to $work_conf — DNS setup skipped"; return 0; }
        WG_CONF="$work_conf"
    fi

    local dns_line dns_server
    dns_line=$(grep -E '^[[:space:]]*DNS[[:space:]]*=' "$WG_CONF" | head -1 || true)
    [ -z "$dns_line" ] && return 0

    dns_server=$(echo "$dns_line" | sed -E 's/^[[:space:]]*DNS[[:space:]]*=[[:space:]]*//' | tr -d ' ' | cut -d, -f1)
    [ -z "$dns_server" ] && return 0

    # Strip DNS directive so nothing tries to invoke resolvconf
    sed -i -E '/^[[:space:]]*DNS[[:space:]]*=/d' "$WG_CONF"
    echo "nameserver $dns_server" > "$RESOLV_CONF"
    log "DNS set to $dns_server (tunnel DNS, work copy $WG_CONF)"
}

# Kill switch: block ALL egress that does not go through wg0.
# If wg0 goes down, the container goes dark — no fallback to the Docker
# bridge / host network. DNS is only allowed to the tunnel DNS server.
setup_firewall() {
    command -v iptables >/dev/null 2>&1 || { warn "iptables missing — kill switch not active (TRAFFIC MAY LEAK)"; return 0; }

    local ep_addr ep_ip ep_port tunnel_dns
    ep_addr=$(wg show wg0 endpoints 2>/dev/null | awk '{print $2}' | head -1)
    if [[ "$ep_addr" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        ep_ip="${BASH_REMATCH[1]}"
        ep_port="${BASH_REMATCH[2]}"
    else
        ep_ip="${ep_addr%:*}"
        ep_port="${ep_addr##*:}"
    fi
    tunnel_dns=$(awk '/^nameserver/{print $2; exit}' "$RESOLV_CONF" 2>/dev/null)

    if [ -z "$ep_ip" ]; then
        warn "could not determine WireGuard endpoint — kill switch NOT active"
        return 0
    fi

    iptables -F OUTPUT 2>/dev/null || true
    iptables -P OUTPUT DROP

    # Loopback — always allowed
    iptables -A OUTPUT -o lo -j ACCEPT

    # WireGuard endpoint (UDP encapsulation must reach the real server)
    iptables -A OUTPUT -p udp -d "$ep_ip" --dport "${ep_port:-51820}" -j ACCEPT

    # DNS — only to the tunnel's DNS server
    if [ -n "$tunnel_dns" ]; then
        iptables -A OUTPUT -p udp --dport 53 -d "$tunnel_dns" -j ACCEPT
        iptables -A OUTPUT -p tcp --dport 53 -d "$tunnel_dns" -j ACCEPT
        iptables -A OUTPUT -p udp --dport 53 -j DROP
        iptables -A OUTPUT -p tcp --dport 53 -j DROP
    fi

    # Everything through the tunnel
    iptables -A OUTPUT -o wg0 -j ACCEPT

    log "Kill switch active: endpoint ${ep_ip}:${ep_port:-51820} dns=${tunnel_dns:-none}"
}

teardown_firewall() {
    command -v iptables >/dev/null 2>&1 || return 0
    iptables -F OUTPUT 2>/dev/null || true
    iptables -P OUTPUT ACCEPT 2>/dev/null || true
}

# Bring the tunnel up. Tries the kernel module first, falls back to
# wireguard-go (userspace) when the host kernel lacks the module.
destroy_tunnel() {
    if [ -n "${WG_GO_PID:-}" ]; then
        kill "$WG_GO_PID" 2>/dev/null || true
        wait "$WG_GO_PID" 2>/dev/null || true
        WG_GO_PID=""
    fi
    ip link del wg0 2>/dev/null || true
}

bring_up_tunnel() {
    # Manual tunnel bring-up. wg-quick's `sysctl net.ipv4.conf.all.src_valid_mark`
    # and resolvconf steps fail inside Docker (proc/sys is mounted read-only),
    # so we replicate the essential steps directly: interface, keys, address,
    # MTU, routes. No fwmark policy routing — the default-route swap plus the
    # iptables kill switch keep all egress on wg0.
    local addr ep_ip default_gw default_dev
    destroy_tunnel
    if [ "$USE_USERSPACE_WG" -eq 1 ]; then
        log "Starting wireguard-go userspace backend"
        wireguard-go wg0 >/var/log/aivpn/wireguard-go.log 2>&1 &
        WG_GO_PID=$!
        for _ in $(seq 1 20); do
            ip link show wg0 >/dev/null 2>&1 && break
            sleep 0.1
        done
        ip link show wg0 >/dev/null 2>&1 || return 1
    else
        ip link add wg0 type wireguard || return 1
    fi
    wg-quick strip "$WG_CONF" > /tmp/wg0-stripped.conf 2>/dev/null || return 1
    wg setconf wg0 /tmp/wg0-stripped.conf || return 1
    addr=$(awk -F'[,= ]+' '/^Address/{print $2; exit}' "$WG_CONF")
    [ -n "$addr" ] || addr="10.2.0.2/32"
    ip -4 address add "$addr" dev wg0 || return 1
    ip link set mtu 1420 up dev wg0 || return 1

    # Pin the WG endpoint through the original default gateway so the UDP
    # handshake never loops back through wg0.
    default_gw=$(ip route show default | awk '/default/ {print $3; exit}')
    default_dev=$(ip route show default | awk '/default/ {print $5; exit}')
    ep_ip=$(grep -E '^Endpoint' "$WG_CONF" | head -1 | sed -E 's/.*= *//; s/:.*//; s/[][]//g')
    if [ -n "$default_gw" ] && [ -n "$default_dev" ] && [ -n "$ep_ip" ]; then
        ip route add "$ep_ip/32" via "$default_gw" dev "$default_dev" 2>/dev/null || true
    fi

    # All egress through the tunnel
    ip route replace default dev wg0 || return 1
    return 0
}

ensure_socks5() {
    # !!! MUST run only AFTER wg0 is up !!!
    # microsocks listens on 0.0.0.0:$SOCKS_PORT inside the container; starting
    # it before the tunnel would let early client connections egress via the
    # host network (IP leak).
    command -v microsocks >/dev/null 2>&1 || { warn "microsocks not found — SOCKS5 disabled"; return 0; }
    pgrep -x microsocks >/dev/null 2>&1 && return 0
    log "Starting SOCKS5 proxy on :$SOCKS_PORT"
    microsocks -i 0.0.0.0 -p "$SOCKS_PORT" >/var/log/aivpn/microsocks.log 2>&1 &
}

connect_once() {
    rm -f "$TUNNEL_UP_FLAG" 2>/dev/null || true
    log "Connecting using $WG_CONF ..."

    setup_dns
    if ! bring_up_tunnel; then
        warn "wg-quick up failed — see 'docker logs <name>'"
        return 1
    fi
    log "Tunnel is UP"

    setup_firewall
    ensure_socks5

    : > "$TUNNEL_UP_FLAG"
    log "Ready (flag: $TUNNEL_UP_FLAG)"
    return 0
}

cleanup() {
    log "Shutting down — tearing down tunnel + SOCKS5"
    teardown_firewall
    pkill -x microsocks 2>/dev/null || true
    destroy_tunnel
    rm -f "$TUNNEL_UP_FLAG" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

healthcheck() {
    [ -f "$TUNNEL_UP_FLAG" ] || return 1
    wg show wg0 >/dev/null 2>&1 || return 1
    curl -fsS -m 10 "$HEALTHCHECK_URL" >/dev/null 2>&1 || return 1
}

# --- Commands ------------------------------------------------------------------

cmd_daemon() {
    local attempt=1 wait_secs backoff
    while ! connect_once; do
        if [ "$attempt" -ge "$MAX_INITIAL_CONNECT_ATTEMPTS" ]; then
            die "connect failed ${attempt} consecutive times — bad config / key / network? (docker logs <name>)"
        fi
        wait_secs=$(( RECONNECT_BACKOFF_INITIAL * attempt ))
        [ "$wait_secs" -gt "$RECONNECT_BACKOFF_MAX" ] && wait_secs="$RECONNECT_BACKOFF_MAX"
        log "initial connect attempt ${attempt}/${MAX_INITIAL_CONNECT_ATTEMPTS} failed — retrying in ${wait_secs}s"
        sleep "$wait_secs" &
        wait $! || true
        attempt=$((attempt + 1))
    done

    backoff="$RECONNECT_BACKOFF_INITIAL"
    while true; do
        sleep "$HEALTH_INTERVAL" &
        wait $! || true
        if healthcheck; then
            backoff="$RECONNECT_BACKOFF_INITIAL"
            continue
        fi
        rm -f "$TUNNEL_UP_FLAG" 2>/dev/null || true
        log "tunnel down — reconnecting in ${backoff}s"
        teardown_firewall
        destroy_tunnel
        sleep "$backoff" &
        wait $! || true
        if connect_once; then
            log "reconnected"
            backoff="$RECONNECT_BACKOFF_INITIAL"
        else
            [ "$backoff" -lt "$RECONNECT_BACKOFF_MAX" ] && backoff=$((backoff * 2))
            [ "$backoff" -gt "$RECONNECT_BACKOFF_MAX" ] && backoff="$RECONNECT_BACKOFF_MAX"
        fi
    done
}

cmd_connect() {
    connect_once || return 1
    echo "[aivpn] Egress IP: $(curl -s -m 10 https://api.ipify.org)"
}

cmd_status() {
    echo "WireGuard status:"
    wg show wg0 || echo "wg0 interface not up"
    echo
    echo "Egress IP: $(curl -s -m 10 https://api.ipify.org 2>/dev/null || echo unknown)"
    echo
    echo "SOCKS5: $(pgrep -x microsocks >/dev/null && echo "running on :$SOCKS_PORT" || echo "not running")"
    echo "Tunnel flag: $([ -f "$TUNNEL_UP_FLAG" ] && echo up || echo down)"
}

cmd_safefetch() {
    # Fetch a URL through the tunnel with prompt-injection scanning.
    # Exit codes: 0 = clean, 77 = PI detected, 1 = fetch error
    local url fetch_output content_len scan_stderr ts
    url="${1:-}"
    [ -z "$url" ] && { echo "Usage: safefetch <url> [curl-options...]" >&2; return 1; }
    shift

    fetch_output=$(curl -s -m "$SAFEFETCH_TIMEOUT" -A "Mozilla/5.0 (compatible; aivpn safefetch)" "$@" "$url" 2>/dev/null)
    local fetch_rc=$?
    if [ "$fetch_rc" -ne 0 ]; then
        echo "[aivpn] safefetch: curl failed (exit $fetch_rc)" >&2
        return 1
    fi

    content_len=${#fetch_output}
    scan_stderr=$(mktemp)
    printf '%s' "$fetch_output" | /usr/local/bin/pi-scan.sh 2>"$scan_stderr"
    local scan_rc=$?
    if [ "$scan_rc" -eq 77 ]; then
        echo "[aivpn] safefetch: PROMPT INJECTION detected — content blocked" >&2
        cat "$scan_stderr" >&2
        rm -f "$scan_stderr"
        return 77
    fi
    printf '%s\n' "$fetch_output"
    rm -f "$scan_stderr"
    return 0
}

usage() {
cat <<EOF
AiVPN v${VERSION} — Agent-Grade WireGuard Relay for Proton VPN

Usage: docker run ... aivpn <command> [args]

Commands:
  daemon                 persistent mode with health checks + reconnect (default)
  connect                one-shot connect, print egress IP, exit
  status                 show tunnel + SOCKS5 status
  stop                   tear down cleanly
  curl <args>            run curl through the tunnel
  safefetch <url>        fetch URL through tunnel with PI scanning (exit 77 = blocked)
  version                print banner + version
  help                   this text

Environment (docker run -e ...):
  WG_CONF                    WireGuard config path (default /etc/wireguard/wg0.conf)
  HEALTH_INTERVAL            health check interval seconds (default 60)
  HEALTHCHECK_URL             egress URL for health checks (default https://api.ipify.org)
  SOCKS_PORT                 SOCKS5 port inside container (default 1080)
  SAFEFETCH_TIMEOUT           curl timeout seconds (default 30)
  FORCE_USERSPACE_WG          force userspace WireGuard for testing (default 0)
EOF
}

# --- Dispatch -------------------------------------------------------------------

case "${1:-daemon}" in
    daemon)     banner; preflight; cmd_daemon ;;
    connect)    banner; preflight; cmd_connect ;;
    status)     banner; cmd_status ;;
    stop|down)  cleanup ;;
    curl)       shift; exec curl "$@" ;;
    safefetch)  shift; cmd_safefetch "$@" ;;
    version)    banner; echo "AiVPN v${VERSION}" ;;
    help|-h|--help) usage ;;
    *)
        echo "Unknown command: $1" >&2
        usage >&2
        exit 1
        ;;
esac
