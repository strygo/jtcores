#!/bin/bash
# CPS+ fitter A/B driver.
#
# Builds the SAME tree twice and reports the timing/utilization delta:
#   1. stock leg:   jtcore <core> -mister            -> results/stock/
#   2. cpsplus leg: jtcore <core> -mister -d CPSPLUS -> results/cpsplus/
# CPS+ is fully gated on the CPSPLUS macro (RTL `ifdef, cfgstr template,
# tied-off gate wire), so the stock leg IS the upstream core; there is no
# patch/install step any more — the integration lives in the tree.
#
# usage:  fitter_ab.sh <jtcores-root> [results-dir]
# env:    SEED=<n>          Quartus fitter seed (default 1, both legs)
#         TRIALS=<n>        seeds tried per leg: SEED, SEED+1, ... until STA
#                           passes (default 1 = single seed, the A/B
#                           experiment setting).  Upstream CI retries seeds
#                           the same way; a marginal miss is placement luck,
#                           not a verdict.
#         CORE=<core>       cps2 (default), cps1, cps15
#         SKIP_STOCK=1      skip the stock leg (e.g. seed-retry of CPSPLUS)
#         SKIP_CPSPLUS=1    stock baseline only
#         CPSPLUS_DBG=1     cpsplus leg also defines CPSPLUS_DBG (the visual
#                           pack-state overlay; omit for release builds)
#         JTCORE_EXTRA=...  extra args appended to every jtcore call
#
# jtcore exits 1 on a negative-slack STA result even though the .rbf and all
# reports are produced; this script harvests reports either way and records
# the per-leg exit code in the manifest.  Overall exit: 0 only if every leg
# built AND passed STA.

set -u

JTC=${1:?usage: fitter_ab.sh <jtcores-root> [results-dir]}
JTC=$(cd "$JTC" && pwd)
RESULTS=${2:-$JTC/fitter_results}
SEED=${SEED:-1}
TRIALS=${TRIALS:-1}
JTCORE_EXTRA=${JTCORE_EXTRA:-}
HERE=$(cd "$(dirname "$0")" && pwd)

CORE=${CORE:-cps2}
TARGET=mister
NAME=jt$CORE
JTCORE_ARGS_BASE="$CORE -$TARGET --nodbg --nolinter --nocopy $JTCORE_EXTRA"

fail() { echo "fitter_ab: ERROR: $*" >&2; exit 1; }
note() { echo "fitter_ab: $*"; }

# ---------------------------------------------------------------- sanity --
test -f "$JTC/setprj.sh"                      || fail "$JTC is not a jtcores root"
test -f "$JTC/cores/$CORE/hdl/${NAME}_game.v" || fail "no $CORE core in $JTC"
test -d "$JTC/modules/cpsplus/hdl"            || fail "modules/cpsplus missing"

# mounted volumes are often owned by another uid (same fix as devops/xjtcore.sh)
git config --global --add safe.directory "$JTC" 2>/dev/null || true

HEAD=$(git -C "$JTC" rev-parse --short=7 HEAD)
DIRTY=$(git -C "$JTC" status --porcelain --untracked-files=no --ignore-submodules=dirty)
[ -n "$DIRTY" ] && note "WARNING: tree has tracked modifications; legs are still A/B-comparable (same tree both legs) but not upstream-comparable"

# ------------------------------------------------------------ environment --
command -v python >/dev/null || fail "python not on PATH (setprj.sh requires it)"
set +u
cd "$JTC"
set --   # clear positional params: setprj.sh executes "$*" if non-empty
source "$JTC/setprj.sh"
set -u
BUILDDIR=$JTROOT/cores/$CORE/$TARGET

note "bootstrapping jtframe (go build on first run)"
jtframe --help > /dev/null || fail "jtframe bootstrap failed (Go missing? network for modules?)"
command -v gawk >/dev/null || fail "gawk not on PATH (jtcore needs it)"

QVER=$( (quartus_sh --version 2>/dev/null || true) | tr '\n' ' ' )
note "quartus: ${QVER:-<not on PATH yet; jtcore will search /opt/intelFPGA_lite>}"

mkdir -p "$RESULTS"
MANIFEST=$RESULTS/manifest.txt
{
    echo "CPS+ fitter A/B  $(date -u +%Y-%m-%dT%H:%M:%SZ)  host=$(hostname)"
    echo "jtcores: $JTC @ $HEAD  dirty_tracked=$([ -n "$DIRTY" ] && echo yes || echo no)"
    echo "quartus: ${QVER:-unknown-at-start}"
    echo "jtcore args: $JTCORE_ARGS_BASE --seed $SEED (trials=$TRIALS)"
    echo
} > "$MANIFEST"

# --------------------------------------------------------------- one leg --
# harvest <legdir>: copy reports out of the build tree (jtcore wipes
# cores/$CORE/mister/ at the start of the NEXT build -- harvest or lose them)
harvest() {
    local out=$1
    mkdir -p "$out"
    # Locate the REAL output_files dir + log by search: setprj clobbers $TARGET
    # (seen as sidi128), so $BUILDDIR/$TARGET is unreliable. Prefer a dir that
    # actually contains the rbf/sof; else any output_files under cores/$CORE.
    local of logf
    of=$(dirname "$(find "$JTROOT/cores/$CORE" -name "$NAME.rbf" -o -name "$NAME.sof" 2>/dev/null | head -1)" 2>/dev/null)
    [ -d "$of" ] || of=$(find "$JTROOT/cores/$CORE" -type d -name output_files 2>/dev/null | head -1)
    logf=$(find "$JTROOT/log" -name "$NAME.log" 2>/dev/null | head -1)
    if [ -n "$logf" ]; then
        cp "$logf" "$out/" 2>/dev/null || true
    fi
    # cfgstr is rendered by jtframe into the core's mister build tree, NOT next
    # to the log — search for a non-empty one. Capturing it confirms the CPS+
    # OSD volume row is present only in the CPSPLUS leg.
    local cfg
    cfg=$(find "$JTROOT/cores/$CORE" -type f -name cfgstr -size +0c 2>/dev/null | head -1)
    [ -n "$cfg" ] || cfg=$(find "$JTROOT" -type f -name cfgstr -size +0c 2>/dev/null | head -1)
    if [ -n "$cfg" ]; then cp "$cfg" "$out/" 2>/dev/null || true
    else note "WARNING: no non-empty cfgstr found for $NAME (OSD row unconfirmed)"; fi
    if [ -z "$of" ] || [ ! -d "$of" ]; then
        note "WARNING: no output_files found under cores/$CORE (searched); only logs harvested"
        find "$JTROOT/cores/$CORE" -maxdepth 4 \( -name "*.rbf" -o -name "*.sof" -o -name "*.fit.summary" \) 2>/dev/null | head >&2
        return
    fi
    note "harvesting from $of"
    cp "$of/$NAME.rbf"          "$out/" 2>/dev/null || note "WARNING: no rbf in $of"
    for f in fit.summary sta.summary map.summary flow.rpt; do
        cp "$of/$NAME.$f" "$out/" 2>/dev/null || note "WARNING: missing $NAME.$f"
    done
    for f in fit.rpt sta.rpt map.rpt; do        # big ones -> gzip
        if [ -e "$of/$NAME.$f" ]; then gzip -c "$of/$NAME.$f" > "$out/$NAME.$f.gz"; fi
    done
    for f in sdram_stuck.rpt sdram_io.rpt; do
        cp "$of/$f" "$out/" 2>/dev/null || true
    done
    cp "$BUILDDIR/sdram_badio.rpt"        "$out/" 2>/dev/null || true
    grep "Worst-case" "$logf" > "$out/worst_slack.txt" 2>/dev/null || true

    # Detailed worst-path STA: the harvested sta.rpt is summary-only (no
    # source/destination nodes). Emit the top setup paths node-by-node.
    # Never fatal: pure diagnostics.
    local pdir; pdir=$(dirname "$of")
    if [ -f "$pdir/$NAME.qpf" ] && command -v quartus_sta >/dev/null 2>&1; then
        note "detailed STA -> $out/worst_paths.rpt"
        quartus_sta -t "$HERE/sta_detail.tcl" "$pdir" "$NAME" \
            "$out/worst_paths.rpt" > "$out/sta_detail.log" 2>&1 \
            || note "WARNING: detailed STA failed (see sta_detail.log)"
    else
        note "WARNING: no $NAME.qpf in $pdir (or no quartus_sta): skipping detailed STA"
    fi
}

build_leg() {
    local leg=$1
    local extra=${2:-}   # per-leg extra jtcore args (cpsplus leg: -d CPSPLUS)
    local rc=0 seed=$SEED try=0
    # Try seeds SEED..SEED+TRIALS-1 until STA closes.  Every violating path
    # measured so far ends at the SDRAM DDIO output register with ~4 ns of a
    # single placement-dependent route in the cone, so a marginal miss is
    # seed luck; retrying is the same remedy upstream CI uses.  Each trial
    # harvests over the previous one, so artifacts describe the LAST build.
    for try in $(seq 0 $((TRIALS-1))); do
        seed=$((SEED+try))
        note "=== $leg leg (seed $seed): jtcore $JTCORE_ARGS_BASE --seed $seed $extra ==="
        rc=0
        ( cd "$JTROOT" && jtcore $JTCORE_ARGS_BASE --seed $seed $extra ) || rc=$?
        harvest "$RESULTS/$leg"
        echo "[$leg] trial seed=$seed exit=$rc" >> "$MANIFEST"
        [ $rc -eq 0 ] && break
        [ -e "$RESULTS/$leg/$NAME.rbf" ] || break   # hard failure: retrying won't help
    done
    {
        echo "[$leg] exit=$rc  seed=$seed  trials_used=$((try+1))"
        [ -e "$RESULTS/$leg/worst_slack.txt" ] && sed "s/^/[$leg] /" "$RESULTS/$leg/worst_slack.txt"
        if [ -e "$RESULTS/$leg/$NAME.fit.summary" ]; then
            grep -E "Logic utilization|Total block memory|Total RAM|Total DSP|Total registers" \
                "$RESULTS/$leg/$NAME.fit.summary" | sed "s/^/[$leg] /"
        fi
        echo
    } >> "$MANIFEST"
    if [ ! -e "$RESULTS/$leg/$NAME.rbf" ]; then
        fail "$leg leg produced no rbf (hard compile failure; see $RESULTS/$leg/$NAME.log)"
    fi
    if [ $rc -ne 0 ]; then
        note "$leg leg: built but jtcore returned $rc (STA miss? see worst_slack.txt) -- reports harvested"
    fi
    return $rc
}

# ------------------------------------------------------------------ legs --
OVERALL=0

if [ -z "${SKIP_STOCK:-}" ]; then
    build_leg stock || OVERALL=1
else
    note "SKIP_STOCK set: skipping stock leg"
fi

if [ -z "${SKIP_CPSPLUS:-}" ]; then
    # CPSPLUS_DBG=1 -> also define CPSPLUS_DBG: the on-screen pack-state
    # overlay (modules/cpsplus/README.md).  Omit for release builds.
    build_leg cpsplus "-d CPSPLUS${CPSPLUS_DBG:+ -d CPSPLUS_DBG}" || OVERALL=1
    # name the distributable core distinctly so its MRAs bind to it and it
    # coexists with stock jt$CORE.rbf
    [ -e "$RESULTS/cpsplus/$NAME.rbf" ] && \
        cp "$RESULTS/cpsplus/$NAME.rbf" "$RESULTS/cpsplus/${NAME}_cpsplus.rbf"

    # by-entity extract: the cpsplus_* rows of the fitter hierarchy table
    if [ -e "$RESULTS/cpsplus/$NAME.fit.rpt.gz" ]; then
        gzip -dc "$RESULTS/cpsplus/$NAME.fit.rpt.gz" | \
            awk '/Fitter Resource Utilization by Entity/{f=1} f&&/^$/{exit} f' \
            > "$RESULTS/cpsplus/by_entity_full.txt" || true
        grep -i "cpsplus" "$RESULTS/cpsplus/by_entity_full.txt" \
            > "$RESULTS/cpsplus/by_entity_cpsplus.txt" 2>/dev/null || \
            note "WARNING: no cpsplus rows in by-entity table (CPSPLUS undefined?)"
    fi
else
    note "SKIP_CPSPLUS set: skipping cpsplus leg"
fi

# ----------------------------------------------------------------- delta --
if [ -e "$RESULTS/stock/$NAME.fit.summary" ] && [ -e "$RESULTS/cpsplus/$NAME.fit.summary" ]; then
    diff -u "$RESULTS/stock/$NAME.fit.summary" "$RESULTS/cpsplus/$NAME.fit.summary" \
        > "$RESULTS/fit_summary.diff" || true
fi

{
    echo "sha256:"
    (cd "$RESULTS" && find . -type f ! -name manifest.txt -print0 | sort -z | xargs -0 sha256sum)
} >> "$MANIFEST"

note "results in $RESULTS (manifest.txt, fit_summary.diff, stock/, cpsplus/)"
exit $OVERALL
