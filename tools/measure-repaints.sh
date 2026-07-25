#!/usr/bin/env bash
# Answer one question about a KiCad stall: is the main thread stuck inside a
# single frame, or repainting in a loop? Those need opposite fixes, and the
# repaint count during the stall separates them.
#
#   ./tools/measure-repaints.sh [seconds]
#
# Start it with KiCad already running, then switch editors while it watches.
#
# The readout is a per-second timeline rather than a total, because a total
# cannot distinguish a short stall from none at all: a 7 s stall inside a
# 25 s window averages ~30% CPU, which reads as ordinary use. Per second the
# same stall is unmistakable -- a run of intervals pinned near 100%.
#
# Repaints are counted with a uprobe on OPENGL_GAL::BeginDrawing, which every
# repaint calls exactly once via GAL_DRAWING_CONTEXT. A debugger breakpoint
# would stop the process once per frame and distort the timing under test.

set -Euo pipefail

# Symbolisation walks 1.9 GB of separated debug info and will reach for a
# debuginfod server as well; both turn a report into a multi-minute hang.
# Keep every perf invocation local, and never call `perf script`.
export DEBUGINFOD_URLS=

FREQ=999      # stack sampling rate for the profile
BUSY_MSEC=800 # task-clock per 1 s interval that counts as "stalled"

# Frame-pointer unwinding is useless here: libnvidia-glcore is built without
# frame pointers, so every stack that enters the driver truncates at the leaf
# and the hot address appears to have no callers at all. LBR reconstructs the
# chain from branch records instead, at a fraction of the size and overhead of
# dwarf unwinding. Set CALLGRAPH=dwarf if a chain comes back deeper than LBR's
# hardware limit.
CALLGRAPH=${CALLGRAPH:-lbr}

# Resolved from the dynamic linker rather than written out, so a KiCad version
# bump moves the soname without silently stranding the probes. The mangled
# names below are C++ ABI and stable across versions; the library file name is
# not.
LIB=$(ldconfig -p 2>/dev/null | awk '/libkigal\.so\./ { print $NF; exit }')

# name -> mangled symbol. BeginDrawing counts repaints (one per frame, via
# GAL_DRAWING_CONTEXT). UpdateAllLayersOrder is the expensive half of
# PCB_DRAW_PANEL_GAL::OnShow: it rewrites the depth of every vertex on the
# board and then forces a full redraw, so counting it separates a switch that
# pays that cost from one that merely redraws.
declare -A PROBES=(
    [kicad_begindraw]=_ZN5KIGFX10OPENGL_GAL12BeginDrawingEv
    [kicad_layerorder]=_ZN5KIGFX4VIEW20UpdateAllLayersOrderEv
)

die() {
    printf 'measure-repaints: %s\n' "$*" >&2
    exit 1
}

duration=${1:-25}
[ -n "$LIB" ] && [ -f "$LIB" ] || die 'libkigal not found -- is the kicad package installed?'
pid=$(pgrep -n -x kicad) || die 'KiCad is not running -- start it first'

sudo -v || die 'sudo is required (perf_event_paranoid=4 blocks unprivileged sampling)'

# Probes persist across runs, so each add is conditional: a second --add of
# the same symbol is an error, not a no-op.
existing=$(sudo perf probe --list 2>/dev/null || true)
events=task-clock
for name in "${!PROBES[@]}"; do
    if ! grep -q "probe_libkigal:$name" <<<"$existing"; then
        sudo perf probe -x "$LIB" --add "$name=${PROBES[$name]}" >/dev/null 2>&1 ||
            die "could not place uprobe $name (is kicad-dbgsym installed?)"
    fi
    events="$events,probe_libkigal:$name"
done

out=$PWD/repaint-$(date '+%Y%m%d-%H%M%S')
mkdir "$out" || die "refusing to reuse an existing directory: $out"

echo "Watching pid $pid for ${duration}s -- switch editors NOW."

sudo perf stat -e "$events" -I 1000 -p "$pid" -o "$out/timeline.txt" \
    -- sleep "$duration" &
timeline=$!
sudo perf record -F "$FREQ" --call-graph "$CALLGRAPH" --output="$out/perf.data" -e cycles:u -p "$pid" \
    -- sleep "$duration" 2>"$out/record.err" || die "perf record failed; see $out/record.err"
wait "$timeline" 2>/dev/null || true
sudo chown "$(id -u):$(id -g)" "$out/perf.data" "$out/timeline.txt" 2>/dev/null || true

{
    printf '### per-second timeline (cpu%% is of one core)\n'
    printf '%5s %7s %9s %11s\n' sec 'cpu%' repaints layerorder
    awk -v busy="$BUSY_MSEC" '
        function num(v) { gsub(/,/, "", v); return (v ~ /^[0-9.]+$/) ? v+0 : 0 }
        /msec +task-clock/  { t=int($1); cpu[t]=num($2); if(!(t in seen)){seen[t]=1; ord[++n]=t} }
        /kicad_begindraw/   { t=int($1); rp[t]=num($2) }
        /kicad_layerorder/  { t=int($1); lo[t]=num($2) }
        END {
            stall_s=0; stall_rp=0; stall_lo=0; run=0; longest=0
            for (i=1; i<=n; i++) {
                t=ord[i]; c=cpu[t]; r=(t in rp)?rp[t]:0; l=(t in lo)?lo[t]:0
                mark=""
                if (c >= busy) {
                    mark="  <-- STALLED"; stall_s++; stall_rp+=r; stall_lo+=l
                    run++; if (run>longest) longest=run
                } else run=0
                printf "%5d %7d %9d %11d%s\n", t, c/10, r, l, mark
            }
            printf "\n### verdict\n"
            if (stall_s == 0) {
                print "NO STALL CAPTURED -- no interval reached " busy/10 "% of a core."
                print "Re-run and make the switch inside the window."
            } else {
                printf "stalled intervals: %d (longest run %ds)\n", stall_s, longest
                printf "repaints during those intervals: %d\n", stall_rp
                printf "layer-order rebuilds during those intervals: %d\n\n", stall_lo
                if (stall_rp <= stall_s)
                    print "=> STUCK: the main thread is inside one frame, not repainting."
                else if (stall_rp > stall_s * 10)
                    print "=> STORM: repainting in a loop; the trigger is upstream of the canvas."
                else
                    print "=> MIXED: repainting, but each frame is expensive."
                if (stall_lo > 0)
                    print "   layer-order rebuild ran: this switch paid the vertex-depth rewrite."
                else
                    print "   no layer-order rebuild: this stall has a different cause."
            }
        }
    ' "$out/timeline.txt"

    printf '\n### callers of the hot driver code (what the frame is actually doing)\n'
    timeout 240 perf report -i "$out/perf.data" --stdio --no-children -G \
        --percent-limit 5 2>/dev/null | grep -vE '^#|^$' | head -30

    printf '\n### where the CPU went (self time)\n'
    # -g none: resolving the call graph against the separated debug info runs
    # for minutes and then reports a truncated profile, which reads as a
    # complete one. The flat self-time profile answers the same question.
    timeout 200 perf report -i "$out/perf.data" --stdio -g none --no-children \
        --sort=symbol --percent-limit 1 2>/dev/null |
        grep -vE '^#|^$' | head -15
} | tee "$out/summary.txt"

echo
echo "Full data: $out"
