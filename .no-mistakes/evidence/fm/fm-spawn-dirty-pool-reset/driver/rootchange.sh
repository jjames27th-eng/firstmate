#!/usr/bin/env bash
# Protection failure refuses acquisition and names the blocking record and copy.
. "$(dirname "$0")/lib.sh"
SRC=$1; ID=rec-rootchange
new_lab; trap stop_lab EXIT
MATE="$LAB/mate"; mkdir -p "$MATE/state" "$MATE/data"
printf '%s\n' "- mate - secondmate (home: $MATE; scope: project; projects: project; added 2026-10-24)" > "$FM_HOME/data/secondmates.md"
COPY=$(th get --lease --lease-holder setup 2>/dev/null); th return --force "$COPY" 2>&1
printf 'kind=scout\nworktree=%s\nproject=%s\n' "$COPY" "$PROJECT" > "$MATE/state/paused-scout.meta"
printf 'root = "%s"\n' "$LAB/pool2" > "$PROJECT/treehouse.toml"; git -C "$PROJECT" commit -qam moved-root
git -C "$PROJECT" push -q origin main
printf 'project root moved to $LAB/pool2; record still names old copy\ntreehouse status now: %s\n' "$(th status --json)"
brief "$ID"
out=$("$SRC/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout 2>&1); rc=$?
printf '$ bin/fm-spawn.sh %s\n%s\nexit=%s\n' "$ID" "$out" "$rc"
check 'spawn refused' [ "$rc" != 0 ]
check 'refusal names the blocking record' grep -q 'paused-scout.meta' <<<"$out"
check 'refusal names the blocking copy' grep -qF "$COPY" <<<"$out"
check 'refusal says it will not acquire' grep -q 'refusing to acquire' <<<"$out"
printf 'files under new root: %s\n' "$(find "$LAB/pool2" -mindepth 3 2>/dev/null | wc -l | tr -d ' ')"; find "$LAB/pool2" -maxdepth 4 2>/dev/null | head
check 'no copy acquired in new root' bash -c '! ls -d "$1"/.treehouse/*/*/project >/dev/null 2>&1' _ "$LAB/pool2"
check 'no task record' [ ! -e "$FM_HOME/state/$ID.meta" ]
check 'no worker window' bash -c '! tmux -L default list-windows -t firstmate -F "#W" | grep -q fm-rec-rootchange'
printf 'RESULT rootchange fails=%s\n' "${FAILS:-0}"
