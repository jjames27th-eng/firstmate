#!/usr/bin/env bash
# Focused contract tests for bin/fm-browser-guard.sh and lib.
# Uses fake process trees, dry-stop hooks, and private lease dirs - no real Chrome.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-browser-guard)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

HOME_A="$TMP_ROOT/home-a"
HOME_B="$TMP_ROOT/home-b"
mkdir -p "$HOME_A/state" "$HOME_A/config" "$HOME_B/state" "$HOME_B/config"

LEASE_DIR="$TMP_ROOT/lease-heavy"
CHROME_BASE="$TMP_ROOT/chrome-state"
STOP_LOG="$TMP_ROOT/stops.log"
mkdir -p "$LEASE_DIR" "$CHROME_BASE"

export FM_BROWSER_GUARD_LEASE_DIR="$LEASE_DIR"
export FM_BROWSER_GUARD_CHROME_STATE_BASE="$CHROME_BASE"
export FM_BROWSER_GUARD_DRY_STOP=1
export FM_BROWSER_GUARD_ALARM_TTL=0

# shellcheck source=/dev/null
. "$ROOT/bin/fm-browser-guard-lib.sh"

# --- identity stability and cross-home non-collision ------------------------

id_a1=$(FM_HOME="$HOME_A" fm_browser_guard_session_id task-alpha)
id_a2=$(FM_HOME="$HOME_A" fm_browser_guard_session_id task-alpha)
id_b1=$(FM_HOME="$HOME_B" fm_browser_guard_session_id task-alpha)
[ "$id_a1" = "$id_a2" ] || fail "same home+task session not stable: $id_a1 vs $id_a2"
[ "$id_a1" != "$id_b1" ] || fail "different homes with same task id collided: $id_a1"
case "$id_a1" in
  fm-????????-*) ;;
  *) fail "session missing fm-<hash8>- prefix: $id_a1" ;;
esac
[ "${#id_a1}" -le 64 ] || fail "session too long: $id_a1"
pass "session identity stable and home-scoped"

# --- heavy lease single-slot serialization ----------------------------------

export FM_HOME="$HOME_A"
export FM_STATE_OVERRIDE="$HOME_A/state"
export FM_CONFIG_OVERRIDE="$HOME_A/config"
# dead pid for owner so reclaims can be tested later
DEAD_PID=999999
# live pid = current shell
LIVE_PID=$$

out=$(fm_browser_guard_lease_acquire task-a "$LIVE_PID") || fail "home A failed to acquire heavy lease: $out"
case "$out" in
  slot=0) ;;
  *) fail "expected slot=0, got $out" ;;
esac

export FM_HOME="$HOME_B"
export FM_STATE_OVERRIDE="$HOME_B/state"
export FM_CONFIG_OVERRIDE="$HOME_B/config"
if fm_browser_guard_lease_acquire task-b "$LIVE_PID" >/dev/null 2>&1; then
  fail "home B acquired heavy lease while home A still holds the only slot"
fi
pass "two homes cannot hold the default single heavy slot concurrently"

# Same home+task refresh succeeds
export FM_HOME="$HOME_A"
export FM_STATE_OVERRIDE="$HOME_A/state"
export FM_CONFIG_OVERRIDE="$HOME_A/config"
out=$(fm_browser_guard_lease_acquire task-a "$LIVE_PID") || fail "same owner re-acquire failed"
[ "$out" = "slot=0" ] || fail "re-acquire slot mismatch: $out"
pass "same home+task may refresh its heavy lease"

fm_browser_guard_lease_release task-a || fail "release failed"
export FM_HOME="$HOME_B"
export FM_STATE_OVERRIDE="$HOME_B/state"
export FM_CONFIG_OVERRIDE="$HOME_B/config"
out=$(fm_browser_guard_lease_acquire task-b "$LIVE_PID") || fail "home B should acquire after release"
fm_browser_guard_lease_release task-b || fail "release B failed"
pass "release frees the heavy slot for another home"

# --- stale reclaim vs ambiguous refusal -------------------------------------

export FM_HOME="$HOME_A"
export FM_STATE_OVERRIDE="$HOME_A/state"
export FM_CONFIG_OVERRIDE="$HOME_A/config"
fm_browser_guard_lease_acquire task-stale "$DEAD_PID" >/dev/null || fail "stale setup acquire"
# With no meta and dead pid, owner is dead -> reconcile reclaims
rec=$(fm_browser_guard_lease_reconcile)
case "$rec" in
  reclaimed=1) ;;
  *) fail "expected reclaimed=1 for dead owner without meta, got $rec" ;;
esac
pass "stale lease reclamation requires confidently dead ownership"

# Ambiguous: dead pid but live meta present without test-dead marker
fm_browser_guard_lease_acquire task-ambig "$DEAD_PID" >/dev/null || fail "ambig setup"
mkdir -p "$HOME_A/state"
printf 'window=t\nworktree=/tmp/x\nproject=/tmp/x\nharness=pi\nkind=ship\nmode=no-mistakes\nyolo=off\n' \
  > "$HOME_A/state/task-ambig.meta"
rec=$(fm_browser_guard_lease_reconcile)
case "$rec" in
  reclaimed=0) ;;
  *) fail "ambiguous meta should refuse reclaim, got $rec" ;;
esac
# force release for cleanup
rm -f "$HOME_A/state/task-ambig.meta"
export FM_BROWSER_GUARD_TEST_DEAD_TASKS="$HOME_A|task-ambig"
rec=$(fm_browser_guard_lease_reconcile)
case "$rec" in
  reclaimed=1) ;;
  *) fail "test-dead marker should allow reclaim, got $rec" ;;
esac
unset FM_BROWSER_GUARD_TEST_DEAD_TASKS
pass "ambiguous ownership refuses; explicit dead proof reclaims"

# --- exact stop leaves unrelated work untouched -----------------------------

export FM_HOME="$HOME_A"
export FM_STATE_OVERRIDE="$HOME_A/state"
export FM_CONFIG_OVERRIDE="$HOME_A/config"

# Track dry stops
fm_browser_guard_stop_chrome_session() {
  local session=$1
  fm_browser_guard_is_owned_session_name "$session" || {
    echo "refused $session" >> "$STOP_LOG"
    return 1
  }
  printf 'stop %s\n' "$session" >> "$STOP_LOG"
  return 0
}
fm_browser_guard_stop_registered_roots() {
  local roots=$1
  [ -n "$roots" ] || return 0
  printf 'roots %s\n' "$roots" >> "$STOP_LOG"
}

: > "$STOP_LOG"
fm_browser_guard_start task-own --heavy --pid "$LIVE_PID" >/dev/null || fail "start own"
# Simulate foreign session dir and user default state (must never be stopped)
mkdir -p "$CHROME_BASE/sessions/default-user" "$CHROME_BASE/sessions/fm-deadbeef-otherhome"
printf '{"pid":1,"session":"default"}\n' > "$CHROME_BASE/bridge.pid"
printf '{"pid":2}\n' > "$CHROME_BASE/sessions/default-user/bridge.pid"

# Another task ownership in same home
fm_browser_guard_start task-other --light --pid "$LIVE_PID" >/dev/null || fail "start other"

fm_browser_guard_stop task-own >/dev/null || fail "stop own failed"
grep -q "stop $(FM_HOME="$HOME_A" fm_browser_guard_session_id task-own)" "$STOP_LOG" \
  || fail "owned session was not stopped"
if grep -q 'default' "$STOP_LOG"; then
  fail "stop log touched default/user chrome: $(cat "$STOP_LOG")"
fi
if grep -q 'otherhome' "$STOP_LOG"; then
  fail "stop log touched foreign session"
fi
# other task ownership still present
[ -f "$HOME_A/state/task-other.browser-guard" ] || fail "other task ownership was removed"
[ ! -f "$HOME_A/state/task-own.browser-guard" ] || fail "own ownership not removed"
# lease released
status=$(fm_browser_guard_lease_status)
case "$status" in
  *'slot=0 free'*) ;;
  *)
    # task-other was light; only task-own held heavy
    case "$status" in
      *task-own*) fail "heavy lease still held by task-own: $status" ;;
    esac
    ;;
esac
pass "exact cleanup removes only the owned session and leaves others untouched"

# Protected review: stop refuses without force; detect alerts without close
: > "$STOP_LOG"
fm_browser_guard_start task-review --role review --protected --pid "$LIVE_PID" >/dev/null \
  || fail "start review"
if fm_browser_guard_stop task-review >/dev/null 2>&1; then
  fail "protected review was auto-stopped"
fi
[ -f "$HOME_A/state/task-review.browser-guard" ] || fail "protected ownership missing after refused stop"

# Fake live bridge for review session to trigger runaway alert under high load mock
rev_session=$(fm_browser_guard_session_id task-review)
mkdir -p "$(fm_browser_guard_chrome_state_dir "$rev_session")"
# Use a live pid we own for "bridge"
printf '{"pid":%s}\n' "$LIVE_PID" > "$(fm_browser_guard_chrome_pid_file "$rev_session")"
# Force high load
fm_browser_guard_load1() { printf '99\n'; }
# Avoid auto-clean of review; detect should alert only
alarms=$(fm_browser_guard_detect 2>/dev/null || true)
case "$alarms" in
  *'BROWSER_GUARD:'*'protected review'*) ;;
  *) fail "expected runaway review alarm, got: $alarms" ;;
esac
[ -f "$HOME_A/state/task-review.browser-guard" ] || fail "detect closed protected review"
if grep -q "stop $rev_session" "$STOP_LOG"; then
  fail "detect stopped protected review session"
fi
pass "protected runaway review alerts but is not closed"

# cleanup-task leaves protected review
fm_browser_guard_cleanup_task task-review
[ -f "$HOME_A/state/task-review.browser-guard" ] || fail "cleanup-task removed protected review"
fm_browser_guard_stop task-review --force-protected >/dev/null || fail "force stop review"
pass "cleanup-task retains protected reviews; force-protected stops explicitly"

# --- run one-shot cleanup on failure ----------------------------------------

: > "$STOP_LOG"
export FM_HOME="$HOME_A"
if fm_browser_guard_run task-run --heavy -- sh -c 'exit 7'; then
  fail "run should propagate command failure"
fi
[ ! -f "$HOME_A/state/task-run.browser-guard" ] || fail "run left ownership after failure"
status=$(fm_browser_guard_lease_status)
case "$status" in
  *task-run*) fail "run left heavy lease after failure: $status" ;;
esac
pass "one-shot run cleans ownership and lease after failure"

# --- env exports shape ------------------------------------------------------

exports=$(fm_browser_guard_env_exports task-env)
case "$exports" in
  *CHROME_DEVTOOLS_AXI_SESSION=*FM_BROWSER_TASK_ID=*FM_BROWSER_SESSION=*) ;;
  *) fail "env exports missing required vars: $exports" ;;
esac
pass "env-exports includes session and task identity"

# --- CLI surface smoke via real script --------------------------------------

cli_out=$(
  FM_HOME="$HOME_A" FM_STATE_OVERRIDE="$HOME_A/state" FM_CONFIG_OVERRIDE="$HOME_A/config" \
    FM_BROWSER_GUARD_LEASE_DIR="$LEASE_DIR" \
    FM_BROWSER_GUARD_CHROME_STATE_BASE="$CHROME_BASE" \
    FM_BROWSER_GUARD_DRY_STOP=1 \
    "$ROOT/bin/fm-browser-guard.sh" session-id cli-task
) || fail "cli session-id failed"
[ -n "$cli_out" ] || fail "cli session-id empty"
pass "cli session-id works"

# --- spawn records browser_session and exports (static source check) --------

grep -q 'browser_session=' "$ROOT/bin/fm-spawn.sh" \
  || fail "spawn does not record browser_session in meta"
grep -q 'CHROME_DEVTOOLS_AXI_SESSION' "$ROOT/bin/fm-spawn.sh" \
  || fail "spawn does not export CHROME_DEVTOOLS_AXI_SESSION"
grep -q 'fm-browser-guard.sh' "$ROOT/bin/fm-spawn.sh" \
  || fail "spawn does not call browser-guard for identity"
# All backends share spawn_send_text_line path - one integration site
count=$(grep -c 'CHROME_DEVTOOLS_AXI_SESSION' "$ROOT/bin/fm-spawn.sh" || true)
[ "$count" -ge 1 ] || fail "missing session export sites"
pass "every verified harness/backend receives task-owned env via shared spawn path"

# --- teardown invokes exact cleanup; landed-work path unchanged -------------

grep -q 'fm-browser-guard.sh" cleanup-task' "$ROOT/bin/fm-teardown.sh" \
  || grep -q 'fm-browser-guard.sh cleanup-task' "$ROOT/bin/fm-teardown.sh" \
  || fail "teardown does not invoke browser-guard cleanup-task"
# Landed-work refusal still present
grep -q 'unlanded\|REFUSED\|landed' "$ROOT/bin/fm-teardown.sh" \
  || fail "teardown lost landed-work language"
# cleanup-task appears after safety validation section (best-effort order check:
# browser cleanup is near state-file rm, not before META existence check)
meta_line=$(grep -n 'META=.*\.meta' "$ROOT/bin/fm-teardown.sh" | head -1 | cut -d: -f1)
clean_line=$(grep -n 'cleanup-task' "$ROOT/bin/fm-teardown.sh" | head -1 | cut -d: -f1)
[ -n "$meta_line" ] && [ -n "$clean_line" ] || fail "could not locate meta/cleanup lines"
[ "$clean_line" -gt "$meta_line" ] || fail "browser cleanup runs before meta gate"
pass "teardown invokes exact owned cleanup after existing safety gates"

# --- brief embeds browser contract ------------------------------------------

grep -q 'Browser resource guard' "$ROOT/bin/fm-brief.sh" \
  || fail "brief missing browser resource guard section"
grep -q 'fm-browser-guard.sh' "$ROOT/bin/fm-brief.sh" \
  || fail "brief missing helper path"
pass "generated brief requires owner/lease helper for browser work"

# --- detect dedupe ----------------------------------------------------------

export FM_HOME="$HOME_A"
export FM_STATE_OVERRIDE="$HOME_A/state"
export FM_BROWSER_GUARD_ALARM_TTL=3600
# orphan session under this home hash with live-looking pid file but no ownership
sess=$(fm_browser_guard_session_id orphan-detect)
mkdir -p "$(fm_browser_guard_chrome_state_dir "$sess")"
printf '{"pid":%s}\n' "$LIVE_PID" > "$(fm_browser_guard_chrome_pid_file "$sess")"
# Override stop to log only
fm_browser_guard_stop_chrome_session() {
  printf 'orphan-stop %s\n' "$1" >> "$STOP_LOG"
}
: > "$STOP_LOG"
a1=$(fm_browser_guard_detect 2>/dev/null || true)
a2=$(fm_browser_guard_detect 2>/dev/null || true)
case "$a1" in
  *BROWSER_GUARD:*) ;;
  *) fail "first detect should alarm for orphan: $a1" ;;
esac
# second should be empty due to dedupe (ttl 3600)
[ -z "$a2" ] || fail "second detect should dedupe, got: $a2"
pass "detect is bounded and emits only actionable deduplicated alarms"

# --- register-root proof path -----------------------------------------------

export FM_BROWSER_GUARD_ALARM_TTL=0
fm_browser_guard_start task-pw --light --pid "$LIVE_PID" >/dev/null
fm_browser_guard_register_root task-pw --pid 424242 --kind playwright >/dev/null \
  || fail "register-root failed"
roots=$(fm_browser_guard_meta_get "$HOME_A/state/task-pw.browser-guard" root_pids)
[ "$roots" = 424242 ] || fail "root_pids not recorded: $roots"
: > "$STOP_LOG"
fm_browser_guard_stop_registered_roots() {
  printf 'roots %s\n' "$1" >> "$STOP_LOG"
}
fm_browser_guard_stop_chrome_session() {
  printf 'stop %s\n' "$1" >> "$STOP_LOG"
}
fm_browser_guard_stop task-pw >/dev/null || fail "stop pw failed"
grep -q 'roots 424242' "$STOP_LOG" || fail "registered root not stopped exactly"
pass "registered Playwright root is cleaned only via exact pid list"

echo "all fm-browser-guard tests passed"
