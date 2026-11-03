#!/usr/bin/env bash
. "$(dirname "$0")/lib.sh"
run() { # <label> <src> <thdir>
  new_lab
  local o; o=$(cd "$PROJECT" && PATH="$3:$PATH" FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip bash "$2/bin/fm-bootstrap.sh" 2>&1); local rc=$?
  printf '=== %s: treehouse %s, get --lease flag: %s, lease subcommand exit: %s\n' "$1" "$(PATH="$3:$PATH" treehouse --version)" "$(PATH="$3:$PATH" treehouse get --help 2>&1 | grep -c -- --lease)" "$(PATH="$3:$PATH" treehouse lease --help >/dev/null 2>&1; echo $?)"
  printf 'bootstrap exit=%s; treehouse lines:\n' "$rc"; printf '%s\n' "$o" | grep -i treehouse || echo '(no treehouse line)'
  tmux -L default kill-server 2>/dev/null; stop_lab
}
run 'patched + v2.0.1' "$WORK/.test-tmp/patched-copy" "$WORK/.test-tmp/th201"
run 'patched + pinned v3.1.5' "$WORK/.test-tmp/patched-copy" "$WORK/.test-tmp/th315"
run 'patched + v3.1.8' "$WORK/.test-tmp/patched-copy" "$(dirname "$(command -v treehouse)")"
run 'unpatched + v2.0.1' "$WORK/.test-tmp/unpatched" "$WORK/.test-tmp/th201"
