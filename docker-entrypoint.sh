#!/bin/bash
# ============================================================================
#  AiVPN — docker-entrypoint.sh
# ----------------------------------------------------------------------------
#  Brings up a WireGuard tunnel inside the container using a Proton VPN
#  config, enforces an iptables kill switch (no leak outside the tunnel),
#  runs a SOCKS5 proxy (microsocks) and exposes helper commands for agents.
#
#  Startup order (fail-closed):
#    1. parse the config once (endpoint, IPv4 address, DNS, MTU)
#    2. remember the original default route
#    3. block IPv6 + install the IPv4 kill switch   <- before any tunnel exists
#    4. bring up wg0, swap the default route, start SOCKS5
#  The kill switch stays in place across reconnects; it is never relaxed.
#
#  Commands:
#    daemon     persistent mode with health checks + auto-reconnect (default)
#    connect    one-shot connect, print egress IP, exit
#    status     show tunnel + recent logs
#    stop       ask the daemon (PID 1) to shut down
#    curl       run curl inside the container (goes through the tunnel)
#    safefetch  fetch URL through tunnel with heuristic prompt-injection scan
#    version    print AiVPN banner + version
#    help       this usage text
#
#  Environment:
#    WG_CONF                    path to WireGuard config (default /etc/wireguard/wg0.conf)
#    TUNNEL_DNS                 override the DNS server from the config
#    HEALTH_INTERVAL            seconds between health checks (default 60)
#    HEALTHCHECK_URL            URL used to verify real egress (default api.ipify.org)
#    RECONNECT_BACKOFF_INITIAL  seconds (default 10)
#    RECONNECT_BACKOFF_MAX      seconds (default 300)
#    MAX_INITIAL_CONNECT_ATTEMPTS  fail-fast cap on first connect (default 10)
#    SOCKS_PORT                 SOCKS5 listen port inside container (default 1080)
#    SOCKS_ALLOW_FROM           who may use SOCKS5: "gateway" (default), "any",
#                               or a comma-separated list of IPs/CIDRs
#    SOCKS_USER / SOCKS_PASS    optional SOCKS5 username/password auth
#    SAFEFETCH_TIMEOUT          curl timeout for safefetch in seconds (default 30)
#    SAFEFETCH_MAX_BYTES        max response size for safefetch (default 10485760)
#    SAFEFETCH_MODE             "block" (default) or "warn"
#    FORCE_USERSPACE_WG         force wireguard-go for testing (default 0)
# ============================================================================

VERSION="1.1.0"
WG_CONF="${WG_CONF:-/etc/wireguard/wg0.conf}"
TUNNEL_DNS="${TUNNEL_DNS:-}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-60}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://api.ipify.org}"
RECONNECT_BACKOFF_INITIAL="${RECONNECT_BACKOFF_INITIAL:-10}"
RECONNECT_BACKOFF_MAX="${RECONNECT_BACKOFF_MAX:-300}"
MAX_INITIAL_CONNECT_ATTEMPTS="${MAX_INITIAL_CONNECT_ATTEMPTS:-10}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
SOCKS_ALLOW_FROM="${SOCKS_ALLOW_FROM:-gateway}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASS="${SOCKS_PASS:-}"
SAFEFETCH_TIMEOUT="${SAFEFETCH_TIMEOUT:-30}"
SAFEFETCH_MAX_BYTES="${SAFEFETCH_MAX_BYTES:-10485760}"
SAFEFETCH_MODE="${SAFEFETCH_MODE:-block}"
FORCE_USERSPACE_WG="${FORCE_USERSPACE_WG:-0}"
USE_USERSPACE_WG=0
WG_GO_PID=""

TUNNEL_UP_FLAG="/var/run/vpn-up"
RESOLV_CONF="/etc/resolv.conf"
STRIPPED_CONF="/tmp/wg0-stripped.conf"
DOCKER_DNS="127.0.0.11"

# Parsed once from the config by parse_config()
EP_IP="" EP_PORT="" TUN_DNS="" TUN_MTU=""
TUN_ADDRS=()
# Saved once by save_default_route() before the default route is swapped
ORIG_GW="" ORIG_DEV=""

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

# --- Config parsing ------------------------------------------------------------

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# First value of a "Key = value" line (case-insensitive key, CRLF-safe).
conf_value() {
    awk -v k="$1" '
        { line = $0; sub(/\r$/, "", line) }
        tolower(line) ~ "^[[:space:]]*" tolower(k) "[[:space:]]*=" {
            sub(/^[^=]*=[[:space:]]*/, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line
            exit
        }' "$WG_CONF"
}

parse_config() {
    [ -f "$WG_CONF" ] || die "WireGuard config not found at $WG_CONF (mount it read-only: -v \$(pwd)/config/wg0.conf:$WG_CONF:ro)"
    [ -r "$WG_CONF" ] || die "WireGuard config at $WG_CONF is not readable"

    local ep ep_host entry
    ep=$(conf_value Endpoint)
    [ -n "$ep" ] || die "config has no Endpoint line"
    if [[ "$ep" =~ ^\[.+\]:[0-9]+$ ]]; then
        die "IPv6 endpoints are not supported (IPv6 is blocked inside the container): $ep"
    elif [[ "$ep" =~ ^([^:]+):([0-9]+)$ ]]; then
        ep_host="${BASH_REMATCH[1]}"
        EP_PORT="${BASH_REMATCH[2]}"
    else
        die "cannot parse Endpoint '$ep' (expected host:port)"
    fi
    if is_ipv4 "$ep_host"; then
        EP_IP="$ep_host"
    else
        # Resolved once, before the kill switch is installed.
        EP_IP=$(getent ahostsv4 "$ep_host" 2>/dev/null | awk '{print $1; exit}')
        is_ipv4 "$EP_IP" || die "cannot resolve Endpoint host '$ep_host' to an IPv4 address"
        log "Endpoint $ep_host resolved to $EP_IP"
    fi

    TUN_ADDRS=()
    IFS=',' read -ra entries <<< "$(conf_value Address)"
    for entry in "${entries[@]}"; do
        entry="${entry//[[:space:]]/}"
        [[ "$entry" == *.* ]] && TUN_ADDRS+=("$entry")
    done
    [ "${#TUN_ADDRS[@]}" -gt 0 ] || die "config has no IPv4 Address"

    if [ -n "$TUNNEL_DNS" ]; then
        TUN_DNS="$TUNNEL_DNS"
    else
        IFS=',' read -ra entries <<< "$(conf_value DNS)"
        for entry in "${entries[@]}"; do
            entry="${entry//[[:space:]]/}"
            if is_ipv4 "$entry"; then TUN_DNS="$entry"; break; fi
        done
    fi
    is_ipv4 "$TUN_DNS" || die "no IPv4 DNS server in the config — add 'DNS = 10.2.0.1' or set TUNNEL_DNS (refusing to fall back to Docker's resolver, which would leak DNS)"

    TUN_MTU=$(conf_value MTU)
    [[ "$TUN_MTU" =~ ^[0-9]+$ ]] || TUN_MTU=1420

    # Keep only what `wg setconf` understands (same keys wg-quick strips).
    (umask 077; awk '
        { line = $0; sub(/\r$/, "", line); key = tolower(line); sub(/[[:space:]]*=.*/, "", key); gsub(/[[:space:]]/, "", key) }
        key ~ /^(address|dns|mtu|table|preup|postup|predown|postdown|saveconfig)$/ { next }
        { print line }' "$WG_CONF" > "$STRIPPED_CONF") || die "cannot write $STRIPPED_CONF"
}

# --- Preflight -------------------------------------------------------------------

preflight() {
    parse_config
    command -v wg       >/dev/null 2>&1 || die "wg not found (wireguard-tools missing)"
    command -v ip       >/dev/null 2>&1 || die "ip not found (iproute2 missing)"
    command -v iptables >/dev/null 2>&1 || die "iptables not found — refusing to run without a kill switch"
    # Kernel WireGuard module? If missing, use wireguard-go.
    if [ "$FORCE_USERSPACE_WG" = "1" ]; then
        log "Userspace WireGuard backend forced by configuration"
        USE_USERSPACE_WG=1
    elif ! ip link add wg-probe type wireguard 2>/dev/null; then
        command -v wireguard-go >/dev/null 2>&1 || die "no kernel wireguard module and no wireguard-go"
        log "Kernel wireguard module unavailable — will use wireguard-go (userspace)"
        USE_USERSPACE_WG=1
    else
        ip link del wg-probe 2>/dev/null || true
        log "Kernel wireguard module available"
    fi
}

# --- Network lockdown (runs once, before the first tunnel) ----------------------

save_default_route() {
    ORIG_GW=$(ip -4 route show default | awk '/^default/ {for (i = 1; i < NF; i++) if ($i == "via") {print $(i + 1); exit}}')
    ORIG_DEV=$(ip -4 route show default | awk '/^default/ {for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
    [ "$ORIG_DEV" = "wg0" ] && die "default route already points at wg0 — is another AiVPN instance running in this container?"
    [ -n "$ORIG_GW" ] && [ -n "$ORIG_DEV" ] || die "cannot determine the container's default gateway"
}

setup_dns() {
    printf 'nameserver %s\n' "$TUN_DNS" > "$RESOLV_CONF" || die "cannot write $RESOLV_CONF"
    log "DNS set to $TUN_DNS (tunnel DNS)"
}

# IPv6 is never routed through the tunnel, so it must not work at all.
block_ipv6() {
    if [ ! -e /proc/net/if_inet6 ]; then
        log "IPv6 stack not present — nothing to block"
        return 0
    fi
    if command -v ip6tables >/dev/null 2>&1 \
        && ip6tables -F INPUT && ip6tables -F OUTPUT && ip6tables -F FORWARD \
        && ip6tables -A INPUT -i lo -j ACCEPT && ip6tables -A OUTPUT -o lo -j ACCEPT \
        && ip6tables -P INPUT DROP && ip6tables -P OUTPUT DROP && ip6tables -P FORWARD DROP; then
        log "IPv6 blocked (ip6tables default DROP)"
        return 0
    fi
    if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "1" ]; then
        warn "ip6tables unavailable, but IPv6 is disabled via sysctl — continuing"
        return 0
    fi
    die "cannot block IPv6 (ip6tables failed and IPv6 is enabled) — run with --sysctl net.ipv6.conf.all.disable_ipv6=1"
}

ipt() { iptables "$@" || die "iptables $* failed — kill switch could not be installed"; }

# Kill switch: block ALL egress that does not go through wg0. Installed before
# the tunnel exists and never relaxed, so if wg0 goes down the container goes
# dark — no fallback to the Docker bridge / host network.
setup_firewall() {
    ipt -F OUTPUT
    ipt -P OUTPUT DROP
    # Docker's embedded resolver forwards queries from the host namespace,
    # which would bypass the tunnel — never allow it.
    ipt -A OUTPUT -d "$DOCKER_DNS" -j DROP
    ipt -A OUTPUT -o lo -j ACCEPT
    # Replies to inbound connections (Docker-published SOCKS5 port).
    ipt -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    # WireGuard encapsulation must reach the real server via the original route.
    ipt -A OUTPUT -o "$ORIG_DEV" -p udp -d "$EP_IP" --dport "$EP_PORT" -j ACCEPT
    # DNS inside the tunnel only to the tunnel's DNS server.
    ipt -A OUTPUT -o wg0 -p udp --dport 53 ! -d "$TUN_DNS" -j DROP
    ipt -A OUTPUT -o wg0 -p tcp --dport 53 ! -d "$TUN_DNS" -j DROP
    ipt -A OUTPUT -o wg0 -j ACCEPT

    # SOCKS5 is unauthenticated by default: only the Docker gateway (where
    # published-port traffic arrives from) may connect, not neighbour containers.
    ipt -F INPUT
    ipt -A INPUT -i lo -j ACCEPT
    if [ "$SOCKS_ALLOW_FROM" != "any" ]; then
        local src sources
        if [ "$SOCKS_ALLOW_FROM" = "gateway" ]; then
            sources="$ORIG_GW"
        else
            sources="$SOCKS_ALLOW_FROM"
        fi
        IFS=',' read -ra src_list <<< "$sources"
        for src in "${src_list[@]}"; do
            src="${src//[[:space:]]/}"
            [ -n "$src" ] && ipt -A INPUT -p tcp --dport "$SOCKS_PORT" -s "$src" -j ACCEPT
        done
        ipt -A INPUT -p tcp --dport "$SOCKS_PORT" -j DROP
    fi

    # Pin the WG endpoint through the original gateway so the UDP handshake
    # never loops back through wg0. Survives reconnects (lives on $ORIG_DEV).
    ip route replace "$EP_IP/32" via "$ORIG_GW" dev "$ORIG_DEV" || die "cannot pin endpoint route"

    log "Kill switch active: endpoint ${EP_IP}:${EP_PORT} via ${ORIG_DEV} dns=${TUN_DNS} socks-allow=${SOCKS_ALLOW_FROM}"
}

lock_down_network() {
    save_default_route
    setup_dns
    block_ipv6
    setup_firewall
}

# --- Tunnel ----------------------------------------------------------------------

destroy_tunnel() {
    if [ -n "${WG_GO_PID:-}" ]; then
        kill "$WG_GO_PID" 2>/dev/null || true
        wait "$WG_GO_PID" 2>/dev/null || true
        WG_GO_PID=""
    fi
    ip link del wg0 2>/dev/null || true
}

# Manual tunnel bring-up. wg-quick's sysctl and resolvconf steps fail inside
# Docker (/proc/sys is read-only), so the essential steps are done directly:
# interface, keys, address, MTU, default route. The iptables kill switch keeps
# all egress on wg0. Tries the kernel module first, wireguard-go otherwise.
bring_up_tunnel() {
    local addr
    destroy_tunnel
    if [ "$USE_USERSPACE_WG" -eq 1 ]; then
        log "Starting wireguard-go userspace backend"
        wireguard-go -f wg0 >/var/log/aivpn/wireguard-go.log 2>&1 &
        WG_GO_PID=$!
        for _ in $(seq 1 20); do
            ip link show wg0 >/dev/null 2>&1 && break
            sleep 0.1
        done
        ip link show wg0 >/dev/null 2>&1 || return 1
    else
        ip link add wg0 type wireguard || return 1
    fi
    wg setconf wg0 "$STRIPPED_CONF" || return 1
    for addr in "${TUN_ADDRS[@]}"; do
        ip -4 address add "$addr" dev wg0 || return 1
    done
    ip link set mtu "$TUN_MTU" up dev wg0 || return 1
    ip route replace "$EP_IP/32" via "$ORIG_GW" dev "$ORIG_DEV" || return 1
    ip route replace default dev wg0 || return 1
    return 0
}

ensure_socks5() {
    # !!! MUST run only AFTER wg0 is up !!!
    # Starting it before the tunnel would let early client connections hit a
    # half-configured network. The kill switch blocks leaks either way.
    command -v microsocks >/dev/null 2>&1 || { warn "microsocks not found — SOCKS5 disabled"; return 0; }
    pgrep -x microsocks >/dev/null 2>&1 && return 0
    local auth=() auth_note=""
    if [ -n "$SOCKS_USER" ] || [ -n "$SOCKS_PASS" ]; then
        [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ] || die "set both SOCKS_USER and SOCKS_PASS (or neither)"
        auth=(-u "$SOCKS_USER" -P "$SOCKS_PASS")
        auth_note=" (auth enabled)"
    fi
    log "Starting SOCKS5 proxy on :$SOCKS_PORT$auth_note"
    microsocks -i 0.0.0.0 -p "$SOCKS_PORT" "${auth[@]}" >/var/log/aivpn/microsocks.log 2>&1 &
}

connect_once() {
    rm -f "$TUNNEL_UP_FLAG" 2>/dev/null || true
    log "Connecting using $WG_CONF ..."
    if ! bring_up_tunnel; then
        warn "tunnel bring-up failed — see 'docker logs <name>'"
        destroy_tunnel
        return 1
    fi
    log "Tunnel is UP"
    ensure_socks5
    : > "$TUNNEL_UP_FLAG"
    log "Ready (flag: $TUNNEL_UP_FLAG)"
    return 0
}

# The kill switch is intentionally left in place: the network namespace dies
# with the container, and nothing may leak while it shuts down.
cleanup() {
    log "Shutting down — tearing down tunnel + SOCKS5"
    pkill -x microsocks 2>/dev/null || true
    destroy_tunnel
    rm -f "$TUNNEL_UP_FLAG" 2>/dev/null || true
    exit 0
}

healthcheck() {
    [ -f "$TUNNEL_UP_FLAG" ] || return 1
    wg show wg0 >/dev/null 2>&1 || return 1
    curl -fsS -m 10 "$HEALTHCHECK_URL" >/dev/null 2>&1 || return 1
}

# --- Commands --------------------------------------------------------------------

cmd_daemon() {
    trap cleanup SIGTERM SIGINT SIGHUP
    lock_down_network

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
        # Kill switch stays up: while wg0 is gone nothing can leave the container.
        log "tunnel down — reconnecting in ${backoff}s (kill switch remains active)"
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
    ip link show wg0 >/dev/null 2>&1 && die "wg0 already exists — the daemon is running; use 'status' instead"
    lock_down_network
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

cmd_stop() {
    if [ "$$" -eq 1 ]; then
        cleanup
    fi
    if tr '\0' ' ' < /proc/1/cmdline 2>/dev/null | grep -q 'docker-entrypoint'; then
        log "Signalling the AiVPN daemon (PID 1) to shut down."
        log "Note: with a restart policy Docker starts it again — use 'docker stop <name>' or 'aivpn down' to stop for good."
        kill -TERM 1
        exit 0
    fi
    die "stop must be run inside an AiVPN container (use 'docker stop <name>' from the host)"
}

cmd_safefetch() {
    # Fetch a URL through the tunnel and run a heuristic prompt-injection scan.
    # Exit codes: 0 = clean (or warn mode), 77 = possible PI (block mode),
    #             1 = fetch error, 2 = scanner error (content withheld)
    local url body scan_err scan_rc size
    url="${1:-}"
    case "$url" in
        http://*|https://*) ;;
        *) echo "Usage: safefetch <http(s)-url> [curl-options...]" >&2; return 1 ;;
    esac
    shift

    body=$(mktemp) && scan_err=$(mktemp) || { echo "[aivpn] safefetch: mktemp failed" >&2; return 1; }
    # shellcheck disable=SC2064  # expand the paths now
    trap "rm -f '$body' '$scan_err'" RETURN

    if ! curl -fsSL -m "$SAFEFETCH_TIMEOUT" --max-filesize "$SAFEFETCH_MAX_BYTES" \
            --proto '=http,https' --proto-redir '=http,https' \
            -A "Mozilla/5.0 (compatible; aivpn safefetch)" -o "$body" "$@" "$url"; then
        echo "[aivpn] safefetch: fetch failed (HTTP error, timeout or larger than ${SAFEFETCH_MAX_BYTES} bytes)" >&2
        return 1
    fi
    size=$(wc -c < "$body")
    if [ "$size" -gt "$SAFEFETCH_MAX_BYTES" ]; then
        echo "[aivpn] safefetch: response larger than ${SAFEFETCH_MAX_BYTES} bytes — refused" >&2
        return 1
    fi

    /usr/local/bin/pi-scan.sh < "$body" 2>"$scan_err"
    scan_rc=$?
    case "$scan_rc" in
        0)  cat "$body"; return 0 ;;
        77)
            cat "$scan_err" >&2
            if [ "$SAFEFETCH_MODE" = "warn" ]; then
                echo "[aivpn] safefetch: WARNING — possible prompt injection (heuristic match), content passed through" >&2
                cat "$body"
                return 0
            fi
            echo "[aivpn] safefetch: possible prompt injection (heuristic match) — content blocked" >&2
            return 77
            ;;
        *)
            cat "$scan_err" >&2
            echo "[aivpn] safefetch: scanner error (rc=$scan_rc) — content withheld" >&2
            return 2
            ;;
    esac
}

usage() {
cat <<EOF
AiVPN v${VERSION} — Agent-Grade WireGuard Relay for Proton VPN

Usage: docker run ... aivpn <command> [args]

Commands:
  daemon                 persistent mode with health checks + reconnect (default)
  connect                one-shot connect, print egress IP, exit
  status                 show tunnel + SOCKS5 status
  stop                   ask the daemon to shut down (use 'docker stop' with a restart policy)
  curl <args>            run curl through the tunnel
  safefetch <url>        fetch URL with heuristic PI scan (exit 77 = blocked, 2 = scanner error)
  version                print banner + version
  help                   this text

Environment (docker run -e ...):
  WG_CONF                    WireGuard config path (default /etc/wireguard/wg0.conf)
  TUNNEL_DNS                 override the config's DNS server
  HEALTH_INTERVAL            health check interval seconds (default 60)
  HEALTHCHECK_URL            egress URL for health checks (default https://api.ipify.org)
  SOCKS_PORT                 SOCKS5 port inside container (default 1080)
  SOCKS_ALLOW_FROM           gateway (default) | any | comma-separated IPs/CIDRs
  SOCKS_USER / SOCKS_PASS    optional SOCKS5 auth
  SAFEFETCH_TIMEOUT          curl timeout seconds (default 30)
  SAFEFETCH_MAX_BYTES        max safefetch response size (default 10485760)
  SAFEFETCH_MODE             block (default) | warn
  FORCE_USERSPACE_WG         force userspace WireGuard for testing (default 0)
EOF
}

# --- Dispatch ----------------------------------------------------------------------

# Invoked through the /usr/local/bin/safefetch symlink?
[ "$(basename "$0")" = "safefetch" ] && set -- safefetch "$@"

case "${1:-daemon}" in
    daemon)     banner; preflight; cmd_daemon ;;
    connect)    banner; preflight; cmd_connect ;;
    status)     banner; cmd_status ;;
    stop|down)  cmd_stop ;;
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
