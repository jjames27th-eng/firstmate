#!/usr/bin/env bash
# paired.sh <unpatched|patched> <src-root>: real fm-spawn + real tmux + real Treehouse + bounded outside writer.
. "$(dirname "$0")/lib.sh"
name=$1 SRC=$2; ID="proof-$name"
new_lab; trap stop_lab EXIT
printf '=== %s source=%s\n' "$name" "$3"
printf 'treehouse %s\n' "$(treehouse --version)"
printf 'tmux socket under private lab dir; project/pool/home all under $LAB; HOME=$LAB/userhome\n'
brief "$ID"
start_writer "$ID"
out=$("$SRC/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout 2>&1); rc=$?
wait "$WRITER"
printf '$ bin/fm-spawn.sh %s $LAB/project --scout\n%s\nspawn_exit=%s\n' "$ID" "$out" "$rc"
cat "$LAB/writer.$ID"
COPY=$(sed -n 's/^path=//p' "$LAB/writer.$ID")
HEAD0=$(git -C "$COPY" rev-parse HEAD)
check 'spawn refused the dirty copy with exit 1' [ "$rc" = 1 ]
check 'refusal says the copy is not clean' grep -q 'is not clean' <<<"$out"
check 'refusal published no task record' [ ! -e "$FM_HOME/state/$ID.meta" ]
snapshot 'BEFORE shell exit' "$COPY"
T send-keys -t "firstmate:fm-$ID" exit Enter
wait_pane "firstmate:fm-$ID" 'Clean worktree and return|Not returning' 15
sleep 0.5
printf -- '--- pane after typing exit:\n'; T capture-pane -p -J -t "firstmate:fm-$ID" | grep -v '^$' | tail -8
T send-keys -t "firstmate:fm-$ID" Enter
sleep 2
printf -- '--- pane after one empty Enter:\n'; T capture-pane -p -J -t "firstmate:fm-$ID" | grep -v '^$' | tail -10
snapshot 'AFTER shell exit plus empty Enter' "$COPY"
if [ "$name" = patched ]; then
  check 'edit survives shell exit plus empty Enter' grep -q 'outside writer edit' "$COPY/README.md"
  check 'HEAD unchanged after exit plus Enter' [ "$(git -C "$COPY" rev-parse HEAD)" = "$HEAD0" ]
  check 'durable lease retained after exit' [ "$(th status --json | jq -r --arg p "$(basename "$(dirname "$COPY")")" '.[]|select(.name==$p)|.status')" = leased ]
else
  check 'bug reproduced: empty Enter discarded the edit' bash -c '! grep -q "outside writer edit" "$1"' _ "$COPY/README.md"
fi
# Leave the outer project shell so the retry can create its endpoint.
T send-keys -t "firstmate:fm-$ID" exit Enter; sleep 1
T list-windows -t firstmate | sed 's/^/window: /'
out=$("$SRC/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout 2>&1); rc=$?
printf '$ RETRY bin/fm-spawn.sh %s $LAB/project --scout\n%s\nretry_exit=%s\n' "$ID" "$out" "$rc"
RW=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$ID.meta"); printf 'retry worktree=%s\n' "$RW"
check 'retry launched' [ "$rc" = 0 ]
snapshot 'REFUSED COPY after retry' "$COPY"
if [ "$name" = patched ]; then
  check 'retry uses a different copy' [ "$RW" != "$COPY" ]
  check 'edit survives the retry' grep -q 'outside writer edit' "$COPY/README.md"
  # Adversarial: other actors cannot reclaim it.
  printf '$ treehouse prune\n'; th prune 2>&1
  printf '$ treehouse return <copy> (no --force, no holder)\n'; th return "$COPY" </dev/null 2>&1; printf 'return_exit=%s\n' $?
  check 'edit survives prune and plain return' grep -q 'outside writer edit' "$COPY/README.md"
  snapshot 'REFUSED COPY after prune and plain return' "$COPY"
  brief proof-other
  out=$("$SRC/bin/fm-spawn.sh" proof-other "$PROJECT" --scout 2>&1); rc=$?
  OW=$(sed -n 's/^worktree=//p' "$FM_HOME/state/proof-other.meta")
  printf '$ another task bin/fm-spawn.sh proof-other\nexit=%s\n%s\nworktree=%s\n' "$rc" "$out" "$OW"
  check 'another task also avoids the refused copy' [ "$OW" != "$COPY" ]
  # Explicit release is the one way back, using the exact printed recovery.
  printf '$ (cd $LAB/project && treehouse return --force <copy>)\n'; th return --force "$COPY" 2>&1; printf 'release_exit=%s\n' $?
  snapshot 'REFUSED COPY after explicit release' "$COPY"
  check 'explicit release discards the edit' bash -c '! grep -q "outside writer edit" "$1"' _ "$COPY/README.md"
  brief proof-after-release
  out=$("$SRC/bin/fm-spawn.sh" proof-after-release "$PROJECT" --scout 2>&1); rc=$?
  AW=$(sed -n 's/^worktree=//p' "$FM_HOME/state/proof-after-release.meta")
  printf '$ next task bin/fm-spawn.sh proof-after-release\nexit=%s\nworktree=%s\n' "$rc" "$AW"
  check 'released copy is reusable by the next spawn' [ "$AW" = "$COPY" ]
else
  check 'bug reproduced: retry reuses the refused copy' [ "$RW" = "$COPY" ]
fi
printf 'RESULT %s fails=%s\n' "$name" "${FAILS:-0}"
