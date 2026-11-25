# shellcheck shell=bash
# lib/progress.sh - the one progress API every long-running option reports through
# (begin/update/clear/end), the renderer behind it, and write_status. Sourced by
# flac_health_reencode.sh; the PROGRESS_* state, the geometry and the colours are
# declared in the entry.

render_progress() {
    local done="$1"
    local total="$2"
    local fails="$3"
    local label="${4:-Failed}"
    local show_times="${5:-0}"
    local percent core timing width avail filled empty elapsed_text eta_text
    local bar_filled='' bar_empty=''

    [ "$total" -gt 0 ] || return 0
    [ "$done" -le "$total" ] || done="$total"

    percent=$(( done * 100 / total ))
    # "%3d%%" keeps the suffix a fixed width as the count climbs.
    printf -v core ' %3d%% (%d/%d) | %s: %d' "$percent" "$done" "$total" "$label" "$fails"

    timing=''
    if [ "$show_times" = '1' ] && [ "$done" -gt 0 ]; then
        local elapsed now eta
        now=$(date +%s)
        elapsed=$(( now - PROGRESS_START ))
        [ "$elapsed" -lt 0 ] && elapsed=0
        elapsed_text=$(format_duration "$elapsed")
        if [ "$done" -lt "$total" ]; then
            eta=$(( elapsed * (total - done) / done ))
            eta_text=$(format_duration "$eta")
            timing=" | ${elapsed_text} ETA ${eta_text}"
        elif [ -n "$elapsed_text" ]; then
            timing=" | ${elapsed_text}"
        fi
    fi

    # The line is "[" + bar + "]" + core + timing; keep it inside the terminal.
    width=$PROGRESS_WIDTH
    [ "$width" -gt "$PROGRESS_MAX_WIDTH" ] && width=$PROGRESS_MAX_WIDTH
    avail=$(( PROGRESS_COLS - ( ${#core} + ${#timing} + 2 ) ))
    [ "$avail" -lt "$width" ] && width=$avail
    if [ "$width" -lt "$PROGRESS_MIN_WIDTH" ]; then
        # Too narrow for the timings: retry without them before shrinking further.
        if [ -n "$timing" ]; then
            timing=''
            avail=$(( PROGRESS_COLS - ( ${#core} + 2 ) ))
            width=$PROGRESS_MAX_WIDTH
            [ "$avail" -lt "$width" ] && width=$avail
        fi
        # Still too narrow for even the minimum bar: drop the bar, keep the
        # counters. A wrapped line would wreck a single-line '\r' display, and the
        # counters are the part that must stay readable.
        if [ "$width" -lt "$PROGRESS_MIN_WIDTH" ]; then
            printf ' %3d%% (%d/%d) | %s: %d%s' "$percent" "$done" "$total" "$label" "$fails" "$timing"
            return 0
        fi
    fi

    filled=$(( percent * width / 100 ))
    empty=$(( width - filled ))
    # Pure-bash padding (no tr/seq child per redraw): printf '%*s' emits spaces.
    printf -v bar_filled '%*s' "$filled" ''
    printf -v bar_empty '%*s' "$empty" ''
    printf '[%s%s]%s%s' "${bar_filled// /#}" "${bar_empty// /-}" "$core" "$timing"
}

# Resolves the terminal width once per run: 'tput cols' when it is available and
# sanely wide, else $COLUMNS, else 80. A live display is padded by the renderer,
# so this only decides where the counters sit.
progress_resolve_cols() {
    local cols=''
    if stdout_is_tty && [ "${TERM:-}" != 'dumb' ] && command -v tput >/dev/null 2>&1; then
        cols=$(tput cols 2>/dev/null) || cols=''
    fi
    [[ "$cols" =~ ^[0-9]+$ ]] || cols="${COLUMNS:-}"
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    [ "$cols" -lt 20 ] && cols=80
    PROGRESS_COLS=$cols
    return 0
}

# Starts progress reporting for ONE run of $1 files. Everything after this is a
# no-op unless a run is active, so stray calls (and child processes, which start
# from PROGRESS_ACTIVE=0) can never draw over the parent's line.
# A live single-line display needs a real terminal AND a terminfo that is not
# 'dumb'; a pipe or redirect cannot be rewritten in place, so it gets plain
# periodic lines instead - unless the caller asked for no display at all, which
# is what a captured sequential run does (its per-file status lines already say
# everything). Sets PROGRESS_ACTIVE/PROGRESS_DRAW_LIVE/PROGRESS_TOTAL/
# PROGRESS_START and, when live, draws the initial 0% state.
# $1 = total files, $2 = counter label (e.g. 'Failed' or 'Errors'),
# $3 = quiet when captured (1 = no plain lines off a terminal, 0 = emit them).
progress_begin() {
    local total="$1"
    local label="${2:-Failed}"
    local quiet_off_tty="${3:-0}"

    PROGRESS_ACTIVE=0
    PROGRESS_DRAW_LIVE=0
    PROGRESS_TOTAL=0
    PROGRESS_DONE=0
    PROGRESS_FAIL=0
    PROGRESS_LAST_PCT=-1
    PROGRESS_LAST_DONE=-1

    # A zero-length run has nothing to report, and render_progress divides by total.
    [ "$total" -gt 0 ] || return 0

    PROGRESS_TOTAL=$total
    PROGRESS_LABEL=$label
    PROGRESS_START=$(date +%s)
    if stdout_is_tty && [ "${TERM:-}" != 'dumb' ]; then
        PROGRESS_ACTIVE=1
        PROGRESS_DRAW_LIVE=1
        progress_resolve_cols
        progress_update 0 0
    elif [ "$quiet_off_tty" != '1' ]; then
        PROGRESS_ACTIVE=1
    fi
    return 0
}

# Reports $1 completed files, of which $2 failed.
#
# A live display redraws in place only when the whole percent ADVANCES (or the
# run completes and that state has not been drawn yet), which caps a run at ~100
# redraws however large the library is. A non-live display writes a plain,
# self-terminated line on the same cadence, so a redirected long run still shows
# progress without flooding its log.
progress_update() {
    local done="$1"
    local fails="${2:-0}"
    local pct total

    if [ "$PROGRESS_ACTIVE" != '1' ]; then return 0; fi
    if [ "$PROGRESS_TOTAL" -le 0 ]; then return 0; fi
    [ "$done" -le "$PROGRESS_TOTAL" ] || done="$PROGRESS_TOTAL"

    total="$PROGRESS_TOTAL"
    pct=$(( done * 100 / total ))
    # Cheap guard first: below the last drawn percent nothing is redrawn, which is
    # the common case for a large library.
    if (( pct < PROGRESS_LAST_PCT )); then
        return 0
    fi
    # Then skip an equal percent, unless this is the run's final state.
    if (( pct == PROGRESS_LAST_PCT )) && (( done != total || PROGRESS_LAST_DONE == total )); then
        return 0
    fi
    PROGRESS_LAST_PCT=$pct
    PROGRESS_LAST_DONE=$done
    PROGRESS_DONE=$done
    PROGRESS_FAIL=$fails

    if [ "$PROGRESS_DRAW_LIVE" = '1' ]; then
        printf '\r'
        render_progress "$done" "$PROGRESS_TOTAL" "$fails" "$PROGRESS_LABEL" 1
        # Erase any tail the previous (wider) line left behind - e.g. a 3-digit
        # ETA becoming 2 digits. Standard VT100 CSI, supported everywhere.
        printf '\033[K'
    else
        printf 'Progress: '
        render_progress "$done" "$PROGRESS_TOTAL" "$fails" "$PROGRESS_LABEL" 1
        printf '\n'
    fi
    return 0
}

# Erases the live bar line before a status or summary line is printed (and from
# the interrupt handler, so its message is not appended to the bar). No-op when
# nothing live is drawn. Deliberately does NOT end progress: the next update
# redraws the bar.
progress_clear() {
    if [ "$PROGRESS_ACTIVE" = '1' ] && [ "$PROGRESS_DRAW_LIVE" = '1' ]; then
        printf '\r\033[K'
    fi
    return 0
}

# Ends progress reporting for the run: draws the final 100% state if it was never
# drawn, then terminates a live line with a newline so any summary that follows
# starts on its own row. Safe to call when no run is active.
progress_end() {
    if [ "$PROGRESS_ACTIVE" != '1' ]; then
        return 0
    fi
    progress_update "$PROGRESS_TOTAL" "$PROGRESS_FAIL"
    if [ "$PROGRESS_DRAW_LIVE" = '1' ]; then
        printf '\n'
    fi
    PROGRESS_ACTIVE=0
    PROGRESS_DRAW_LIVE=0
    return 0
}

# Writes one status line to the run log, and to the terminal while
# STATUS_TO_CONSOLE is 1. $1 = the full line, $2 = run log path.
write_status() {
    local line="$1"
    local log_file="$2"
    printf '%s\n' "$line" >> "$log_file"
    if [ "$STATUS_TO_CONSOLE" = "1" ]; then
        if [ "$PROGRESS_ACTIVE" = '1' ] && [ "$PROGRESS_DRAW_LIVE" = '1' ]; then
            # Wipe the live bar first, then print on its own row and redraw the
            # bar, so a sequential run can show both without gluing them together.
            progress_clear
            printf '%s\n' "$line"
            render_progress "$PROGRESS_DONE" "$PROGRESS_TOTAL" "$PROGRESS_FAIL" \
                "$PROGRESS_LABEL" 1
            printf '\033[K'
        else
            printf '%s\n' "$line"
        fi
    fi
}
