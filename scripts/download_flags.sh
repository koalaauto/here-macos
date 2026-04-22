#!/usr/bin/env bash
# Download rectangular country-flag PNGs into Assets.xcassets/Flags/.
# Each ISO 3166-1 alpha-2 code gets its own imageset and a PNG named flag_XX.png.
#
# Source: https://flagcdn.com — serves rectangular (not waving) flat PNG flags
# using a lowercased 2-letter country code. Free for public use.
# Re-runnable: existing PNGs are skipped unless --force is passed.

set -euo pipefail

cd "$(dirname "$0")/.."

FLAGS_DIR="Here/Resources/Assets.xcassets/Flags"
# Width of 1× image. Retina displays will upscale; 160px wide keeps file <~1.5KB
# while still looking sharp at 15-22pt status bar heights.
WIDTH="w160"
BASE_URL="https://flagcdn.com/${WIDTH}"
FORCE="${1:-}"

mkdir -p "$FLAGS_DIR"

cat > "$FLAGS_DIR/Contents.json" <<'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

CODES=(
AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ
BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ
CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ
DE DJ DK DM DO DZ
EC EE EG EH ER ES ET
FI FJ FK FM FO FR
GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY
HK HM HN HR HT HU
ID IE IL IM IN IO IQ IR IS IT
JE JM JO JP
KE KG KH KI KM KN KP KR KW KY KZ
LA LB LC LI LK LR LS LT LU LV LY
MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ
NA NC NE NF NG NI NL NO NP NR NU NZ
OM
PA PE PF PG PH PK PL PM PN PR PS PT PW PY
QA
RE RO RS RU RW
SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ
TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ
UA UG UM US UY UZ
VA VC VE VG VI VN VU
WF WS
YE YT
ZA ZM ZW
EU UN XK
)

downloaded=0
skipped=0
failed=0

for code in "${CODES[@]}"; do
    lower=$(echo "$code" | tr 'A-Z' 'a-z')
    imageset="$FLAGS_DIR/flag_${code}.imageset"
    target_png="${imageset}/flag_${code}.png"

    mkdir -p "$imageset"

    # `template-rendering-intent: original` pins each imageset to full-color
    # rendering. Without it, Xcode's automatic detection can in some cases
    # interpret a flag as a template image, which would collapse the flag
    # to a tinted silhouette based on the alpha channel — hiding visible
    # features (e.g. Taiwan's blue canton + sun) and making two unrelated
    # flags look near-identical in the menu bar.
    cat > "$imageset/Contents.json" <<EOF
{
  "images" : [
    {
      "filename" : "flag_${code}.png",
      "idiom" : "universal",
      "scale" : "1x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "original"
  }
}
EOF

    if [[ -f "$target_png" && "$FORCE" != "--force" ]]; then
        skipped=$((skipped + 1))
        continue
    fi

    if curl -sSL --fail --max-time 20 -o "$target_png" "${BASE_URL}/${lower}.png"; then
        downloaded=$((downloaded + 1))
    else
        failed=$((failed + 1))
        rm -f "$target_png"
        echo "warn: failed to fetch $code" >&2
    fi
done

echo "Flags ready: downloaded=$downloaded skipped=$skipped failed=$failed total_codes=${#CODES[@]}"
