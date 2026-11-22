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

set -u

# Container path first, repo path as fallback (for local testing).
PATTERNS="${PI_PATTERNS:-/usr/local/share/aivpn/pi-patterns.txt}"
[ -r "$PATTERNS" ] || PATTERNS="$(cd "$(dirname "$0")/.." && pwd)/data/pi-patterns.txt"
[ -r "$PATTERNS" ] || { echo "[pi-scan] pattern file missing or unreadable — refusing to pass content" >&2; exit 2; }

pat_file=$(mktemp) && text_file=$(mktemp) || { echo "[pi-scan] mktemp failed" >&2; exit 2; }
trap 'rm -f "$pat_file" "$text_file"' EXIT

# Patterns: drop CRs (Windows checkouts), comments and blank lines.
sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$PATTERNS" > "$pat_file" \
    || { echo "[pi-scan] cannot read patterns" >&2; exit 2; }
[ -s "$pat_file" ] || exit 0

# Normalise stdin into two lines: raw text and tag-stripped text.
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
function decode(s,    out, ent, n) {
    out = ""
    while (match(s, /&#[xX]?[0-9a-fA-F]+;/)) {
        ent = substr(s, RSTART, RLENGTH)
        out = out substr(s, 1, RSTART - 1)
        s = substr(s, RSTART + RLENGTH)
        if (ent ~ /^&#[xX]/) n = hexval(substr(ent, 4, length(ent) - 4))
        else if (ent ~ /^&#[0-9]+;$/) n = substr(ent, 3, length(ent) - 3) + 0
        else n = -1
        out = out ((n >= 32 && n < 127) ? sprintf("%c", n) : " ")
    }
    s = out s
    gsub(/&nbsp;/, " ", s); gsub(/&quot;/, "\"", s); gsub(/&apos;/, "'"'"'", s)
    gsub(/&lt;/, "<", s);   gsub(/&gt;/, ">", s);    gsub(/&amp;/, "\\&", s)
    return s
}
BEGIN {
    # UTF-8 zero-width space/non-joiner/joiner, LRM/RLM, word joiner, BOM
    zw[1] = sprintf("%c%c%c", 226, 128, 139); zw[2] = sprintf("%c%c%c", 226, 128, 140)
    zw[3] = sprintf("%c%c%c", 226, 128, 141); zw[4] = sprintf("%c%c%c", 226, 128, 142)
    zw[5] = sprintf("%c%c%c", 226, 128, 143); zw[6] = sprintf("%c%c%c", 226, 129, 160)
    zw[7] = sprintf("%c%c%c", 239, 187, 191)
}
{ buf = buf " " $0 }
END {
    for (i = 1; i <= 7; i++) gsub(zw[i], "", buf)
    raw = decode(buf)
    gsub(/[[:space:]]+/, " ", raw)
    stripped = buf
    gsub(/<[^>]*>/, " ", stripped)
    stripped = decode(stripped)
    gsub(/[[:space:]]+/, " ", stripped)
    print raw
    print stripped
}' > "$text_file" || { echo "[pi-scan] normalisation failed" >&2; exit 2; }

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
