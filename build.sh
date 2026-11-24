#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# build.sh -- one-command build of the CDJ-2000NXS2 "CDJ-3000 UI" firmware update, both profiles.
#
#   ./build.sh /path/to/official/C2KNXS2.UPD [options]               -> the RELEASE build (= R23R1r)
#   PROFILE=dev ./build.sh /path/to/official/C2KNXS2.UPD [options]   -> the DEV build for contributors (dev/README.md)
#
# Input : YOUR OWN copy of the official CDJ-2000NXS2 update 1.87 (MAIN 1.87 / GUI 1.81), unchanged (sha256 checked).
# Output: <out>/C2KNXS2.UPD (+ verify.txt, bootcheck.txt, build.log); sha256 printed and compared with the reference.
#
#   --font-ttf PATH         the UI font. Default: mods/v2ui/fonts/CuelineSans/ (Cueline Sans).
#   --fallback-ttf PATH     the font for the glyphs the UI font lacks. Default: fonts/RobotoCondensed.ttf.
#   --no-keyshift           build without KEY SHIFT / KEY SYNC (no reference sha for this variant).
#   --out DIR               output directory (default ./out-<profile>).
#
# Nothing in this bundle comes from Pioneer/AlphaTheta: the firmware is always your copy and everything derived from
# it is regenerated from that copy at build time.
# The GUI icons are ours (shipped sources) plus stock NXS2 icons taken from YOUR .UPD at build time.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
STOCK_UPD_SHA=f211191a573b7a5c0e694936871f76011a58d5861dd061301cdb0d8b83a8b3e5   # official C2KNXS2.UPD 1.87
FONT_DEFAULT=mods/v2ui/fonts/CuelineSans/
FONT_SHA=none
ROBOTO_SHA=a9603db0f52e244064de480253ab7f48e6c21c22e24528207cab06d39abc7bb7
REF_TOOLS="sh4-linux-gnu-gcc 13.3.0 / binutils 2.42 (Ubuntu 24.04), Python 3.12, Pillow 12.1.1, numpy, fontTools 4.61.1"

# ---- the two reference builds (same sources, same toolchain) ---------------------------------------------------
# release = R23R1r  (labels MAIN 2.20 / GUI 2.14 = bump 33)
REL_TAG=R23R1r;  REL_BUMP=33; REL_ID="Cueline-2.3 20261123-2329 2cd1c93f"
REL_SHA=85905736d2f042e3be62c363180c60a5107d97032fa854369c28315074ca0b6e
DEV_TAG=R23R1n; DEV_BUMP=33; DEV_ID="R23R1n 20261123-2331 2cd1c93f"
DEV_SHA=31aabb3ce3124f2516094cbcd35b17428225be4fa5de1a4fbf42e4deb56dd6fd

# the recipe (both profiles share every feature; dev adds the tooling: see the README / DEV_TOOLS.md)
FEAT_MODS="touchaudio touchaudioip touchaudiotouch tadec modsmenu wav32 rowwave three_band ui3000x bootname
           font3000 v2ui v2needle lang7 usbkey"
# the mods after keyshift, in the reference builds' order (bbox = BLACK BOX: dev tooling)
REL_EXTRA="reclaim guitrim_cjk w8send w8cap w8recv ks3k ownks jogcue link0brx link0btx"
DEV_EXTRA="reclaim guitrim_cjk w8send w8cap w8recv ks3k bbox ownks jogcue link0brx link0btx"
V2_FEAT="-DV2_DMACPY -DV2_VSPACE -DV2_BDIRECT -DV2_AUTO60 -DV2_HWBAND -DV2_MSUB -DV2_G3PURGE -DV2_GR1METER -DV2_SC0BYP -DV2_LANG7"   # + KS_V2; LANG7 = the 7 Latin-1 UI languages; GR1METER + SC0BYP = LINK WAVEFORM meter on its own GR1 hardware layer
P56=proven
# KEY SHIFT / KEY SYNC engine of this package: our own engine
KS_ENGINE=own
KS_MODS="keyshift"            # replace 'keyshift' in the mod list (KEY SHIFT engine + front end)
KS_EXTRA="ks3k"                # KEY SYNC with CDJ-3000 masters
KS_ONLY="ks3k ownks"           # dropped with keyshift (--no-keyshift)
KS_V2="-DV2_KEYSHIFT"
KS_TADEC="0x08018000:256"          # tadec base:arena(KB) in the keyshift layout
NOKS_TADEC="0x08140000:256"    # ... and in the stock layout (no keyshift)

die() { echo "build.sh: ERROR: $*" >&2; exit 1; }
warn() { echo "build.sh: WARNING: $*" >&2; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

PROFILE=${PROFILE:-release}
UPD=""; RX3=""; FALLBACK=""; FONT=""; OUT=""; NOKS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE=$2; shift 2;;
    --font-ttf) FONT=$2; shift 2;;
    --fallback-ttf) FALLBACK=$2; shift 2;;
    --no-keyshift) NOKS=1; shift;;
    --out) OUT=$2; shift 2;;
    -h|--help) sed -n '3,30p' "$0"; exit 0;;
    -*) die "unknown option $1";;
    *) [ -z "$UPD" ] || die "one input .UPD only"; UPD=$1; shift;;
  esac
done
[ -n "$UPD" ] || { [ -f "$PWD/C2KNXS2.UPD" ] && UPD=$PWD/C2KNXS2.UPD; }
[ -n "$UPD" ] || die "usage: ./build.sh /path/to/C2KNXS2.UPD [--font-ttf PATH]   (or put C2KNXS2.UPD in this folder)"
[ "$KS_ENGINE" = none ] && NOKS=1
case "$PROFILE" in
  release) TAG=$REL_TAG; BUMP=$REL_BUMP; REF_ID=$REL_ID; REF_SHA=$REL_SHA
           V2_CFLAGS="$V2_FEAT"; PRE_KS="$FEAT_MODS";;
  dev)     TAG=$DEV_TAG; BUMP=$DEV_BUMP; REF_ID=$DEV_ID; REF_SHA=$DEV_SHA     # (repository: the dev/ components)
           V2_CFLAGS="-DV2_HUD $V2_FEAT -DV2_USBLOG"; PRE_KS="$FEAT_MODS autotest usblog";;
  *) die "PROFILE=$PROFILE: use release or dev";;
esac
EXTRA=$REL_EXTRA; [ $PROFILE = dev ] && EXTRA=$DEV_EXTRA
if [ $NOKS = 1 ]; then
  MODS="$PRE_KS"; for m in $EXTRA; do case " $KS_ONLY " in *" $m "*) ;; *) MODS="$MODS $m";; esac; done; TADEC=$NOKS_TADEC
else
  # same order as the reference builds: ... keyshift reclaim guitrim_cjk w8send w8cap w8recv ks3k bbox
  MODS="$PRE_KS $KS_MODS $EXTRA"; TADEC=$KS_TADEC
  case "$PROFILE" in dev) V2_CFLAGS="-DV2_HUD $V2_FEAT $KS_V2 -DV2_USBLOG";; release) V2_CFLAGS="$V2_FEAT $KS_V2";; esac
fi
MODS=$(echo $MODS)
FLAGS="--bump-gui --main-bump=$BUMP --gui-bump=$BUMP --no-main-size-check"
[ -n "$OUT" ] || OUT="$PWD/out-$PROFILE"

# ---- 1. prerequisites -------------------------------------------------------------------------------------------
[ -f "$UPD" ] || die "no such file: $UPD"
UPD=$(cd "$(dirname "$UPD")" && pwd)/$(basename "$UPD")
got=$(sha "$UPD")
[ "$got" = "$STOCK_UPD_SHA" ] || die "$UPD is not the official C2KNXS2.UPD 1.87
  expected sha256 $STOCK_UPD_SHA
  got             $got
  (use the unmodified file from alphatheta.com; MAIN 1.87 / GUI 1.81)"
echo "build.sh: profile $PROFILE ($TAG), keyshift $([ $NOKS = 1 ] && echo none || echo $KS_ENGINE), input OK  $UPD  sha256 $got"

for t in sh4-linux-gnu-gcc sh4-linux-gnu-as sh4-linux-gnu-ld sh4-linux-gnu-objcopy sh4-linux-gnu-nm sh4-linux-gnu-readelf python3 sha256sum; do
  command -v $t >/dev/null || die "missing tool '$t'. SH toolchain: Debian/Ubuntu 'apt install gcc-sh4-linux-gnu binutils-sh4-linux-gnu'"
done
python3 - <<'EOF' || die "missing Python modules: pip install pillow numpy fonttools  (Python >= 3.8)"
import sys
assert sys.version_info >= (3, 8)
import PIL, numpy  # noqa
from fontTools.ttLib import TTFont  # noqa
from PIL import ImageFont
ImageFont.truetype  # FreeType support
EOF
TOOLS="$(sh4-linux-gnu-gcc --version | head -1) | $(sh4-linux-gnu-as --version | head -1) | $(python3 --version) | Pillow $(python3 -c 'import PIL;print(PIL.__version__)') | fontTools $(python3 -c 'import fontTools;print(fontTools.version)')"

FONT_OK=1
# default: our own UI font, built from the sources (mods/v2ui/fonts/CuelineSans/, SIL OFL 1.1); --font-ttf = an override
if [ -z "$FONT" ]; then FONT_MODE=tree; else FONT_MODE=file; fi
if [ $FONT_MODE = file ]; then
  [ -f "$FONT" ] || die "UI font not found ($FONT): pass --font-ttf PATH"
  FONT=$(cd "$(dirname "$FONT")" && pwd)/$(basename "$FONT")
  [ "$(sha "$FONT")" = "$FONT_SHA" ] || { warn "$FONT is not the reference UI font: the output sha will differ"; FONT_OK=0; }
fi
[ -n "$FALLBACK" ] || FALLBACK=$HERE/fonts/RobotoCondensed.ttf
[ -f "$FALLBACK" ] || die "Roboto Condensed TTF not found ($FALLBACK): pass --fallback-ttf PATH or put it in fonts/"
FALLBACK=$(cd "$(dirname "$FALLBACK")" && pwd)/$(basename "$FALLBACK")
[ "$(sha "$FALLBACK")" = "$ROBOTO_SHA" ] || warn "$FALLBACK is not the reference Roboto Condensed file: the output sha will differ"



# sources as shipped? (MANIFEST.txt lists every mods/ and scripts/ file) -> the reference build ID; else a local one
SRC_OK=1
if [ -f "$HERE/MANIFEST.txt" ]; then
  ( cd "$HERE" && grep -E '  \./(mods|scripts)/' MANIFEST.txt | grep -v -E '/v2ui_atlas\.[ch]$' | sha256sum -c --quiet >/dev/null 2>&1 ) || SRC_OK=0
else
  SRC_OK=0
fi
REF_VARIANT=1
{ [ "$REF_SHA" = none ] || [ -z "$REF_ID" ]; } && REF_VARIANT=0      # no published reference for this variant
[ $NOKS = 1 ] && [ "$KS_ENGINE" != none ] && REF_VARIANT=0      # --no-keyshift on a package whose reference has it
if [ $SRC_OK = 1 ] && [ $REF_VARIANT = 1 ]; then
  BUILD_ID=$REF_ID
else
  SUF=m; [ $SRC_OK = 1 ] && SUF=x
  BUILD_ID="${TAG}${SUF} $(date +%Y%m%d-%H%M) $(cd "$HERE/mods" && python3 -c 'import patch_main; print(patch_main.source_hash())')"
  [ $SRC_OK = 1 ] || warn "the sources differ from MANIFEST.txt: local build ID '$BUILD_ID' (the output cannot match the reference)"
  [ $REF_VARIANT = 1 ] || warn "--no-keyshift: a variant of the reference, build ID '$BUILD_ID' (no reference sha)"
fi
echo "build.sh: prerequisites OK ($TOOLS)"

# ---- 2. build in a scratch copy (the bundle stays clean) ---------------------------------------------------------
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
W=$OUT/work; rm -rf "$W"; mkdir -p "$W"
cp -a "$HERE/mods" "$HERE/scripts" "$W/"
# the developer components (dev/mods: autotest, usblog, bbox, the TchAud test variant) are copied in for BOTH
# profiles: every routine of the patcher's table has a slot, so the release needs their sources too (not named)
[ -d "$HERE/dev/mods" ] || die "the dev/ folder of the repository is missing (its mods are needed by every build)"
cp -a "$HERE/dev/mods/." "$W/mods/"
L=$OUT/build.log; : > "$L"
step() { echo "build.sh: $1"; echo "=== $1" >> "$L"; }


TB=${TADEC%%:*}; TA=${TADEC##*:}
step "tadec decoder blob (MAIN $TB, $TA KB arena)"
( cd "$W/mods/tadec" && BASE=$TB ARENA_KB=$TA OPT=O2 sh build.sh ) >> "$L" 2>&1
step "players 5/6 cave (call-site tables generated from YOUR stock MAIN; never shipped)"
( cd "$W" && python3 scripts/firmware/main_decode.py "$UPD" "$W/stock_main.bin" ) >> "$L" 2>&1
( cd "$W/mods/player56" && STOCK_MAIN="$W/stock_main.bin" sh build.sh ) >> "$L" 2>&1 || { tail -5 "$L"; die "player56 build failed (see $L)"; }

export CDJ_PROFILE=$PROFILE CDJ_BUILD_ID="$BUILD_ID" V2_CFLAGS CDJ_STOCK_UPD="$UPD"
# Cueline 2.3: KEY SHIFT works through the original firmware's MASTER TEMPO engine (mods/ownks/dsp/ks4mt.c).
export CDJ_KS4MT=1
export CDJ_V2_FONTTRIM=1
if [ $FONT_MODE = tree ]; then unset CDJ_V2_TTF CDJ_FONT3000_TTF CDJ_FONT3000_FALLBACK
else export CDJ_V2_TTF="$FONT" CDJ_FONT3000_TTF="$FONT" CDJ_FONT3000_FALLBACK="$FALLBACK"; fi
unset CDJ_V3E2 CDJ_TESTLOG CDJ_BBOX CDJ_UT_DIAG CDJ_LCDRV V3E_NO_RTGO V2_EARLY V2_RO V2_BASE
step "assemble GUI mods";  ( cd "$W" && python3 mods/patch_gui.py --assemble ) >> "$L" 2>&1 || true
step "assemble MAIN mods"; ( cd "$W" && python3 mods/patch_main.py --assemble ) >> "$L" 2>&1 || true
step "v2ui renderer";      ( cd "$W/mods/v2ui" && sh build.sh ) >> "$L" 2>&1 || { tail -5 "$L"; die "v2ui build failed (see $L)"; }
grep -q -i 'image''data' "$L" && die "the build asked for the XDJ-RX3 sprite file: this package must not need it (see $L)"
step "patch the update ($MODS)"
( cd "$W" && python3 mods/player56/build_upd.py "$UPD" "$OUT/C2KNXS2.UPD" $MODS $FLAGS --p56=$P56 ) >> "$L" 2>&1 \
  || { tail -5 "$L"; die "patching failed (see $L)"; }
step "verify + GUI boot check"
( cd "$W" && python3 scripts/firmware/verify_update.py "$UPD" "$OUT/C2KNXS2.UPD" $MODS $FLAGS --p56=$P56 ) > "$OUT/verify.txt" 2>&1 || true
( cd "$W" && python3 scripts/firmware/gui_bootcheck.py --strict "$OUT/C2KNXS2.UPD" ) > "$OUT/bootcheck.txt" 2>&1 || true
rm -rf "$W"

# ---- 3. result ---------------------------------------------------------------------------------------------------
OSHA=$(sha "$OUT/C2KNXS2.UPD")
RC=0
echo
echo "build.sh: wrote $OUT/C2KNXS2.UPD  [profile $PROFILE, build ID \"$BUILD_ID\"]"
echo "  sha256    $OSHA"
echo "  verify    $(tail -1 "$OUT/verify.txt")"
echo "  bootcheck $(head -1 "$OUT/bootcheck.txt")"
grep -q 'all checks passed' "$OUT/verify.txt" || { echo "  !! verify FAILED: do not install"; RC=1; }
grep -q '^PASS' "$OUT/bootcheck.txt" || { echo "  !! GUI boot check FAILED: do not install"; RC=1; }
if [ $REF_VARIANT = 0 ]; then
  echo "  (--no-keyshift variant: no reference sha256 to compare with)"
elif [ "$OSHA" = "$REF_SHA" ]; then
  echo "  == $TAG reference build, byte-identical (sha256 $REF_SHA)"
else
  echo "  != the $TAG reference ($REF_SHA): expected only if a font/atlas/source warning was printed above or the"
  echo "     toolchain differs from the reference ($REF_TOOLS)"
  [ $RC = 1 ] || RC=2
fi
echo "  Install: C2KNXS2.UPD alone in the root of a small FAT32 stick (README.md > Install)."
echo "  Flashing a modified update is at your own risk (README.md > Safety)."
exit $RC
