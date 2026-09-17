#!/usr/bin/env bash
#
# /usr/local/sbin/update-afd-set
#
# Populate the nftables sets inet filter/afd4 and afd6 with the current
# AzureFrontDoor.Backend prefixes, using the public ServiceTags JSON.
# No Azure credentials required.
#
# Dependencies: curl, python3 (both present on a stock Ubuntu server).
#
# Exit codes:
#   0  sets are current (updated, or already up to date)
#   1  something went wrong -- existing set contents left untouched
#
set -euo pipefail

TAG="${AFD_TAG:-AzureFrontDoor.Backend}"
PAGE="${AFD_PAGE:-https://www.microsoft.com/en-us/download/details.aspx?id=56519}"
STATE="${AFD_STATE:-/var/lib/afd-ranges}"
TABLE="${AFD_TABLE:-inet filter}"
MIN_PREFIXES="${AFD_MIN_PREFIXES:-50}"
UA='Mozilla/5.0 (X11; Linux x86_64)'

log() { printf '%s\n' "$*" >&2; }
die() { log "update-afd-set: $*"; exit 1; }

command -v nft >/dev/null     || die "nft not found"
command -v python3 >/dev/null || die "python3 not found"

# The sets must already exist (they come from /etc/nftables.conf). Creating
# them here would silently paper over an unloaded ruleset.
nft list set $TABLE afd4 >/dev/null 2>&1 \
    || die "set '$TABLE afd4' does not exist -- is /etc/nftables.conf loaded?"

mkdir -p "$STATE"

# --------------------------------------------------------------------------
# 1. Locate this week's dated JSON file on the download page.
#
# The URL is embedded in the page as escaped JSON (https:\/\/...), hence the
# backslash strip. If several dated files appear, take the newest by filename.
# --------------------------------------------------------------------------
page=$(curl -fsSL --retry 3 --retry-delay 5 --max-time 60 -A "$UA" "$PAGE") \
    || die "could not fetch download page"

url=$(printf '%s' "$page" | tr -d '\\' \
    | grep -oE "https://download\.microsoft\.com/download/[^\"' <>]+/ServiceTags_Public_[0-9]{8}\.json" \
    | sort -u \
    | awk -F/ '{print $NF"\t"$0}' | sort -k1,1 | tail -n1 | cut -f2-) || true

[[ -n "${url:-}" ]] \
    || die "no ServiceTags_Public URL found on the page (layout may have changed)"

file="$STATE/$(basename "$url")"

# --------------------------------------------------------------------------
# 2. Download, unless we already hold this week's file.
#    Validate before moving into place, so a captive portal or truncated
#    transfer can never replace the last known-good copy.
# --------------------------------------------------------------------------
if [[ ! -s "$file" ]]; then
    log "downloading $(basename "$url")"
    curl -fsSL --retry 3 --retry-delay 5 --max-time 300 -A "$UA" \
        -o "$file.part" "$url" || die "download failed"

    python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
if not doc.get("values"):
    sys.exit(1)
' "$file.part" 2>/dev/null || { rm -f "$file.part"; die "downloaded file is not valid service-tag JSON"; }

    mv "$file.part" "$file"
fi

# --------------------------------------------------------------------------
# 3. Extract changeNumber + prefixes for the tag.
#    First output line is the changeNumber, the rest are prefixes.
# --------------------------------------------------------------------------
out=$(python3 -c '
import json, sys
path, tag = sys.argv[1], sys.argv[2]
with open(path) as f:
    doc = json.load(f)
for v in doc.get("values", []):
    if v.get("name") == tag:
        p = v.get("properties", {})
        print(p.get("changeNumber", "0"))
        for prefix in p.get("addressPrefixes", []):
            print(prefix)
        sys.exit(0)
sys.exit(3)
' "$file" "$TAG") || die "tag '$TAG' not present in $(basename "$file")"

mapfile -t lines <<<"$out"
change="${lines[0]}"
prefixes=("${lines[@]:1}")

# --------------------------------------------------------------------------
# 4. Sanity gate.
#
# Every failure mode above degrades to "empty list", and an empty set means
# the site goes dark. Refuse to apply an implausibly short list instead.
# --------------------------------------------------------------------------
(( ${#prefixes[@]} >= MIN_PREFIXES )) \
    || die "only ${#prefixes[@]} prefixes for $TAG (expected >= $MIN_PREFIXES) -- refusing to apply"

# --------------------------------------------------------------------------
# 5. Skip the reload when nothing has changed and the set is already loaded.
# --------------------------------------------------------------------------
loaded=$(nft -j list set $TABLE afd4 2>/dev/null | grep -c 'prefix\|"elem"' || true)
if [[ -f "$STATE/changeNumber" && "$change" == "$(cat "$STATE/changeNumber")" && "$loaded" -gt 0 ]]; then
    log "unchanged (changeNumber $change, ${#prefixes[@]} prefixes) -- nothing to do"
    exit 0
fi

v4=$(printf '%s\n' "${prefixes[@]}" | { grep -v ':' || true; } | paste -sd, -)
v6=$(printf '%s\n' "${prefixes[@]}" | { grep    ':' || true; } | paste -sd, -)

[[ -n "$v4" ]] || die "no IPv4 prefixes parsed -- refusing to apply"

# --------------------------------------------------------------------------
# 6. Apply. Flush + add per family; rules referencing the sets are untouched.
# --------------------------------------------------------------------------
nft flush set $TABLE afd4
nft add element $TABLE afd4 "{ $v4 }"

nft flush set $TABLE afd6
if [[ -n "$v6" ]]; then
    nft add element $TABLE afd6 "{ $v6 }"
fi

printf '%s\n' "$change" > "$STATE/changeNumber"

log "applied ${#prefixes[@]} prefixes for $TAG (changeNumber $change) from $(basename "$file")"
