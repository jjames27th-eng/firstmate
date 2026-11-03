#!/usr/bin/env bash
# Disposable loopback T3 server, scratch base dir, scratch HOME, scratch credential.
. "$(dirname "$0")/lib.sh"
SRC=$1; T3="$WORK/.test-tmp/t3/node_modules/.bin/t3"
new_lab; PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
SP=
cleanup() { [ -z "$SP" ] || kill "$SP" 2>/dev/null; sleep 1; stop_lab; rm -rf /tmp/fm-t3rec* 2>/dev/null; }
trap cleanup EXIT
printf '=== t3 %s treehouse=%s\n' "$("$T3" --version)" "$(treehouse --version)"
(cd "$PROJECT" && T3CODE_TELEMETRY_ENABLED=false exec "$T3" serve --host 127.0.0.1 --port "$PORT" --no-browser --base-dir "$LAB/t3base" --auto-bootstrap-project-from-cwd > "$LAB/t3.log" 2>&1) & SP=$!
for i in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 1; done
export PATH="$(dirname "$T3"):$PATH" FM_T3CODE_ORIGIN="http://127.0.0.1:$PORT"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  "$WORK/bin/fm-t3-mcp.mjs" login --url "http://127.0.0.1:$PORT" --access full-access --t3 "$T3" --base-dir "$LAB/t3base" > "$LAB/login.out" 2>&1; lrc=$?
  [ "$lrc" = 0 ] && break; grep -q 'HTTP 503' "$LAB/login.out" || break; sleep 5
done
cut -c1-300 "$LAB/login.out"; echo "login exit=$lrc attempts=$i"
"$WORK/bin/fm-t3-mcp.mjs" status 2>&1 | cut -c1-300
printf 'claude\n' > "$FM_HOME/config/crew-harness"
MATE="$LAB/mate"; mkdir -p "$MATE/state" "$MATE/data"
printf '%s\n' "- mate - secondmate (home: $MATE; scope: project; projects: project; added 2026-10-24)" > "$FM_HOME/data/secondmates.md"
COPY=$(th get --lease --lease-holder setup 2>/dev/null); th return --force "$COPY" 2>&1
printf 'kind=scout\nworktree=%s\nproject=%s\n' "$COPY" "$PROJECT" > "$MATE/state/paused-scout.meta"
printf 'recorded copy HEAD=%s origin/main=%s\n' "$(git -C "$COPY" rev-parse HEAD)" "$(git -C "$PROJECT" rev-parse origin/main)"
ID=t3rec1; brief "$ID"
out=$("$SRC/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout --backend t3code 2>&1); rc=$?
RW=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$ID.meta" 2>/dev/null)
printf '$ fm-spawn %s --scout --backend t3code\n%s\nexit=%s\nworktree=%s\n' "$ID" "$out" "$rc" "$RW"
grep -E '^(backend|t3_thread_id)=' "$FM_HOME/state/$ID.meta" 2>/dev/null
th status --json | jq -c '.[] | {name,status,lease_holder}'
check 'T3 spawn launched (no double-lease abort)' [ "$rc" = 0 ]
check 'T3 task avoided the recorded copy' [ -n "$RW" ] && [ "$RW" != "$COPY" ]
check 'recorded copy leased to paused task' [ "$(th status --json | jq -r --arg n "$(basename "$(dirname "$COPY")")" '.[]|select(.name==$n)|.lease_holder')" = paused-scout ]
[ -n "$RW" ] && check 'T3 task holds the lease on its copy' [ "$(th status --json | jq -r --arg n "$(basename "$(dirname "$RW")")" '.[]|select(.name==$n)|.lease_holder')" = "$ID" ]
[ -n "$RW" ] && check 'slot-owner claim written for T3 task' grep -qx "task=$ID" "$(dirname "$RW")/.fm-slot-owner"
printf 'RESULT t3 fails=%s\n' "${FAILS:-0}"
tail -5 "$LAB/t3.log" | cut -c1-200
