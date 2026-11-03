#!/usr/bin/env bash
# Shared lab helpers. Everything is under $LAB; private tmux socket; no Herdr.
WORK=$REDACTED_PATH
export TMPDIR="$WORK/.test-tmp" TZ=UTC BASH_SILENCE_DEPRECATION_WARNING=1
unset NO_MISTAKES_GATE_X FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE
export SHELL=/bin/bash
new_lab() {  # sets LAB FM_HOME PROJECT TMUX_TMPDIR HOME; <treehouse-dir>
  LAB=$(cd "$(mktemp -d "$TMPDIR/$LAB")" && pwd -P)
  FM_HOME="$LAB/home"; PROJECT="$LAB/project"
  "$WORK/bin/fm-lab-home.sh" create "$FM_HOME" >/dev/null
  export FM_HOME
  export TMUX_TMPDIR=$("$WORK/bin/fm-lab-home.sh" tmux-dir "$FM_HOME")
  export HOME="$LAB/userhome" XDG_CONFIG_HOME="$LAB/userhome/.config"
  mkdir -p "$HOME"
  printf 'PS1="lab$ "\n' > "$HOME/.bashrc"; printf '. ~/.bashrc\n' > "$HOME/.bash_profile"
  git config --global user.name 'Lab'; git config --global user.email lab@example.invalid
  git config --global init.defaultBranch main
  git init -q --bare -b main "$LAB/origin.git"
  git init -q -b main "$PROJECT"
  printf 'base\n' > "$PROJECT/README.md"
  printf 'root = "%s"\n' "$LAB/pool" > "$PROJECT/treehouse.toml"
  git -C "$PROJECT" add . ; git -C "$PROJECT" commit -qm base
  git -C "$PROJECT" remote add origin "$LAB/origin.git"
  git -C "$PROJECT" push -q -u origin main
  git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
  git -C "$PROJECT" remote set-head origin main 2>/dev/null
  printf 'codex\n' > "$FM_HOME/config/crew-harness"
  touch "$FM_HOME/state/.last-watcher-beat"
  tmux -L default new-session -d -s firstmate -x 120 -y 40 -c "$PROJECT"
}
stop_lab() {
  tmux -L default kill-server 2>/dev/null
  # Real workers can outlive SIGHUP; stop only processes naming this exact lab.
  local i pids
  for i in 1 2 3 4 5; do
    pids=$(ps -axo pid=,command= | grep -F "$LAB/" | grep -v grep | awk '{print $1}')
    [ -n "$pids" ] || break
    [ "$i" -lt 4 ] && kill $pids 2>/dev/null || kill -9 $pids 2>/dev/null
    sleep 1
  done
  "$WORK/bin/fm-lab-home.sh" teardown "$FM_HOME" >/dev/null 2>&1
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"
  rm -rf /tmp/fm-proof-* /tmp/fm-rec-* /tmp/fm-old-th /tmp/fm-herdr-rec* 2>/dev/null
}
brief() {
  mkdir -p "$FM_HOME/data/$1"
  printf '# Task\n## Captain'"'"'s intent\nDo nothing. Scratch lab worker for %s.\n\n## Firstmate spec\nDo nothing and stop.\n' "$1" > "$FM_HOME/data/$1/brief.md"
}
sanitize() {  # stdin -> stdout
}
th() { (cd "$PROJECT" && treehouse "$@"); }
T() { tmux -L default "$@"; }
snapshot() { # <label> <copy>
  printf -- '--- %s\n' "$1"
  printf 'HEAD=%s\n' "$(git -C "$2" rev-parse HEAD)"
  printf 'git status --short:\n'; git -C "$2" status --short
  printf 'README.md content:\n'; cat "$2/README.md"
  printf 'treehouse status:\n'; th status --json | jq -c '.[] | {name,status,lease_holder,head_path:(.path|split("/")|.[-2:]|join("/"))}'
}
wait_pane() { # <target> <regex> <secs>
  local i
  for i in $(seq 1 $(( $3 * 5 ))); do
    T capture-pane -p -t "$1" 2>/dev/null | grep -Eq "$2" && return 0
    sleep 0.2
  done
  return 1
}
start_writer() { # <id> ; bounded outside writer
  local id=$1
  ( for i in $(seq 1 3000); do
      p=$(T list-panes -t "firstmate:fm-$id" -F '#{pane_current_path}' 2>/dev/null | head -1)
      case "$p" in
        */pool/.treehouse/*/project)
          printf 'outside writer edit for %s\n' "$id" >> "$p/README.md"
          printf 'path=%s\nhead=%s\nstatus=%s\n' "$p" "$(git -C "$p" rev-parse HEAD)" "$(git -C "$p" status --short)" > "$LAB/writer.$id"
          exit 0 ;;
      esac
      sleep 0.02
    done ) &
  WRITER=$!
}
rec() { printf '%s\n' "$*"; }
check() { # <desc> <cond-cmd...>
  local d=$1; shift
  if "$@"; then printf 'CHECK PASS: %s\n' "$d"; else printf 'CHECK FAIL: %s\n' "$d"; FAILS=$((${FAILS:-0}+1)); fi
}
