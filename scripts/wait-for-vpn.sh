#!/bin/bash
# ============================================================================
#  AiVPN — wait-for-vpn.sh
# ----------------------------------------------------------------------------
#  Waits until a relay container reports the tunnel is up
#  (/var/run/vpn-up flag), or fails with container logs on timeout.
#
#  Usage:
#    ./scripts/wait-for-vpn.sh <container-name> [timeout-seconds]
#    timeout-seconds defaults to 90
# ============================================================================

set -u

CONTAINER="${1:-}"
[ -n "$CONTAINER" ] || { echo "Usage: $0 <container-name> [timeout-seconds]" >&2; exit 2; }
TIMEOUT="${2:-90}"

wait_loop=0
while [ "$wait_loop" -lt "$TIMEOUT" ]; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        echo "[wait-for-vpn] container $CONTAINER is not running" >&2
        docker logs "$CONTAINER" 2>&1 | tail -n 40 >&2
        exit 1
    fi
    if docker exec "$CONTAINER" test -e /var/run/vpn-up 2>/dev/null; then
        echo "[wait-for-vpn] $CONTAINER tunnel is UP"
        exit 0
    fi
    sleep 1
    wait_loop=$((wait_loop + 1))
done

echo "[wait-for-vpn] timeout (${TIMEOUT}s) waiting for tunnel — container logs:" >&2
docker logs "$CONTAINER" 2>&1 | tail -n 40 >&2
exit 1
