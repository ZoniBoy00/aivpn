#!/bin/bash
# ============================================================================
#  AiVPN — pi-scan.sh
# ----------------------------------------------------------------------------
#  Lightweight prompt-injection scanner used by `safefetch`.
#  Reads content on stdin, checks against heuristic regex patterns.
#
#  Exit codes:
#    0   clean
#    77  prompt injection detected (content suppressed)
#
#  Fail-open: if the pattern file is missing or unreadable, content passes.
# ============================================================================

set -u

# Container path first, repo path as fallback (for local testing).
PATTERNS="${PI_PATTERNS:-/usr/local/share/aivpn/pi-patterns.txt}"
[ -r "$PATTERNS" ] || PATTERNS="$(cd "$(dirname "$0")/.." && pwd)/data/pi-patterns.txt"

[ -r "$PATTERNS" ] || { echo "[pi-scan] pattern file missing — fail-open" >&2; exit 0; }

# Read all stdin
content=$(cat)

while IFS= read -r pattern || [ -n "$pattern" ]; do
    # Skip comments and empty lines
    case "$pattern" in
        ''|\#*) continue ;;
    esac
    if printf '%s' "$content" | grep -Eiq "$pattern"; then
        echo "[pi-scan] blocked: matched pattern '${pattern:0:60}...'" >&2
        exit 77
    fi
done < "$PATTERNS"

exit 0
