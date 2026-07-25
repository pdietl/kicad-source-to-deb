#!/usr/bin/env bash
# Capture evidence about a KiCad UI stall (the GNOME "wait or force quit"
# dialog) across every layer that can produce one: KiCad's own trace output,
# the compositor's frame-sync complaints, the kernel/GPU log, and a stack
# snapshot of the blocked process taken while it is still blocked.
#
# Run it, reproduce the stall, quit KiCad. Everything lands in one fresh
# timestamped directory. Press Enter at any time to drop a marker into the
# event log ("I clicked the PCB editor now").
#
# Stack snapshots need root: ptrace_scope=1 forbids attaching to a
# non-descendant, and perf_event_paranoid=4 forbids unprivileged sampling.
# The script primes sudo once at start so a stall is never spent at a
# password prompt.

set -Euo pipefail

SAMPLE_INTERVAL=0.4 # seconds between watchdog polls
STALL_SECS=3.0      # suspicious for this long => snapshot
MAX_SNAPSHOTS=12    # cap, so a permanent hang cannot fill the disk

# Trace masks that explain what KiCad was loading when it went quiet, without
# costing anything while it is quiet. KICAD_TOOL_STACK is deliberately absent:
# it logs a line per mouse-motion event, tens of thousands per session, which
# is I/O inside the window being timed.
#
# KICAD_GAL_PROFILE yields the per-frame render breakdown, but only from a
# build configured with -DKICAD_GAL_PROFILE=ON -- the call sites are behind a
# compile-time #ifdef of the same name. Listing it here is harmless on an
# ordinary build and is what makes the timings appear on a profiling one.
TRACE_MASKS="KICAD_GAL_PROFILE,KICAD_UI_PROFILE,KICAD_PATHS_AND_FILES,KICAD_LIBRARIES,KICAD_WAYLAND"

# Main-thread wait channels that mean "idle in the GLib event loop", not
# "stalled". Anything else, for STALL_SECS, is treated as a blocked stall.
IDLE_WCHANS='do_epoll_wait|ep_poll|do_sys_poll|poll_schedule_timeout|do_select'

KICAD_BIN=${KICAD_BIN:-/usr/bin/kicad}
PROC_NAME=${PROC_NAME:-kicad} # process to watch; overridable for self-test
CFG_DIR=${CFG_DIR:-$HOME/.config/kicad/10.0}
ADV_CFG="$CFG_DIR/kicad_advanced"

RUNDIR=
ADV_CFG_SAVED=
declare -a BG_PIDS=()
declare -A COLLECTORS=() # label -> pid, for the liveness assertions

die() {
    printf 'kicad-hang-capture: %s\n' "$*" >&2
    exit 1
}

note() { printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$RUNDIR/events.log"; }

# Name the GPU behind a sysfs device link, e.g. "01:00.0 NVIDIA ... RTX PRO".
gpu_of() {
    local slot
    slot=$(basename "$(readlink -f "$1" 2>/dev/null)" 2>/dev/null) || return 0
    [ -n "$slot" ] || return 0
    lspci -nn -s "${slot#0000:}" 2>/dev/null | cut -c1-70 || printf '%s' "$slot"
}

# ---------------------------------------------------------------- environment

record_environment() {
    local out=$RUNDIR/00-environment.txt
    {
        echo "### captured $(date '+%F %T %Z') on $(hostname)"
        echo
        echo "### session"
        printf 'XDG_SESSION_TYPE=%s\nWAYLAND_DISPLAY=%s\nDISPLAY=%s\nXDG_CURRENT_DESKTOP=%s\nGDK_BACKEND=%s\n' \
            "${XDG_SESSION_TYPE:-unset}" "${WAYLAND_DISPLAY:-unset}" \
            "${DISPLAY:-unset}" "${XDG_CURRENT_DESKTOP:-unset}" "${GDK_BACKEND:-unset}"
        echo
        echo "### connected outputs (which GPU actually drives each display)"
        local s conn
        for s in /sys/class/drm/card*-*/status; do
            [ -r "$s" ] || continue
            [ "$(cat "$s")" = connected ] || continue
            conn=$(dirname "$s")
            printf '%-24s %s\n' "$(basename "$conn")" "$(gpu_of "$conn/../device")"
        done
        echo
        echo "### render nodes (a stall is likely if KiCad renders on a"
        echo "### different GPU than the one driving the displays)"
        local r
        for r in /sys/class/drm/renderD*; do
            [ -e "$r" ] || continue
            printf '%-12s %s\n' "$(basename "$r")" "$(gpu_of "$r/device")"
        done
        echo
        echo "### GPUs"
        lspci -nn | grep -iE 'vga|3d controller|display' || true
        echo
        echo "### drivers"
        cat /proc/driver/nvidia/version 2>/dev/null || echo '(no nvidia)'
        printf 'mutter: %s\n' "$(dpkg-query -W -f='${Version}' mutter-common 2>/dev/null || echo '?')"
        printf 'kicad:  %s\n' "$(dpkg-query -W -f='${Version}' kicad 2>/dev/null || echo '?')"
        printf 'wx:     %s\n' "$(dpkg-query -W -f='${Version}' libwxgtk3.2-1t64 2>/dev/null || echo '?')"
        echo
        echo "### monitor layout"
        gnome-monitor-config list 2>/dev/null || echo '(gnome-monitor-config unavailable)'
        echo
        echo "### debug symbols in the shipped binaries"
        file -b "$KICAD_BIN"
        printf 'exported symbols in _pcbnew.kiface: %s\n' \
            "$(nm -D --defined-only /usr/bin/_pcbnew.kiface 2>/dev/null | wc -l)"
    } >"$out" 2>&1
}

# ------------------------------------------------------------------- tracing

enable_traces() {
    mkdir -p "$CFG_DIR"
    if [ -e "$ADV_CFG" ]; then
        ADV_CFG_SAVED=$RUNDIR/kicad_advanced.orig
        cp -a "$ADV_CFG" "$ADV_CFG_SAVED"
        sed -i '/^TraceMasks=/d' "$ADV_CFG"
    else
        ADV_CFG_SAVED=ABSENT
        : >"$ADV_CFG"
    fi
    printf 'TraceMasks=%s\n' "$TRACE_MASKS" >>"$ADV_CFG"
    cp -a "$ADV_CFG" "$RUNDIR/kicad_advanced.used"
}

restore_traces() {
    [ -n "$ADV_CFG_SAVED" ] || return 0
    if [ "$ADV_CFG_SAVED" = ABSENT ]; then
        rm -f "$ADV_CFG"
    else
        cp -a "$ADV_CFG_SAVED" "$ADV_CFG"
    fi
}

# ---------------------------------------------------------------- collectors

start_collectors() {
    journalctl -f -n0 -o short-precise -t gnome-shell \
        >"$RUNDIR/20-journal-shell.log" 2>&1 &
    COLLECTORS["20-journal-shell.log"]=$!
    BG_PIDS+=($!)

    journalctl -kf -n0 -o short-precise \
        >"$RUNDIR/21-journal-kernel.log" 2>&1 &
    COLLECTORS["21-journal-kernel.log"]=$!
    BG_PIDS+=($!)

    if command -v nvidia-smi >/dev/null; then
        nvidia-smi --format=csv -l 1 \
            --query-gpu=timestamp,utilization.gpu,utilization.memory,memory.used,clocks.sm,temperature.gpu,power.draw \
            >"$RUNDIR/30-gpu.csv" 2>&1 &
        COLLECTORS["30-gpu.csv"]=$!
        BG_PIDS+=($!)
    fi
}

# A follower that captured nothing because the journal was quiet is healthy;
# one that died is not. Only the process itself can tell the two apart, so
# liveness is sampled before anything is killed.
check_collectors() {
    local label
    for label in "${!COLLECTORS[@]}"; do
        if kill -0 "${COLLECTORS[$label]}" 2>/dev/null; then
            COLLECTORS[$label]=ALIVE
        else
            COLLECTORS[$label]=DIED
        fi
    done
}

stop_collectors() {
    local p
    for p in "${BG_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
    wait "${BG_PIDS[@]}" 2>/dev/null || true
}

# -------------------------------------------------------------------- launch

# Sets KICAD_PID. Deliberately not a command substitution: that would run the
# whole function in a subshell, losing the background pid and turning die()
# into a silent subshell exit that leaves main() running with no pid.
KICAD_PID=
launch_kicad() {
    # KiCad has two independent trace channels and a mask must be enabled
    # on the one its call site uses. wxLogTrace: gated by KICAD_ENABLE_WXTRACE,
    # masks from kicad_advanced, because this wxWidgets build ignores the
    # WXTRACE variable entirely. KI_TRACE (TRACE_MANAGER): reads the same mask
    # names from KICAD_TRACE and prints to stderr; the GAL profile's per-phase
    # "Timing:" line uses this channel.
    KICAD_ENABLE_WXTRACE=1 KICAD_TRACE="$TRACE_MASKS" "$KICAD_BIN" "$@" 2>&1 |
        gawk '{ printf "%s %s\n", strftime("%F %T"), $0; fflush() }' \
            >"$RUNDIR/10-kicad.log" &
    BG_PIDS+=($!)

    local deadline=$((SECONDS + 30))
    while [ "$SECONDS" -lt "$deadline" ]; do
        KICAD_PID=$(pgrep -n -u "$UID" -x "$PROC_NAME" 2>/dev/null) || KICAD_PID=
        [ -n "$KICAD_PID" ] && return 0
        sleep 0.2
    done
    die "KiCad did not start within 30s; see $RUNDIR/10-kicad.log"
}

# Which display protocol and which GPU KiCad actually chose. Both are
# runtime choices no environment variable reliably reports: GTK picks the
# backend itself, and the GL stack picks the render node itself. Unix-socket
# peers and open render nodes are the only honest evidence.
record_window_system() {
    local pid=$1 peers x11 wl
    peers=$(ss -xp 2>/dev/null | grep "pid=$pid," || true)
    x11=$(grep -c '/tmp/.X11-unix/X' <<<"$peers" || true)
    wl=$(grep -c '/wayland-' <<<"$peers" || true)
    {
        echo "### display protocol (from actual socket peers, not env vars)"
        printf 'X11 (XWayland) connections: %s\n' "$x11"
        printf 'native Wayland connections: %s\n' "$wl"
        if [ "$x11" -gt 0 ]; then
            echo '=> KiCad is on XWayland'
        elif [ "$wl" -gt 0 ]; then
            echo '=> KiCad is on native Wayland'
        else
            echo '=> INDETERMINATE -- ss found no display socket for this pid'
        fi
        echo
        echo "### GPU render nodes KiCad has open"
        local r n
        for r in /dev/dri/renderD*; do
            [ -e "$r" ] || continue
            n=$(find "/proc/$pid/fd" -lname "$r" 2>/dev/null | wc -l)
            [ "$n" -gt 0 ] && printf '%-20s %s fd(s)  %s\n' "$r" "$n" \
                "$(gpu_of "/sys/class/drm/$(basename "$r")/device")"
        done
        echo
        echo "### environment as KiCad sees it"
        tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null |
            grep -E '^(GDK_|WAYLAND|DISPLAY|XDG_SESSION|__NV|__GL|LIBGL|MESA|KICAD)' || true
    } >"$RUNDIR/01-window-system.txt" 2>&1
}

# ------------------------------------------------------------------ watchdog

# The stall predicate. Two ways a UI thread stops answering the compositor:
# it spins (state R, burning CPU) or it parks somewhere that is not the event
# loop. Everything else -- notably sitting in epoll waiting for input -- is a
# healthy idle app and must not trigger.
#
# Echoes a reason when the sample looks stalled, nothing when it looks fine.
stall_reason() {
    local pid=$1 cpu_delta=$2 state wchan
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null) || return 0
    wchan=$(cat "/proc/$pid/task/$pid/wchan" 2>/dev/null) || wchan=unknown

    if [ "$state" = R ] && [ "$cpu_delta" -gt 0 ]; then
        printf 'busy (state=R, cpu+%s ticks)' "$cpu_delta"
    elif [[ ! $wchan =~ $IDLE_WCHANS ]]; then
        printf 'blocked (state=%s, wchan=%s)' "$state" "$wchan"
    fi
}

snapshot() {
    local pid=$1 reason=$2 n=$3 scope=${4:-all}
    local out
    out=$(printf '%s/40-stalls/stall-%02d-%s.txt' "$RUNDIR" "$n" "$(date '+%H%M%S')")
    mkdir -p "$RUNDIR/40-stalls"
    {
        printf '### stall snapshot %s   pid=%s\n### reason: %s\n\n' \
            "$(date '+%F %T.%3N')" "$pid" "$reason"

        if [ "$scope" = main ]; then
            # A repeat sample inside a stall already in progress. Only the
            # main thread matters here, and a 30-thread dump would cost
            # seconds of the very stall being sampled.
            echo "### main thread only (repeat sample within one stall)"
            sudo -n gdb -p "$pid" -batch \
                -ex 'set pagination off' \
                -ex 'bt 40' \
                -ex 'detach' 2>&1 ||
                echo "!! gdb failed -- sudo expired?"
        else
            echo "### per-thread state (name / state / wchan)"
            local t
            for t in "/proc/$pid/task/"*; do
                [ -d "$t" ] || continue
                printf '%-8s %-22s %-3s %s\n' "$(basename "$t")" \
                    "$(cat "$t/comm" 2>/dev/null)" \
                    "$(awk '{print $3}' "$t/stat" 2>/dev/null)" \
                    "$(cat "$t/wchan" 2>/dev/null)"
            done

            echo
            echo "### backtraces (all threads)"
            sudo -n gdb -p "$pid" -batch \
                -ex 'set pagination off' \
                -ex 'set print thread-events off' \
                -ex 'thread apply all bt 40' \
                -ex 'detach' 2>&1 ||
                echo "!! gdb failed -- sudo expired? re-run 'sudo -v' in another terminal"

            echo
            echo "### GPU at the moment of the stall"
            nvidia-smi -q -d UTILIZATION,CLOCK,PERFORMANCE 2>/dev/null |
                grep -vE '^\s*$' | head -60 || echo '(nvidia-smi unavailable)'
        fi
    } >"$out" 2>&1
    note "STALL #$n: $reason -> $(basename "$out")"
}

watchdog() {
    local pid=$1
    local stall_samples=0 snaps=0 prev_cpu=0 cpu delta reason fired=0 since_snap=0
    local need
    need=$(awk -v s="$STALL_SECS" -v i="$SAMPLE_INTERVAL" 'BEGIN{printf "%d", s/i}')

    note "watching pid $pid (Enter = marker, quit KiCad to finish)"
    while kill -0 "$pid" 2>/dev/null; do
        # Markers only make sense on a terminal. Without the tty test, read
        # returns instantly on EOF and the watchdog spins at 100% CPU --
        # perturbing the very timing it exists to measure.
        local line
        if [ -t 0 ] && read -r -t "$SAMPLE_INTERVAL" line; then
            note "MARK: ${line:-<enter>}"
        elif [ ! -t 0 ]; then
            sleep "$SAMPLE_INTERVAL"
        fi

        cpu=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null) || break
        delta=$((cpu - prev_cpu))
        prev_cpu=$cpu

        reason=$(stall_reason "$pid" "$delta")
        if [ -n "$reason" ]; then
            stall_samples=$((stall_samples + 1))
            since_snap=$((since_snap + 1))
            # Sample repeatedly through a sustained stall rather than once per
            # episode. One stack cannot distinguish a thread wedged on a single
            # call from one grinding through a long sequence, and that is the
            # whole question; several stacks seconds apart answer it directly.
            if [ "$since_snap" -ge "$need" ] && [ "$snaps" -lt "$MAX_SNAPSHOTS" ]; then
                snaps=$((snaps + 1))
                since_snap=0
                # The first stack of an episode carries every thread for
                # context; later ones take the main thread only, because a
                # 30-thread dump costs seconds of the stall being measured.
                if [ "$fired" -eq 0 ]; then
                    fired=1
                    snapshot "$pid" "$reason" "$snaps" all
                else
                    snapshot "$pid" "$reason" "$snaps" main
                fi
            fi
        else
            [ "$fired" -eq 1 ] && note "recovered after $stall_samples samples"
            stall_samples=0
            since_snap=0
            fired=0
        fi
    done
    note "KiCad exited; took $snaps stall snapshot(s)"
}

# ------------------------------------------------------------------ manifest

# A dead instrument emits data-shaped output, not an error. Every sink is
# asserted non-trivial here so that "nothing found" can never be confused
# with "nothing recorded".
write_manifest() {
    local out=$RUNDIR/MANIFEST.txt failed=0
    # min=0 marks a sink that is legitimately allowed to be empty, because a
    # quiet journal is not a broken follower. Those are judged by liveness.
    local -a checks=(
        "10-kicad.log|KiCad stdout+stderr|1"
        "20-journal-shell.log|compositor (gnome-shell) journal|0"
        "21-journal-kernel.log|kernel journal|0"
        "30-gpu.csv|GPU utilisation samples|2"
        "00-environment.txt|environment snapshot|10"
        "01-window-system.txt|X11-vs-Wayland determination|3"
    )
    {
        printf '### run %s\n\n' "$RUNDIR"
        local spec f desc min n status
        for spec in "${checks[@]}"; do
            IFS='|' read -r f desc min <<<"$spec"
            n=0
            [ -f "$RUNDIR/$f" ] && n=$(wc -l <"$RUNDIR/$f")
            if [ "${COLLECTORS[$f]:-}" = DIED ]; then
                status=DEAD # follower crashed: this sink cannot be trusted
            elif [ ! -f "$RUNDIR/$f" ]; then
                status=DEAD # never created at all
            elif [ "$n" -lt "$min" ]; then
                status=DEAD # produced less than the sink must always produce
            elif [ "$n" -eq 0 ]; then
                status=QUIET # allowed to be empty, and its follower survived
            else
                status=OK
            fi
            [ "$status" = DEAD ] && failed=1
            printf '%-5s %-38s %6s lines  %s\n' "$status" "$desc" "$n" "$f"
        done

        n=$(find "$RUNDIR/40-stalls" -name 'stall-*.txt' 2>/dev/null | wc -l)
        printf '%-4s %-38s %6s files\n' "$([ "$n" -gt 0 ] && echo OK || echo NONE)" \
            'stall snapshots' "$n"

        if grep -qs 'ptrace: Operation not permitted' "$RUNDIR/40-stalls/"*.txt; then
            echo 'DEAD gdb could not attach -- snapshots contain no stacks'
            failed=1
        fi
        if [ -s "$RUNDIR/10-kicad.log" ] &&
            ! grep -q 'Trace: (' "$RUNDIR/10-kicad.log"; then
            # Test for trace output as such, not for one chosen mask: a mask
            # whose call sites simply never ran is not evidence that tracing
            # failed to switch on, and reporting it as such cries wolf.
            echo 'WARN no trace output in the KiCad log -- masks may not have applied'
        fi
        # The per-phase "Timing:" line travels the KI_TRACE channel, which is
        # switched on separately from wxLogTrace. When the installed build has
        # the GAL timers compiled in, a run that never logged one means that
        # channel was off, and the run cannot answer the question a profiling
        # build exists to answer.
        local gallib
        gallib=$(ldconfig -p 2>/dev/null | awk '/libkigal\.so\./ { print $NF; exit }')
        if [ -n "$gallib" ] && strings -- "$gallib" 2>/dev/null | grep -q '^Timing:' &&
            [ -s "$RUNDIR/10-kicad.log" ] &&
            ! grep -q 'Timing:' "$RUNDIR/10-kicad.log"; then
            echo 'DEAD profiling build installed, but no Timing: lines were captured'
            failed=1
        fi
        echo
        if [ "$failed" -eq 0 ]; then
            echo 'Every instrument survived. QUIET means the source was silent,'
            echo 'which is a real observation. Safe to interpret.'
        else
            echo 'AT LEAST ONE INSTRUMENT IS DEAD. Do not interpret this run.'
        fi
    } >"$out"
    cat "$out"
}

# ---------------------------------------------------------------------- main

cleanup() {
    check_collectors # liveness must be sampled before anything is killed
    stop_collectors
    restore_traces
    [ -n "$RUNDIR" ] && write_manifest
}

main() {
    [ -x "$KICAD_BIN" ] || die "no KiCad at $KICAD_BIN (set KICAD_BIN=)"
    command -v gawk >/dev/null || die 'gawk is required (apt install gawk)'
    command -v gdb >/dev/null || die 'gdb is required (apt install gdb)'

    # The parent is created on demand, but the run directory itself must be
    # new: a capture sink opened over a previous run destroys it. Hence -p on
    # one line and not the other, and two distinct messages -- a single mkdir
    # -p would silently accept a collision, while a single bare mkdir blames
    # reuse for what is really just a missing parent.
    local base=${OUTDIR:-$PWD}
    mkdir -p "$base" || die "cannot create output directory: $base"
    RUNDIR="$base/kicad-hang-$(date '+%Y%m%d-%H%M%S')"
    mkdir "$RUNDIR" || die "refusing to reuse an existing run directory: $RUNDIR"
    : >"$RUNDIR/events.log"

    echo "Priming sudo now so a stall is never spent at a password prompt."
    sudo -v || die 'sudo is required for stack snapshots'
    (while true; do
        sleep 50
        sudo -n true 2>/dev/null || exit
    done) &
    BG_PIDS+=($!)

    trap cleanup EXIT
    note "run directory: $RUNDIR"

    record_environment
    enable_traces
    start_collectors

    launch_kicad "$@"
    record_window_system "$KICAD_PID"
    watchdog "$KICAD_PID"
}

main "$@"
