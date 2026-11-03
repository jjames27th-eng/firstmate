#!/usr/bin/env bash
# Old Treehouse v2.0.1: spawn and bootstrap refuse before any acquisition.
. "$(dirname "$0")/lib.sh"
SRC=$1; ID=old-th
new_lab; trap stop_lab EXIT
printf 'treehouse %s; lease --help exit: ' "$(treehouse --version)"; treehouse lease --help >/dev/null 2>&1; echo $?
brief "$ID"
out=$("$SRC/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout 2>&1); rc=$?
printf '$ bin/fm-spawn.sh %s\n%s\nexit=%s\n' "$ID" "$out" "$rc"
check 'spawn refused on old Treehouse' [ "$rc" != 0 ]
check 'refusal names treehouse lease support' grep -q 'requires treehouse lease support' <<<"$out"
check 'no copy acquired' [ ! -e "$LAB/pool/.treehouse" ]
check 'no worker window' bash -c '! tmux -L default list-windows -t firstmate -F "#W" | grep -q fm-old-th'
printf 'RESULT old-th fails=%s\n' "${FAILS:-0}"
