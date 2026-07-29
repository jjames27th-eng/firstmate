#!/usr/bin/env bash
# bin/fm-browser-guard-lib.sh - Firstmate-owned browser workload identity,
# machine-wide heavy lease, exact session cleanup, and cheap detection.
#
# ONE owner of the browser resource-guard contract. Callers source this after
# resolving FM_HOME / FM_ROOT / STATE / CONFIG (or accept the defaults below).
# Exact CLI verbs live in bin/fm-browser-guard.sh; this file is the reusable
# implementation so tests and teardown can call the same proofs.
#
# Safety invariants (never relax):
#   - Never broad process matching, never pkill -f, never user-Chrome sweeps.
#   - Cleanup requires home + task + session (+ optional registered root) proof.
#   - Ambiguous ownership refuses; only confidently dead owners are reclaimed.
#   - Protected captain reviews alert only; automatic action never closes them.
#   - Captain-launched / non-task browsers stay on the chrome-devtools default.
#
# Private ownership evidence: state/<task-id>.browser-guard (key=value lines).
# Machine-wide heavy lease: /tmp/firstmate-browser-guard-<uid>/heavy/slot-N
# (override with FM_BROWSER_GUARD_LEASE_DIR for tests).
# Optional config/browser-heavy-slots: positive integer, default 1.
# Optional registered Playwright roots: root_pids= in the ownership record.
# Optional protected reviews: role=review protected=1 in the ownership record.

# shellcheck disable=SC2034 # Sourced library; callers read many of these.

FM_BROWSER_GUARD_SESSION_PREFIX="fm"
FM_BROWSER_GUARD_MAX_SESSION_LEN=64
FM_BROWSER_GUARD_META_SUFFIX=".browser-guard"
FM_BROWSER_GUARD_ALARM_PREFIX="BROWSER_GUARD:"

fm_browser_guard_log() {
  echo "fm-browser-guard: $*" >&2
}

fm_browser_guard_error() {
  fm_browser_guard_log "$*"
  return 1
}

# --- path / identity helpers ------------------------------------------------

fm_browser_guard_home_real() {
  local home=${1:-${FM_HOME:-}}
  [ -n "$home" ] || return 1
  (cd "$home" 2>/dev/null && pwd -P)
}

fm_browser_guard_hash8() {
  local input=$1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$input" | shasum -a 256 | awk '{print substr($1,1,8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$input" | sha256sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$input" | cksum | awk '{printf "%08x", $1}'
  fi
}

# fm_browser_guard_sanitize_task_id <task-id>
# Map a task id into the chrome-devtools session charset [A-Za-z0-9._-].
fm_browser_guard_sanitize_task_id() {
  local raw=$1 out
  out=$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '-' | tr -s '-')
  out=${out#-}
  out=${out%-}
  [ -n "$out" ] || out=task
  printf '%s' "$out"
}

# fm_browser_guard_session_id <task-id> [home]
# Stable collision-resistant chrome-devtools session for this home+task.
# Shape: fm-<homehash8>-<sanitized-task> capped at 64 chars.
fm_browser_guard_session_id() {
  local task=$1 home=${2:-} home_real hash task_part max_task session
  [ -n "$task" ] || return 1
  if [ -z "$home" ]; then
    home=${FM_HOME:-}
  fi
  home_real=$(fm_browser_guard_home_real "$home") || home_real=$home
  [ -n "$home_real" ] || return 1
  hash=$(fm_browser_guard_hash8 "$home_real")
  task_part=$(fm_browser_guard_sanitize_task_id "$task")
  # "fm-" + 8 + "-" = 12 prefix chars.
  max_task=$((FM_BROWSER_GUARD_MAX_SESSION_LEN - 12))
  [ "$max_task" -ge 1 ] || return 1
  if [ "${#task_part}" -gt "$max_task" ]; then
    task_part=${task_part:0:max_task}
    task_part=${task_part%-}
  fi
  session="${FM_BROWSER_GUARD_SESSION_PREFIX}-${hash}-${task_part}"
  fm_browser_guard_validate_session_name "$session" || return 1
  printf '%s\n' "$session"
}

# chrome-devtools-axi session name rules (mirrored; never invent a looser set).
fm_browser_guard_validate_session_name() {
  local name=$1
  [ -n "$name" ] || return 1
  [ "${#name}" -le "$FM_BROWSER_GUARD_MAX_SESSION_LEN" ] || return 1
  case "$name" in
    default) return 1 ;;
    .*|*.|*.*) ;;
  esac
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$name" =~ ^\.+$ ]] && return 1
  return 0
}

# Refuse to operate on non-Firstmate session names for automatic cleanup.
fm_browser_guard_is_owned_session_name() {
  local name=$1 prefix
  fm_browser_guard_validate_session_name "$name" || return 1
  prefix="${FM_BROWSER_GUARD_SESSION_PREFIX}-"
  case "$name" in
    "$prefix"*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_browser_guard_ownership_path() {
  local task=$1
  local state=${FM_STATE_OVERRIDE:-${STATE:-${FM_HOME:-}/state}}
  printf '%s/%s%s' "$state" "$task" "$FM_BROWSER_GUARD_META_SUFFIX"
}

fm_browser_guard_meta_get() {
  local path=$1 key=$2 line
  [ -f "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*)
        printf '%s\n' "${line#*=}"
        return 0
        ;;
    esac
  done < "$path"
  return 1
}

fm_browser_guard_write_ownership() {
  # Args as key=value pairs after path.
  local path=$1
  shift
  local tmp dir
  dir=$(dirname "$path")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.browser-guard.XXXXXX") || return 1
  {
    printf 'version=1\n'
    local kv
    for kv in "$@"; do
      printf '%s\n' "$kv"
    done
  } > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$path"
}

# --- machine-wide heavy lease -----------------------------------------------

fm_browser_guard_lease_dir() {
  if [ -n "${FM_BROWSER_GUARD_LEASE_DIR:-}" ]; then
    printf '%s' "$FM_BROWSER_GUARD_LEASE_DIR"
    return 0
  fi
  local uid
  uid=$(id -u 2>/dev/null || printf '0')
  printf '/tmp/firstmate-browser-guard-%s/heavy' "$uid"
}

fm_browser_guard_heavy_slots() {
  local config=${FM_CONFIG_OVERRIDE:-${CONFIG:-${FM_HOME:-}/config}}
  local file="$config/browser-heavy-slots" raw
  if [ -f "$file" ]; then
    raw=$(tr -d '[:space:]' < "$file" 2>/dev/null || true)
    case "$raw" in
      ''|*[!0-9]*) ;;
      0) ;;
      *)
        printf '%s\n' "$raw"
        return 0
        ;;
    esac
  fi
  printf '1\n'
}

fm_browser_guard_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# Prove a lease record's owner is confidently dead for reclaim.
# Returns 0 only when reclaim is safe; 1 when live or ambiguous.
fm_browser_guard_lease_owner_dead() {
  local lease_path=$1
  local home task pid session endpoint_state meta
  home=$(fm_browser_guard_meta_get "$lease_path" home_real) || return 1
  task=$(fm_browser_guard_meta_get "$lease_path" task_id) || return 1
  pid=$(fm_browser_guard_meta_get "$lease_path" pid) || return 1
  session=$(fm_browser_guard_meta_get "$lease_path" session) || return 1
  [ -n "$home" ] && [ -n "$task" ] && [ -n "$session" ] || return 1

  if fm_browser_guard_pid_alive "$pid"; then
    return 1
  fi

  # Same home+task re-acquire: if no live ownership file and no live meta
  # endpoint, the dead pid is enough. If meta exists with a live endpoint,
  # refuse (ambiguous - another process may still own the browser work).
  meta="$home/state/${task}.meta"
  if [ -f "$meta" ]; then
    # Prefer fm_backend_agent_state when available; otherwise treat present meta
    # with unknown liveness as ambiguous unless FM_BROWSER_GUARD_TEST_DEAD_TASKS
    # lists this home/task (tests only).
    if [ -n "${FM_BROWSER_GUARD_TEST_DEAD_TASKS:-}" ]; then
      case " ${FM_BROWSER_GUARD_TEST_DEAD_TASKS} " in
        *" ${home}|${task} "*) return 0 ;;
      esac
    fi
    if command -v fm_backend_of_meta >/dev/null 2>&1 \
      && command -v fm_backend_agent_state >/dev/null 2>&1; then
      local backend window
      backend=$(fm_backend_of_meta "$meta" 2>/dev/null || true)
      window=$(grep '^window=' "$meta" 2>/dev/null | cut -d= -f2- || true)
      if [ -n "$backend" ] && [ -n "$window" ]; then
        endpoint_state=$(fm_backend_agent_state "$backend" "$window" 2>/dev/null || true)
        case "$endpoint_state" in
          dead|missing) return 0 ;;
          *) return 1 ;;
        esac
      fi
    fi
    # Meta present, cannot prove dead -> refuse.
    return 1
  fi

  # No meta: still refuse if an ownership record claims protected/live work
  # with a different pid we cannot verify. Absent ownership -> reclaim ok.
  local own="$home/state/${task}${FM_BROWSER_GUARD_META_SUFFIX}"
  if [ -f "$own" ]; then
    local own_pid own_prot
    own_pid=$(fm_browser_guard_meta_get "$own" pid 2>/dev/null || true)
    own_prot=$(fm_browser_guard_meta_get "$own" protected 2>/dev/null || true)
    if [ "$own_prot" = 1 ]; then
      return 1
    fi
    if [ -n "$own_pid" ] && fm_browser_guard_pid_alive "$own_pid"; then
      return 1
    fi
  fi
  return 0
}

fm_browser_guard_lease_slot_path() {
  local slot=$1
  printf '%s/slot-%s' "$(fm_browser_guard_lease_dir)" "$slot"
}

# fm_browser_guard_lease_status
# Prints one line per held heavy slot: slot=N home=... task=... session=... pid=...
# Exit 0 always (inspection).
fm_browser_guard_lease_status() {
  local dir slots i path home task session pid
  dir=$(fm_browser_guard_lease_dir)
  slots=$(fm_browser_guard_heavy_slots)
  mkdir -p "$dir" 2>/dev/null || true
  i=0
  while [ "$i" -lt "$slots" ]; do
    path=$(fm_browser_guard_lease_slot_path "$i")
    if [ -f "$path" ]; then
      home=$(fm_browser_guard_meta_get "$path" home_real 2>/dev/null || true)
      task=$(fm_browser_guard_meta_get "$path" task_id 2>/dev/null || true)
      session=$(fm_browser_guard_meta_get "$path" session 2>/dev/null || true)
      pid=$(fm_browser_guard_meta_get "$path" pid 2>/dev/null || true)
      printf 'slot=%s home=%s task=%s session=%s pid=%s\n' \
        "$i" "${home:-?}" "${task:-?}" "${session:-?}" "${pid:-?}"
    else
      printf 'slot=%s free\n' "$i"
    fi
    i=$((i + 1))
  done
}

# fm_browser_guard_lease_acquire <task-id> [pid]
# Acquire one heavy slot. Rejects if all slots held by live/ambiguous owners.
# Prints slot=N on success.
fm_browser_guard_lease_acquire() {
  local task=$1
  local pid=${2:-${BASHPID:-$$}}
  local home_real session dir slots i path owner_home owner_task
  home_real=$(fm_browser_guard_home_real) || {
    fm_browser_guard_error "cannot resolve FM_HOME for lease acquire"
    return 1
  }
  session=$(fm_browser_guard_session_id "$task" "$home_real") || return 1
  dir=$(fm_browser_guard_lease_dir)
  mkdir -p "$dir" || return 1
  # Private to this user.
  chmod 700 "$(dirname "$dir")" 2>/dev/null || true
  chmod 700 "$dir" 2>/dev/null || true

  slots=$(fm_browser_guard_heavy_slots)
  i=0
  while [ "$i" -lt "$slots" ]; do
    path=$(fm_browser_guard_lease_slot_path "$i")
    if [ -f "$path" ]; then
      owner_home=$(fm_browser_guard_meta_get "$path" home_real 2>/dev/null || true)
      owner_task=$(fm_browser_guard_meta_get "$path" task_id 2>/dev/null || true)
      # Same home+task already holds this slot: refresh pid and succeed.
      if [ "$owner_home" = "$home_real" ] && [ "$owner_task" = "$task" ]; then
        fm_browser_guard_write_ownership "$path" \
          "home_real=$home_real" \
          "task_id=$task" \
          "session=$session" \
          "pid=$pid" \
          "kind=heavy" \
          "slot=$i" \
          "acquired_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" \
          || return 1
        printf 'slot=%s\n' "$i"
        return 0
      fi
      if fm_browser_guard_lease_owner_dead "$path"; then
        rm -f "$path" || true
      else
        i=$((i + 1))
        continue
      fi
    fi
    # Exclusive claim via mkdir; only the winner writes the slot file.
    if mkdir "${path}.claim" 2>/dev/null; then
      if [ -f "$path" ]; then
        rmdir "${path}.claim" 2>/dev/null || true
        i=$((i + 1))
        continue
      fi
      if fm_browser_guard_write_ownership "$path" \
        "home_real=$home_real" \
        "task_id=$task" \
        "session=$session" \
        "pid=$pid" \
        "kind=heavy" \
        "slot=$i" \
        "acquired_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"; then
        rmdir "${path}.claim" 2>/dev/null || true
        printf 'slot=%s\n' "$i"
        return 0
      fi
      rmdir "${path}.claim" 2>/dev/null || true
    fi
    i=$((i + 1))
  done

  # All slots busy - diagnostic.
  fm_browser_guard_error "heavy browser lease unavailable (slots=$slots)"
  fm_browser_guard_lease_status >&2
  return 1
}

# fm_browser_guard_lease_release <task-id>
# Release only slots owned by this home+task.
fm_browser_guard_lease_release() {
  local task=$1
  local home_real dir slots i path owner_home owner_task released=0
  home_real=$(fm_browser_guard_home_real) || return 1
  dir=$(fm_browser_guard_lease_dir)
  slots=$(fm_browser_guard_heavy_slots)
  i=0
  while [ "$i" -lt "$slots" ]; do
    path=$(fm_browser_guard_lease_slot_path "$i")
    if [ -f "$path" ]; then
      owner_home=$(fm_browser_guard_meta_get "$path" home_real 2>/dev/null || true)
      owner_task=$(fm_browser_guard_meta_get "$path" task_id 2>/dev/null || true)
      if [ "$owner_home" = "$home_real" ] && [ "$owner_task" = "$task" ]; then
        rm -f "$path" && released=1
      fi
    fi
    i=$((i + 1))
  done
  # Idempotent: already free is success.
  return 0
}

# Reclaim only slots whose owners are confidently dead.
fm_browser_guard_lease_reconcile() {
  local dir slots i path reclaimed=0
  dir=$(fm_browser_guard_lease_dir)
  slots=$(fm_browser_guard_heavy_slots)
  i=0
  while [ "$i" -lt "$slots" ]; do
    path=$(fm_browser_guard_lease_slot_path "$i")
    if [ -f "$path" ] && fm_browser_guard_lease_owner_dead "$path"; then
      rm -f "$path" && reclaimed=$((reclaimed + 1))
    fi
    i=$((i + 1))
  done
  printf 'reclaimed=%s\n' "$reclaimed"
}

# --- ownership / start / stop -----------------------------------------------

# fm_browser_guard_start <task-id> [--heavy|--light] [--role disposable|review]
# [--protected] [--pid N]
fm_browser_guard_start() {
  local task=$1
  shift
  local kind=light role=disposable protected=0 pid=${BASHPID:-$$} heavy=0
  local home_real session path slot=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --heavy) heavy=1; kind=heavy; shift ;;
      --light) heavy=0; kind=light; shift ;;
      --role)
        role=${2:-}
        shift 2
        ;;
      --protected) protected=1; shift ;;
      --pid)
        pid=${2:-}
        shift 2
        ;;
      *)
        fm_browser_guard_error "unknown start flag: $1"
        return 2
        ;;
    esac
  done
  case "$role" in
    disposable|review|registered-root) ;;
    *)
      fm_browser_guard_error "invalid role: $role"
      return 2
      ;;
  esac
  if [ "$role" = review ]; then
    protected=1
  fi
  home_real=$(fm_browser_guard_home_real) || return 1
  session=$(fm_browser_guard_session_id "$task" "$home_real") || return 1
  if [ "$heavy" -eq 1 ]; then
    slot=$(fm_browser_guard_lease_acquire "$task" "$pid") || return 1
    slot=${slot#slot=}
  fi
  path=$(fm_browser_guard_ownership_path "$task")
  fm_browser_guard_write_ownership "$path" \
    "home_real=$home_real" \
    "task_id=$task" \
    "session=$session" \
    "pid=$pid" \
    "kind=$kind" \
    "role=$role" \
    "protected=$protected" \
    "slot=${slot:-}" \
    "root_pids=" \
    "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" \
    || {
      [ -n "$slot" ] && fm_browser_guard_lease_release "$task" || true
      return 1
    }
  printf 'session=%s kind=%s role=%s protected=%s slot=%s\n' \
    "$session" "$kind" "$role" "$protected" "${slot:-}"
}

fm_browser_guard_register_root() {
  local task=$1
  shift
  local pid='' kind=other path existing
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pid)
        pid=${2:-}
        shift 2
        ;;
      --kind)
        kind=${2:-other}
        shift 2
        ;;
      *)
        fm_browser_guard_error "unknown register-root flag: $1"
        return 2
        ;;
    esac
  done
  case "$pid" in
    ''|*[!0-9]*)
      fm_browser_guard_error "register-root requires --pid <number>"
      return 2
      ;;
  esac
  path=$(fm_browser_guard_ownership_path "$task")
  if [ ! -f "$path" ]; then
    fm_browser_guard_start "$task" --light --role registered-root || return 1
  fi
  existing=$(fm_browser_guard_meta_get "$path" root_pids 2>/dev/null || true)
  if [ -n "$existing" ]; then
    existing="${existing},${pid}"
  else
    existing=$pid
  fi
  # Rewrite preserving other fields.
  local home_real session own_pid own_kind role protected slot started
  home_real=$(fm_browser_guard_meta_get "$path" home_real)
  session=$(fm_browser_guard_meta_get "$path" session)
  own_pid=$(fm_browser_guard_meta_get "$path" pid)
  own_kind=$(fm_browser_guard_meta_get "$path" kind)
  role=$(fm_browser_guard_meta_get "$path" role)
  protected=$(fm_browser_guard_meta_get "$path" protected)
  slot=$(fm_browser_guard_meta_get "$path" slot 2>/dev/null || true)
  started=$(fm_browser_guard_meta_get "$path" started_at 2>/dev/null || true)
  fm_browser_guard_write_ownership "$path" \
    "home_real=$home_real" \
    "task_id=$task" \
    "session=$session" \
    "pid=$own_pid" \
    "kind=$own_kind" \
    "role=$role" \
    "protected=$protected" \
    "slot=${slot:-}" \
    "root_pids=$existing" \
    "root_kind=$kind" \
    "started_at=${started:-}"
  printf 'root_pids=%s\n' "$existing"
}

# Prove ownership record binds this home+task+session before any kill.
fm_browser_guard_prove_ownership() {
  local task=$1
  local path home_real session rec_home rec_task rec_session
  path=$(fm_browser_guard_ownership_path "$task")
  [ -f "$path" ] || {
    fm_browser_guard_error "no ownership record for task $task"
    return 1
  }
  home_real=$(fm_browser_guard_home_real) || return 1
  session=$(fm_browser_guard_session_id "$task" "$home_real") || return 1
  rec_home=$(fm_browser_guard_meta_get "$path" home_real) || return 1
  rec_task=$(fm_browser_guard_meta_get "$path" task_id) || return 1
  rec_session=$(fm_browser_guard_meta_get "$path" session) || return 1
  [ "$rec_home" = "$home_real" ] || {
    fm_browser_guard_error "ownership home mismatch for $task"
    return 1
  }
  [ "$rec_task" = "$task" ] || {
    fm_browser_guard_error "ownership task mismatch for $task"
    return 1
  }
  [ "$rec_session" = "$session" ] || {
    fm_browser_guard_error "ownership session mismatch for $task"
    return 1
  }
  fm_browser_guard_is_owned_session_name "$rec_session" || {
    fm_browser_guard_error "session name not Firstmate-owned: $rec_session"
    return 1
  }
  FM_BROWSER_GUARD_PROVED_PATH=$path
  FM_BROWSER_GUARD_PROVED_SESSION=$rec_session
  FM_BROWSER_GUARD_PROVED_PROTECTED=$(fm_browser_guard_meta_get "$path" protected 2>/dev/null || echo 0)
  FM_BROWSER_GUARD_PROVED_ROOTS=$(fm_browser_guard_meta_get "$path" root_pids 2>/dev/null || true)
  return 0
}

# chrome-devtools-axi state dir for a named session (mirrors package sessions.js).
fm_browser_guard_chrome_state_dir() {
  local session=$1
  local base="${FM_BROWSER_GUARD_CHROME_STATE_BASE:-$HOME/.chrome-devtools-axi}"
  if [ "$session" = default ]; then
    printf '%s' "$base"
  else
    printf '%s/sessions/%s' "$base" "$session"
  fi
}

fm_browser_guard_chrome_pid_file() {
  printf '%s/bridge.pid' "$(fm_browser_guard_chrome_state_dir "$1")"
}

# Read bridge pid from chrome-devtools pid JSON if present.
fm_browser_guard_read_bridge_pid() {
  local session=$1 file pid
  file=$(fm_browser_guard_chrome_pid_file "$session")
  [ -f "$file" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    pid=$(jq -er '.pid // empty' "$file" 2>/dev/null) || return 1
  else
    pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$file" | head -1)
  fi
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pid"
}

# Exact stop of one named chrome-devtools session via the axi CLI when available.
# Falls back to SIGTERM of the exact bridge pid from the session pid file only.
# Never touches default session, user Chrome, or unmatched names.
fm_browser_guard_stop_chrome_session() {
  local session=$1
  local axi=${FM_BROWSER_GUARD_AXI:-chrome-devtools-axi}
  local pid file
  fm_browser_guard_is_owned_session_name "$session" || {
    fm_browser_guard_error "refusing to stop non-owned session: $session"
    return 1
  }
  if [ "${FM_BROWSER_GUARD_DRY_STOP:-0}" = 1 ]; then
    printf 'dry-stop session=%s\n' "$session"
    return 0
  fi
  if command -v "$axi" >/dev/null 2>&1; then
    if CHROME_DEVTOOLS_AXI_SESSION="$session" "$axi" stop >/dev/null 2>&1; then
      return 0
    fi
  fi
  # Fallback: exact pid from session pid file only.
  file=$(fm_browser_guard_chrome_pid_file "$session")
  pid=$(fm_browser_guard_read_bridge_pid "$session" 2>/dev/null || true)
  if [ -n "$pid" ] && fm_browser_guard_pid_alive "$pid"; then
    # Verify the pid file still names this session if JSON has a session field.
    if command -v jq >/dev/null 2>&1 && [ -f "$file" ]; then
      local named
      named=$(jq -er '.session // empty' "$file" 2>/dev/null || true)
      if [ -n "$named" ] && [ "$named" != "$session" ]; then
        fm_browser_guard_error "pid file session mismatch; refusing kill"
        return 1
      fi
    fi
    kill -TERM "$pid" 2>/dev/null || true
    local i=0
    while [ "$i" -lt 20 ] && fm_browser_guard_pid_alive "$pid"; do
      sleep 0.1
      i=$((i + 1))
    done
    if fm_browser_guard_pid_alive "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$file" 2>/dev/null || true
  return 0
}

# Stop only exact registered root pids that are still alive. No tree walk by name.
fm_browser_guard_stop_registered_roots() {
  local roots=$1
  local pid
  [ -n "$roots" ] || return 0
  IFS=',' read -r -a _fm_bg_roots <<< "$roots"
  for pid in "${_fm_bg_roots[@]}"; do
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    if fm_browser_guard_pid_alive "$pid"; then
      if [ "${FM_BROWSER_GUARD_DRY_STOP:-0}" = 1 ]; then
        printf 'dry-stop root_pid=%s\n' "$pid"
        continue
      fi
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
}

# fm_browser_guard_stop <task-id> [--force-protected]
# Exact cleanup. Protected reviews refuse unless --force-protected (never used
# by automatic detection; only explicit captain/teardown-with-force paths).
fm_browser_guard_stop() {
  local task=$1
  shift
  local force_protected=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force-protected) force_protected=1; shift ;;
      *)
        fm_browser_guard_error "unknown stop flag: $1"
        return 2
        ;;
    esac
  done
  if ! fm_browser_guard_prove_ownership "$task"; then
    # Idempotent: no record is success for cleanup-task path.
    return 0
  fi
  if [ "${FM_BROWSER_GUARD_PROVED_PROTECTED:-0}" = 1 ] && [ "$force_protected" -ne 1 ]; then
    fm_browser_guard_error "refusing to auto-stop protected review for $task"
    return 1
  fi
  fm_browser_guard_stop_chrome_session "$FM_BROWSER_GUARD_PROVED_SESSION" || true
  fm_browser_guard_stop_registered_roots "${FM_BROWSER_GUARD_PROVED_ROOTS:-}" || true
  fm_browser_guard_lease_release "$task" 2>/dev/null || true
  rm -f "$FM_BROWSER_GUARD_PROVED_PATH"
  printf 'stopped task=%s session=%s\n' "$task" "$FM_BROWSER_GUARD_PROVED_SESSION"
}

# Teardown hook: exact owned disposable cleanup only. Never force protected.
# Never bypasses unlanded-work checks (caller runs this only after authorized).
fm_browser_guard_cleanup_task() {
  local task=$1
  local path protected
  path=$(fm_browser_guard_ownership_path "$task")
  if [ ! -f "$path" ]; then
    # Still release any heavy lease this home+task might hold.
    fm_browser_guard_lease_release "$task" 2>/dev/null || true
    return 0
  fi
  protected=$(fm_browser_guard_meta_get "$path" protected 2>/dev/null || echo 0)
  if [ "$protected" = 1 ]; then
    # Leave protected review ownership; still release heavy lease if any.
    fm_browser_guard_lease_release "$task" 2>/dev/null || true
    fm_browser_guard_log "leaving protected review ownership for $task"
    return 0
  fi
  fm_browser_guard_stop "$task" || true
}

# Env exports for spawned workers (one line shell-safe assignments).
fm_browser_guard_env_exports() {
  local task=$1
  local session
  session=$(fm_browser_guard_session_id "$task") || return 1
  printf 'export CHROME_DEVTOOLS_AXI_SESSION=%q\n' "$session"
  printf 'export FM_BROWSER_TASK_ID=%q\n' "$task"
  printf 'export FM_BROWSER_SESSION=%q\n' "$session"
}

# One-shot: acquire, run command, always cleanup.
# fm_browser_guard_run <task-id> [--heavy|--light] -- <cmd...>
fm_browser_guard_run() {
  local task=$1
  shift
  local heavy=1
  local -a cmd=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --heavy) heavy=1; shift ;;
      --light) heavy=0; shift ;;
      --)
        shift
        cmd=("$@")
        break
        ;;
      *)
        cmd=("$@")
        break
        ;;
    esac
  done
  [ "${#cmd[@]}" -gt 0 ] || {
    fm_browser_guard_error "run requires a command"
    return 2
  }
  local start_flags=(--role disposable)
  if [ "$heavy" -eq 1 ]; then
    start_flags+=(--heavy)
  else
    start_flags+=(--light)
  fi
  fm_browser_guard_start "$task" "${start_flags[@]}" || return 1
  local session rc=0
  session=$(fm_browser_guard_session_id "$task") || return 1
  # shellcheck disable=SC2064
  trap 'fm_browser_guard_stop "'"$task"'" || true' EXIT INT TERM
  export CHROME_DEVTOOLS_AXI_SESSION=$session
  export FM_BROWSER_TASK_ID=$task
  export FM_BROWSER_SESSION=$session
  "${cmd[@]}" || rc=$?
  trap - EXIT INT TERM
  fm_browser_guard_stop "$task" || true
  return "$rc"
}

# --- detection (cheap, bounded) ---------------------------------------------

# Dedupe marker path under state.
fm_browser_guard_alarm_seen_path() {
  local key=$1
  local state=${FM_STATE_OVERRIDE:-${STATE:-${FM_HOME:-}/state}}
  local safe
  safe=$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')
  printf '%s/.browser-guard-seen-%s' "$state" "$safe"
}

fm_browser_guard_emit_alarm() {
  local key=$1
  local message=$2
  local path now last
  path=$(fm_browser_guard_alarm_seen_path "$key")
  now=$(date +%s 2>/dev/null || echo 0)
  last=$(cat "$path" 2>/dev/null || true)
  # Dedupe for 10 minutes (600s) unless FM_BROWSER_GUARD_ALARM_TTL overrides.
  local ttl=${FM_BROWSER_GUARD_ALARM_TTL:-600}
  if [ -n "$last" ]; then
    case "$last" in
      *[!0-9]*) ;;
      *)
        if [ $((now - last)) -lt "$ttl" ]; then
          return 0
        fi
        ;;
    esac
  fi
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  printf '%s\n' "$now" > "$path" 2>/dev/null || true
  printf '%s %s\n' "$FM_BROWSER_GUARD_ALARM_PREFIX" "$message"
}

# List Firstmate-owned chrome session dirs under the axi state base.
fm_browser_guard_list_owned_session_dirs() {
  local base="${FM_BROWSER_GUARD_CHROME_STATE_BASE:-$HOME/.chrome-devtools-axi}"
  local d name
  [ -d "$base/sessions" ] || return 0
  for d in "$base/sessions"/*; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    fm_browser_guard_is_owned_session_name "$name" || continue
    printf '%s\n' "$name"
  done
}

# Cheap load sample (1-minute load average integer-ish).
fm_browser_guard_load1() {
  if [ -r /proc/loadavg ]; then
    awk '{print int($1)}' /proc/loadavg
    return 0
  fi
  # macOS: sysctl
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i+0==$i){print int($i); exit}}'
    return 0
  fi
  printf '0\n'
}

# fm_browser_guard_detect
# Bounded detection for session-start and heartbeat. Emits only actionable
# deduplicated BROWSER_GUARD: lines. Never closes protected or ambiguous work.
fm_browser_guard_detect() {
  local home_real state session path task rec_home rec_task rec_session protected
  local load1 bridge_pid cpu
  home_real=$(fm_browser_guard_home_real 2>/dev/null || true)
  state=${FM_STATE_OVERRIDE:-${STATE:-${FM_HOME:-}/state}}
  load1=$(fm_browser_guard_load1 2>/dev/null || echo 0)

  # 1) Ownership records whose session bridge is live but task meta is gone
  #    (orphan disposable) -> auto clean only if unprotected and proved.
  if [ -d "$state" ]; then
    local f
    for f in "$state"/*"$FM_BROWSER_GUARD_META_SUFFIX"; do
      [ -f "$f" ] || continue
      task=$(fm_browser_guard_meta_get "$f" task_id 2>/dev/null || true)
      rec_home=$(fm_browser_guard_meta_get "$f" home_real 2>/dev/null || true)
      rec_session=$(fm_browser_guard_meta_get "$f" session 2>/dev/null || true)
      protected=$(fm_browser_guard_meta_get "$f" protected 2>/dev/null || echo 0)
      [ -n "$task" ] && [ -n "$rec_session" ] || continue
      if [ -n "$home_real" ] && [ -n "$rec_home" ] && [ "$rec_home" != "$home_real" ]; then
        continue
      fi
      if [ ! -f "$state/${task}.meta" ] && [ "$protected" != 1 ]; then
        if bridge_pid=$(fm_browser_guard_read_bridge_pid "$rec_session" 2>/dev/null); then
          if fm_browser_guard_pid_alive "$bridge_pid"; then
            fm_browser_guard_emit_alarm "orphan-$task" \
              "orphan disposable browser session=$rec_session task=$task (no meta); cleaning exact owned session"
            # Auto-clean only exact owned disposable.
            FM_HOME="${rec_home:-$FM_HOME}" fm_browser_guard_stop "$task" 2>/dev/null || true
          fi
        fi
      fi
      # Protected review runaway: high load + live bridge for protected role.
      if [ "$protected" = 1 ]; then
        if bridge_pid=$(fm_browser_guard_read_bridge_pid "$rec_session" 2>/dev/null); then
          if fm_browser_guard_pid_alive "$bridge_pid"; then
            cpu=0
            if command -v ps >/dev/null 2>&1; then
              cpu=$(ps -o %cpu= -p "$bridge_pid" 2>/dev/null | tr -d ' ' | cut -d. -f1)
              case "$cpu" in ''|*[!0-9]*) cpu=0 ;; esac
            fi
            # Alert thresholds: load1 >= 8 or bridge %cpu >= 50. Alert only.
            if [ "${load1:-0}" -ge 8 ] || [ "${cpu:-0}" -ge 50 ]; then
              fm_browser_guard_emit_alarm "runaway-review-$task" \
                "protected review session=$rec_session task=$task may be runaway (load1=$load1 bridge_cpu=${cpu}%); not auto-closed - close the review tab or stop the owned session deliberately"
            fi
          fi
        fi
      fi
    done
  fi

  # 2) Orphan chrome session dirs under ~/.chrome-devtools-axi/sessions/fm-*
  #    with live bridge pid and no matching ownership in this home.
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    bridge_pid=$(fm_browser_guard_read_bridge_pid "$session" 2>/dev/null || true)
    if [ -z "$bridge_pid" ] || ! fm_browser_guard_pid_alive "$bridge_pid"; then
      continue
    fi
    # Does this home claim it?
    local claimed=0
    if [ -d "$state" ]; then
      for f in "$state"/*"$FM_BROWSER_GUARD_META_SUFFIX"; do
        [ -f "$f" ] || continue
        rec_session=$(fm_browser_guard_meta_get "$f" session 2>/dev/null || true)
        if [ "$rec_session" = "$session" ]; then
          claimed=1
          break
        fi
      done
    fi
    if [ "$claimed" -eq 0 ]; then
      # Only auto-clean if session name embeds this home's hash.
      if [ -n "$home_real" ]; then
        local hash
        hash=$(fm_browser_guard_hash8 "$home_real")
        case "$session" in
          "${FM_BROWSER_GUARD_SESSION_PREFIX}-${hash}-"*)
            fm_browser_guard_emit_alarm "orphan-session-$session" \
              "orphan Firstmate session=$session bridge_pid=$bridge_pid with no ownership record; stopping exact session only"
            fm_browser_guard_stop_chrome_session "$session" 2>/dev/null || true
            ;;
          *)
            # Other home's session: alert only, never stop.
            fm_browser_guard_emit_alarm "foreign-session-$session" \
              "live Firstmate-owned session=$session not claimed by this home; leaving untouched"
            ;;
        esac
      fi
    fi
  done < <(fm_browser_guard_list_owned_session_dirs)

  # 3) Sustained machine pressure while this home holds a heavy lease.
  if [ "${load1:-0}" -ge 20 ]; then
    local dir slots i lpath ltask lsession
    dir=$(fm_browser_guard_lease_dir)
    slots=$(fm_browser_guard_heavy_slots)
    i=0
    while [ "$i" -lt "$slots" ]; do
      lpath=$(fm_browser_guard_lease_slot_path "$i")
      if [ -f "$lpath" ]; then
        ltask=$(fm_browser_guard_meta_get "$lpath" task_id 2>/dev/null || true)
        lsession=$(fm_browser_guard_meta_get "$lpath" session 2>/dev/null || true)
        rec_home=$(fm_browser_guard_meta_get "$lpath" home_real 2>/dev/null || true)
        if [ -n "$home_real" ] && [ "$rec_home" = "$home_real" ]; then
          fm_browser_guard_emit_alarm "pressure-$ltask" \
            "high load1=$load1 while heavy lease held by task=$ltask session=$lsession; release or stop disposable browser work before swap collapse"
        fi
      fi
      i=$((i + 1))
    done
  fi
}

# Status for one task.
fm_browser_guard_status() {
  local task=$1
  local path session home_real
  path=$(fm_browser_guard_ownership_path "$task")
  home_real=$(fm_browser_guard_home_real 2>/dev/null || true)
  session=$(fm_browser_guard_session_id "$task" 2>/dev/null || true)
  printf 'task=%s\n' "$task"
  printf 'session=%s\n' "${session:-}"
  printf 'home_real=%s\n' "${home_real:-}"
  if [ -f "$path" ]; then
    printf 'ownership=present\n'
    cat "$path"
  else
    printf 'ownership=absent\n'
  fi
  printf 'leases:\n'
  fm_browser_guard_lease_status
}
