#!/usr/bin/env bash
# herdr.sh <unpatched|patched> <src>: second acquisition path, real Herdr lab + real Treehouse.
WORK=$REDACTED_PATH
export TMPDIR="$WORK/.test-tmp" TZ=UTC BASH_SILENCE_DEPRECATION_WARNING=1
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
name=$1 SRC=$2
LAB=$(cd "$(mktemp -d "$TMPDIR/$LAB")" && pwd -P)
HELPER=$WORK/bin/fm-herdr-lab.sh
S=$("$HELPER" name rec-$name) || exit 9
export HERDR_SESSION=$S FM_HOME="$LAB/home" FM_SPAWN_NO_GUARD=1
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
PROJECT=$LAB/project
cleanup() {
  "$HELPER" teardown "$S" 2>&1 | tail -2
  local p; p=$(ps -axo pid=,command= | grep -F "$LAB/" | grep -v grep | awk '{print $1}'); [ -z "$p" ] || kill $p 2>/dev/null; sleep 1
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB" /tmp/fm-hrec* /tmp/fm-hdirty* 2>/dev/null
}
trap cleanup EXIT
"$HELPER" provision "$S" >/dev/null || { echo provision failed; exit 9; }
"$WORK/bin/fm-lab-home.sh" create "$FM_HOME" >/dev/null
printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
printf 'codex\n' > "$FM_HOME/config/crew-harness"
touch "$FM_HOME/state/.last-watcher-beat"
git init -q --bare -b main "$LAB/origin.git"; git init -q -b main "$PROJECT"
printf 'base\n' > "$PROJECT/README.md"; printf 'root = "%s"\n' "$LAB/pool" > "$PROJECT/treehouse.toml"
git -C "$PROJECT" add .; git -C "$PROJECT" commit -qm base; git -C "$PROJECT" remote add origin "$LAB/origin.git"; git -C "$PROJECT" push -q -u origin main; git -C "$PROJECT" remote set-head origin main 2>/dev/null
th() { (cd "$PROJECT" && treehouse "$@"); }
check() { local d=$1; shift; if "$@"; then printf 'CHECK PASS: %s\n' "$d"; else printf 'CHECK FAIL: %s\n' "$d"; FAILS=$((${FAILS:-0}+1)); fi; }
stat() { th status --json | jq -c '.[] | {name,status,lease_holder}'; }
brief() { mkdir -p "$FM_HOME/data/$1"; printf '# Task\n## Captain'"'"'s intent\nscratch\n\n## Firstmate spec\nnone\n' > "$FM_HOME/data/$1/brief.md"; }
spawn() { local id=$1; brief "$id"; "$SRC/bin/fm-spawn.sh" "$id" "$PROJECT" "sh -c 'echo ok; sleep 300'" --mode no-mistakes --yolo off --backend herdr 2>&1; }
printf '=== herdr %s treehouse=%s herdr=%s session=fm-lab-*\n' "$name" "$(treehouse --version)" "$(herdr --version)"
# A: clean unleased copy at origin/main recorded by a paused task in another home.
MATE="$LAB/mate"; mkdir -p "$MATE/state" "$MATE/data"
printf '%s\n' "- mate - secondmate (home: $MATE; scope: project; projects: project; added 2026-10-24)" > "$FM_HOME/data/secondmates.md"
COPY=$(th get --lease --lease-holder setup 2>/dev/null); th return --force "$COPY" 2>&1
printf 'kind=scout\nworktree=%s\nproject=%s\n' "$COPY" "$PROJECT" > "$MATE/state/paused-scout.meta"
printf 'recorded copy=%s HEAD=%s origin/main=%s\n' "$COPY" "$(git -C "$COPY" rev-parse HEAD)" "$(git -C "$PROJECT" rev-parse origin/main)"
stat
out=$(spawn hrec1); rc=$?
RW=$(sed -n 's/^worktree=//p' "$FM_HOME/state/hrec1.meta" 2>/dev/null)
printf '$ fm-spawn hrec1 --backend herdr\n%s\nexit=%s\nworktree=%s\n' "$out" "$rc" "$RW"; grep -E '^(backend|window)=' "$FM_HOME/state/hrec1.meta"
stat
if [ "$name" = unpatched ]; then
  printf 'observed: herdr task copy %s recorded copy\n' "$([ "$RW" = "$COPY" ] && echo REUSED || echo avoided)"
  exit 0
fi
check 'fresh Herdr spawn launched (no double-lease abort)' [ "$rc" = 0 ]
check 'Herdr task avoided the recorded copy' [ "$RW" != "$COPY" ]
check 'recorded copy leased to its paused task' [ "$(th status --json | jq -r --arg n "$(basename "$(dirname "$COPY")")" '.[]|select(.name==$n)|.lease_holder')" = paused-scout ]
check 'Herdr task holds its own lease once' [ "$(th status --json | jq -r --arg n "$(basename "$(dirname "$RW")")" '.[]|select(.name==$n)|.lease_holder')" = hrec1 ]
check 'slot-owner claim written for Herdr task' grep -qx 'task=hrec1' "$(dirname "$RW")/.fm-slot-owner"
# B: dirty refusal on the Herdr path: outside writer edits the just-leased copy.
# PATH shim runs the real unmodified Treehouse, then plays the outside writer the
# moment `get --lease` hands the copy back, before fm-spawn's clean check.
REAL_TH=$(command -v treehouse); mkdir -p "$LAB/shim"
cat > "$LAB/shim/treehouse" <<SH
#!/usr/bin/env bash
out=\$("$REAL_TH" "\$@"); rc=\$?
printf '%s\\n' "\$out"
if [ "\$1 \$2" = "get --lease" ] && [ -n "\${FM_LAB_DIRTY_ID:-}" ] && [ "\$4" = "\$FM_LAB_DIRTY_ID" ]; then
  printf 'outside writer edit %s\\n' "\$4" >> "\$out/README.md"; printf '%s\\n' "\$out" > "$LAB/w.\$4"
fi
exit \$rc
SH
chmod +x "$LAB/shim/treehouse"
ID=hdirty; won=0
out=$(PATH="$LAB/shim:$PATH" FM_LAB_DIRTY_ID=$ID spawn "$ID"); rc=$?
printf '$ fm-spawn %s --backend herdr (outside writer edits after get --lease)\n%s\nexit=%s\n' "$ID" "$out" "$rc"
if [ "$rc" != 0 ] && grep -q 'is not clean' <<<"$out"; then won=1; fi
check 'outside writer produced a dirty refusal on Herdr path' [ "$won" = 1 ]
if [ "$won" = 1 ]; then
  D=$(cat "$LAB/w.$ID"); stat
  printf 'refused copy HEAD=%s\n' "$(git -C "$D" rev-parse HEAD)"; git -C "$D" status --short; cat "$D/README.md"
  check 'Herdr refusal keeps the edit' grep -q 'outside writer edit' "$D/README.md"
  check 'Herdr refusal keeps the lease' [ "$(th status --json | jq -r --arg n "$(basename "$(dirname "$D")")" '.[]|select(.name==$n)|.status')" = leased ]
  check 'Herdr refusal names explicit release' grep -q 'treehouse return --force' <<<"$out"
  out=$(spawn "$ID"); rc=$?
  RT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$ID.meta" 2>/dev/null)
  printf '$ RETRY fm-spawn %s\nexit=%s\nworktree=%s\n%s\n' "$ID" "$rc" "$RT" "$out"; stat
  check 'Herdr retry launched' [ "$rc" = 0 ]
  check 'Herdr retry uses a different copy' [ -n "$RT" ] && [ "$RT" != "$D" ]
  check 'edit still intact after Herdr retry' grep -q 'outside writer edit' "$D/README.md"
fi
printf 'RESULT herdr fails=%s\n' "${FAILS:-0}"
