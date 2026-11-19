#!/bin/bash
# A stand-in for `omarchy-notification-send`: it records its argv in
# `argv` next to it (each argument ending in a NUL byte), then does what the
# file `mode` next to it says: nothing (exit 0), `fail` (exit 3) or `hang`
# (starts a child, writes its pid to `child` and waits for it). It never
# sends a notification and runs nothing but builtins and sleep.
d=${0%/*}
printf '%s\0' "$@" >"$d/argv"
mode=
[ -f "$d/mode" ] && read -r mode <"$d/mode"
case $mode in
  fail)
    echo "fake notification-send: refused" >&2
    exit 3
    ;;
  hang)
    /usr/bin/sleep 30 &
    echo "$!" >"$d/child"
    wait
    ;;
esac
exit 0
