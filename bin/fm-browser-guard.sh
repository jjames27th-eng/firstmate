#!/usr/bin/env bash
# Firstmate browser workload lifecycle and resource protection.
#
# Usage:
#   fm-browser-guard.sh session-id <task-id>
#   fm-browser-guard.sh identity <task-id>
#   fm-browser-guard.sh env-exports <task-id>
#   fm-browser-guard.sh start <task-id> [--heavy|--light] [--role disposable|review] [--protected] [--pid N]
#   fm-browser-guard.sh status [<task-id>]
#   fm-browser-guard.sh stop <task-id> [--force-protected]
#   fm-browser-guard.sh cleanup-task <task-id>
#   fm-browser-guard.sh register-root <task-id> --pid <pid> [--kind playwright|puppeteer|other]
#   fm-browser-guard.sh lease acquire <task-id>
#   fm-browser-guard.sh lease release <task-id>
#   fm-browser-guard.sh lease status
#   fm-browser-guard.sh lease reconcile
#   fm-browser-guard.sh run <task-id> [--heavy|--light] -- <command...>
#   fm-browser-guard.sh detect
#
# Contract owner: bin/fm-browser-guard-lib.sh (this CLI is the thin entrypoint).
# Safety: exact home+task+session proof before any stop; never broad kills;
# protected reviews alert only under detect; automatic cleanup is disposable-only.
#
# Local config: config/browser-heavy-slots (positive integer, default 1).
# Private state: state/<task-id>.browser-guard
# Machine-wide lease: /tmp/firstmate-browser-guard-<uid>/heavy/slot-N
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_ROOT FM_HOME STATE CONFIG

# shellcheck source=bin/fm-browser-guard-lib.sh
. "$SCRIPT_DIR/fm-browser-guard-lib.sh"

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
}

op=${1:-}
[ -n "$op" ] || {
  usage >&2
  exit 2
}
shift

case "$op" in
  -h|--help|help)
    usage
    exit 0
    ;;
  session-id)
    [ "$#" -ge 1 ] || {
      echo "usage: fm-browser-guard.sh session-id <task-id>" >&2
      exit 2
    }
    fm_browser_guard_session_id "$1"
    ;;
  identity)
    [ "$#" -ge 1 ] || {
      echo "usage: fm-browser-guard.sh identity <task-id>" >&2
      exit 2
    }
    home_real=$(fm_browser_guard_home_real) || exit 1
    session=$(fm_browser_guard_session_id "$1" "$home_real") || exit 1
    printf 'home_real=%s\n' "$home_real"
    printf 'task_id=%s\n' "$1"
    printf 'session=%s\n' "$session"
    printf 'chrome_state=%s\n' "$(fm_browser_guard_chrome_state_dir "$session")"
    ;;
  env-exports)
    [ "$#" -ge 1 ] || {
      echo "usage: fm-browser-guard.sh env-exports <task-id>" >&2
      exit 2
    }
    fm_browser_guard_env_exports "$1"
    ;;
  start)
    [ "$#" -ge 1 ] || {
      echo "usage: fm-browser-guard.sh start <task-id> [flags]" >&2
      exit 2
    }
    fm_browser_guard_start "$@"
    ;;
  status)
    if [ "$#" -ge 1 ]; then
      fm_browser_guard_status "$1"
    else
      fm_browser_guard_lease_status
      if [ -d "$STATE" ]; then
        for f in "$STATE"/*"$FM_BROWSER_GUARD_META_SUFFIX"; do
          [ -f "$f" ] || continue
          echo "--- $(basename "$f")"
          cat "$f"
        done
      fi
    fi
    ;;
  stop)
    [ "$#" -ge 1 ] || {
      echo "usage: fm-browser-guard.sh stop <task-id> [--force-protected]" >&2
      exit 2
    }
    fm_browser_guard_stop "$@"
    ;;
  cleanup-task)
    [ "$#" -ge 1 ] || {
      echo "usage: fm-browser-guard.sh cleanup-task <task-id>" >&2
      exit 2
    }
    fm_browser_guard_cleanup_task "$1"
    ;;
  register-root)
    [ "$#" -ge 1 ] || {
      echo "usage: fm-browser-guard.sh register-root <task-id> --pid <pid> [--kind ...]" >&2
      exit 2
    }
    fm_browser_guard_register_root "$@"
    ;;
  lease)
    sub=${1:-}
    shift || true
    case "$sub" in
      acquire)
        [ "$#" -ge 1 ] || {
          echo "usage: fm-browser-guard.sh lease acquire <task-id>" >&2
          exit 2
        }
        fm_browser_guard_lease_acquire "$1"
        ;;
      release)
        [ "$#" -ge 1 ] || {
          echo "usage: fm-browser-guard.sh lease release <task-id>" >&2
          exit 2
        }
        fm_browser_guard_lease_release "$1"
        ;;
      status)
        fm_browser_guard_lease_status
        ;;
      reconcile)
        fm_browser_guard_lease_reconcile
        ;;
      *)
        echo "usage: fm-browser-guard.sh lease {acquire|release|status|reconcile}" >&2
        exit 2
        ;;
    esac
    ;;
  run)
    [ "$#" -ge 1 ] || {
      echo "usage: fm-browser-guard.sh run <task-id> [--heavy|--light] -- <cmd...>" >&2
      exit 2
    }
    fm_browser_guard_run "$@"
    ;;
  detect)
    fm_browser_guard_detect
    ;;
  *)
    echo "unknown command: $op" >&2
    usage >&2
    exit 2
    ;;
esac
