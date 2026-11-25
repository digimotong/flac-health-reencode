# shellcheck shell=bash
# lib/common.sh - the entry script's shared vocabulary: the tty probe and generic
# pure helpers (duration formatting). Sourced by flac_health_reencode.sh; no globals
# are declared here (the entry owns the display-state variables).

# 0 while fd 1 is attached to a terminal. The answer is cached in STDOUT_IS_TTY.
stdout_is_tty() {
    [ -z "$STDOUT_IS_TTY" ] && { [ -t 1 ] && STDOUT_IS_TTY=1 || STDOUT_IS_TTY=0; }
    [ "$STDOUT_IS_TTY" = "1" ]
}

# Formatted "H:MM:SS" (or "M:SS" under an hour) from a whole number of seconds.
# $1 = seconds. Prints nothing for a non-numeric value, so a caller can drop the
# field rather than print a nonsense estimate.
format_duration() {
    local secs="${1:-}"
    [[ "$secs" =~ ^[0-9]+$ ]] || return 0
    if [ "$secs" -ge 3600 ]; then
        printf '%d:%02d:%02d' $((secs / 3600)) $(( (secs % 3600) / 60 )) $((secs % 60))
    else
        printf '%d:%02d' $((secs / 60)) $((secs % 60))
    fi
}

# Renders progress AS TEXT (no carriage return, no clearing, no newline), so the
# caller decides whether it is a one-line animation or a plain line:
#
#   [####################----------]  62% (620/1000) | failed: 3 | 04:12 ETA 02:34
#
# The leading "[#...-] NNN% (done/total)" core survives every degradation, so it
# is the part output consumers can rely on. Time fields appear only when timings
# are asked for ($5=1) and there is a meaningful estimate (ETA needs at least one
# completed file). The bar shrinks to fit PROGRESS_COLS, from PROGRESS_MAX_WIDTH
# down to PROGRESS_MIN_WIDTH, and the timing fields are dropped before the bar
# would go below the minimum, so the line never wraps.
