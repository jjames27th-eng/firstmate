#!/usr/bin/env bash
# recorded.sh <unpatched|patched> <src> <default-tip|unlanded|leased>
. "$(dirname "$0")/lib.sh"
name=$1 SRC=$2 mode=$3; ID="rec-$name-$mode"
new_lab; trap stop_lab EXIT
printf '=== %s mode=%s treehouse=%s\n' "$name" "$mode" "$(treehouse --version)"
MATE="$LAB/mate"; mkdir -p "$MATE/state" "$MATE/data"
printf '%s\n' "- mate - secondmate (home: $MATE; scope: project; projects: project; added 2026-10-24)" > "$FM_HOME/data/secondmates.md"
COPY=$(th get --lease --lease-holder setup 2>/dev/null)
th return --force "$COPY" 2>&1
case "$mode" in
  unlanded) printf 'paused only\n' > "$COPY/paused.txt"; git -C "$COPY" add paused.txt; git -C "$COPY" commit -qm paused ;;
  leased) th lease "$(basename "$(dirname "$COPY")")" --lease-holder original-holder >/dev/null 2>&1 ;;
esac
H0=$(git -C "$COPY" rev-parse HEAD)
printf 'kind=scout\nworktree=%s\nproject=%s\n' "$COPY" "$PROJECT" > "$MATE/state/paused-scout.meta"
printf 'paused record (in another home): kind=scout worktree=%s\n' "$COPY"
printf 'origin/main=%s copyHEAD=%s\n' "$(git -C "$PROJECT" rev-parse origin/main)" "$H0"
snapshot 'BEFORE spawn' "$COPY"
brief "$ID"
out=$("$SRC/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout 2>&1); rc=$?
RW=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$ID.meta" 2>/dev/null)
printf '$ bin/fm-spawn.sh %s $LAB/project --scout\n%s\nexit=%s\nnew task worktree=%s\n' "$ID" "$out" "$rc" "$RW"
snapshot 'AFTER spawn' "$COPY"
if [ "$name" = patched ]; then
  check 'spawn launched' [ "$rc" = 0 ]
  check 'new task did not take the recorded copy' [ "$RW" != "$COPY" ]
  check 'recorded copy HEAD unchanged' [ "$(git -C "$COPY" rev-parse HEAD)" = "$H0" ]
  want=paused-scout; [ "$mode" = leased ] && want=original-holder
  check "recorded copy lease holder is $want" [ "$(th status --json | jq -r --arg n "$(basename "$(dirname "$COPY")")" '.[]|select(.name==$n)|.lease_holder')" = "$want" ]
  brief "$ID-next"
  out=$("$SRC/bin/fm-spawn.sh" "$ID-next" "$PROJECT" --scout 2>&1); rc=$?
  NW=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$ID-next.meta")
  printf '$ next spawn exit=%s worktree=%s\n' "$rc" "$NW"
  check 'next spawn also avoids it' [ "$NW" != "$COPY" ] && [ "$NW" != "$RW" ]
  check 'recorded copy HEAD still unchanged' [ "$(git -C "$COPY" rev-parse HEAD)" = "$H0" ]
else
  printf 'observed: new task copy %s recorded copy\n' "$([ "$RW" = "$COPY" ] && echo REUSED || echo avoided)"
fi
printf 'RESULT %s/%s fails=%s\n' "$name" "$mode" "${FAILS:-0}"
