#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# testreport.sh TAG OUTDIR [RUNS_DIR] : one test report per build -> OUTDIR/TESTREPORT_<TAG>.txt
#   OUTDIR   a build.sh output directory (C2KNXS2.UPD, verify.txt, bootcheck.txt, build.log)
#   RUNS_DIR the rig runs directory (tools/rig `--out` parents, default ./runs): the latest net4_dd /
#            ksync_rig2 / ksync_mtap / lc_linkcue / solo3 report.txt summaries, a run named with this build's
#            prefix (V4n38 -> v38_, V4r2 -> r2_) preferred.
# Env: BUILDS=path/to/BUILDS.tsv (build ID <TAB> tag <TAB> UPD sha256 <TAB> written <TAB> path), optional.
set -u
T=${1:?usage: testreport.sh TAG OUTDIR [RUNS_DIR]}
O=${2:?usage: testreport.sh TAG OUTDIR [RUNS_DIR]}
RUNS=${3:-runs}
R=$O/TESTREPORT_$T.txt
UPD=$O/C2KNXS2.UPD
VP=$(echo "$T" | sed -n -e 's/^V4n\([0-9][0-9]*\).*/v\1_/p' -e 's/^V4r\([0-9][0-9]*\).*/r\1_/p')
{
echo "TEST REPORT $T   ($(date '+%Y-%m-%d %H:%M:%S'))"
echo "================================================================================"
echo "## build"
if [ -f "$UPD" ]; then
  echo "UPD      $UPD  $(stat -c %s "$UPD") bytes  sha256 $(sha256sum "$UPD" | cut -d' ' -f1)"
else
  echo "UPD      MISSING ($UPD)"
fi
if [ -n "${BUILDS:-}" ] && [ -f "$BUILDS" ]; then
  B=$(awk -F'\t' -v t="$T" '$2 == t' "$BUILDS" | tail -1)
  [ -n "$B" ] && echo "build ID $(echo "$B" | cut -f1)   (BUILDS.tsv: UPD sha $(echo "$B" | cut -f3 | cut -c1-16), written $(echo "$B" | cut -f4))"
fi
[ -f $O/build.log ] && grep -o 'section 1 (gui, Ver1.81) [0-9]* -> [0-9]* bytes\|MAIN packs to [0-9]* of [0-9]* bytes ([0-9.]*%)' $O/build.log | sed 's/^/size     /'
echo
echo "## gates"
if [ -f $O/verify.txt ]; then echo "verify    $(tail -1 $O/verify.txt)"; else echo "verify    MISSING"; fi
if [ -f $O/bootcheck.txt ]; then echo "bootcheck $(head -1 $O/bootcheck.txt)"; else echo "bootcheck MISSING"; fi
echo
echo "## real rig ($RUNS, latest per scenario; prefix ${VP:-?} preferred)"
if [ -d "$RUNS" ]; then
  ( cd "$RUNS"
    pick() {	# newest run whose report header matches KEY, this build's prefix first
      local k=$1 best= any=
      for d in $(ls -t); do
        [ -f $d/report.txt ] || continue
        head -1 $d/report.txt | grep -q -- "$k" || continue
        [ -z "$any" ] && any=$d
        case $d in "$VP"*) best=$d; break;; esac
      done
      echo ${best:-$any}
    }
    for s in "net4_dd:net4_dd" "ksync_rig2:KEY SYNC real rig" "ksync_mtap:KEY SYNC tap" "lc_linkcue:lc_linkcue" "solo3:solo3"; do
      name=${s%%:*}; key=${s#*:}; d=$(pick "$key")
      if [ -z "$d" ]; then echo "$name: no run"; continue; fi
      tag=""; case $d in "$VP"*) ;; *) tag="  [OTHER BUILD]";; esac
      echo "$name: $d$tag  $(sed -n 2p $d/report.txt | sed 's/  */ /g')"
      grep -E '^FAIL' $d/report.txt | head -4 | sed 's/^/    /' | cut -c1-140
    done )
else
  echo "(no runs directory)"
fi
} > $R 2>&1
cat $R
