#!/bin/bash
# ============================================================================
#  AiVPN — pi-scan.sh
# ----------------------------------------------------------------------------
#  Heuristic prompt-injection scanner used by `safefetch`.
#  Reads content on stdin and checks it against regex patterns.
#
#  This is a tripwire, not a guarantee: it catches common, literal injection
#  phrasing. Paraphrased, translated or encoded attacks will get through.
#  Treat fetched content as untrusted even when the scan is clean.
#
#  Before matching, the content is normalised so trivial tricks do not work:
#    - line breaks, tabs and repeated whitespace collapse to single spaces
#    - numeric (&#99; &#x63;) and basic named HTML entities are decoded
#    - zero-width characters and BOMs are removed
#    - a second, tag-stripped copy is scanned too (catches "ignore <b>all</b> ...")
#
#  Exit codes:
#    0   clean (or the pattern file is intentionally empty)
#    77  possible prompt injection
#    2   scanner error (pattern file missing/unreadable) — fail-closed
# ============================================================================

set -u -o pipefail

# Container path first, repo path as fallback (for local testing).
PATTERNS="${PI_PATTERNS:-/usr/local/share/aivpn/pi-patterns.txt}"
[ -r "$PATTERNS" ] || PATTERNS="$(cd "$(dirname "$0")/.." && pwd)/data/pi-patterns.txt"
[ -r "$PATTERNS" ] || { echo "[pi-scan] pattern file missing or unreadable — refusing to pass content" >&2; exit 2; }

pat_file=$(mktemp) && in_file=$(mktemp) && text_file=$(mktemp) || { echo "[pi-scan] mktemp failed" >&2; exit 2; }
trap 'rm -f "$pat_file" "$in_file" "$text_file"' EXIT

# Patterns: drop CRs (Windows checkouts), comments and blank lines.
sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$PATTERNS" > "$pat_file" \
    || { echo "[pi-scan] cannot read patterns" >&2; exit 2; }
[ -s "$pat_file" ] || exit 0

# Decode HTML entities and drop zero-width characters. One linear pass:
# pages can be megabytes of a single minified line.
decode_entities() {
    LC_ALL=C awk '
    function hexval(h,    i, c, v) {
        v = 0; h = tolower(h)
        for (i = 1; i <= length(h); i++) {
            c = index("0123456789abcdef", substr(h, i, 1))
            if (c == 0) return -1
            v = v * 16 + c - 1
        }
        return v
    }
    function chr(c) { return (c >= 32 && c < 127) ? sprintf("%c", c) : " " }
    BEGIN {
        # UTF-8 zero-width space/non-joiner/joiner, LRM/RLM, word joiner, BOM
        zw[1] = sprintf("%c%c%c", 226, 128, 139); zw[2] = sprintf("%c%c%c", 226, 128, 140)
        zw[3] = sprintf("%c%c%c", 226, 128, 141); zw[4] = sprintf("%c%c%c", 226, 128, 142)
        zw[5] = sprintf("%c%c%c", 226, 128, 143); zw[6] = sprintf("%c%c%c", 226, 129, 160)
        zw[7] = sprintf("%c%c%c", 239, 187, 191)
        named["nbsp"] = " "; named["quot"] = "\""; named["apos"] = "\047"
        named["lt"] = "<";   named["gt"] = ">";    named["amp"] = "&"
    }
    {
        s = $0
        for (i = 1; i <= 7; i++) gsub(zw[i], "", s)
        n = split(s, part, "&")
        printf "%s", part[1]
        for (i = 2; i <= n; i++) {
            x = part[i]
            if (match(x, /^#[0-9]+;/))
                printf "%s%s", chr(substr(x, 2, RLENGTH - 2) + 0), substr(x, RLENGTH + 1)
            else if (match(x, /^#[xX][0-9a-fA-F]+;/))
                printf "%s%s", chr(hexval(substr(x, 3, RLENGTH - 3))), substr(x, RLENGTH + 1)
            else if (match(x, /^[a-z]+;/) && (substr(x, 1, RLENGTH - 1) in named))
                printf "%s%s", named[substr(x, 1, RLENGTH - 1)], substr(x, RLENGTH + 1)
            else
                printf "&%s", x
        }
        printf "\n"
    }'
}

# Normalise stdin into two lines — raw text and tag-stripped text — with
# whitespace collapsed to single spaces.
LC_ALL=C tr '\r\n\t\f\v' '     ' > "$in_file" || { echo "[pi-scan] cannot read input" >&2; exit 2; }
{
    decode_entities < "$in_file"
    LC_ALL=C sed 's/<[^>]*>/ /g' "$in_file" | decode_entities
} | LC_ALL=C tr -s ' ' > "$text_file" || { echo "[pi-scan] normalisation failed" >&2; exit 2; }

LC_ALL=C grep -Eiq -f "$pat_file" "$text_file"
rc=$?
case "$rc" in
    0)
        match=$(LC_ALL=C grep -Eio -f "$pat_file" "$text_file" | head -1)
        echo "[pi-scan] possible prompt injection: '${match:0:80}'" >&2
        exit 77
        ;;
    1) exit 0 ;;
    *) echo "[pi-scan] grep failed (rc=$rc) — invalid pattern?" >&2; exit 2 ;;
esac
