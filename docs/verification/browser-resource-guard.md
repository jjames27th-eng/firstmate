# Browser resource guard verification

Audience: maintainer verification.

This record holds reusable evidence for Firstmate-owned browser identity, the machine-wide heavy lease, exact cleanup safety, spawn environment propagation, and bounded detection.
Incident chronology stays in private task reports.
Operator layout and config defaults live in `docs/configuration.md` "Browser resource guard".
Exact CLI mechanics live in `bin/fm-browser-guard.sh` help and `bin/fm-browser-guard-lib.sh`.

## Date and versions

- Date: 2026-07-29
- Firstmate branch under test: `fm/firstmate-browser-resource-guard`
- Host: macOS (Darwin), bash from `/bin/bash` or Homebrew bash as used by the suite
- chrome-devtools-axi session rules mirrored: name charset `[A-Za-z0-9._-]`, max 64 chars, state under `~/.chrome-devtools-axi/sessions/<name>/`

## Focused contract tests

```sh
bin/fm-test-run.sh tests/fm-browser-guard.test.sh
```

The suite proves, with fake process trees and dry-stop hooks (no real Chrome):

- same home+task session id is stable across calls
- different homes with the same task id produce different session names
- default single heavy slot cannot be held by two homes concurrently
- release and signal/failure cleanup remove only the exact owned session
- simulated user Chrome, unrelated tabs, another task, another home, a protected review, and ambiguous processes are never targeted
- stale lease reclamation requires confidently dead ownership
- ambiguous ownership refuses reclaim
- teardown path invokes exact owned cleanup only (via cleanup-task) without altering landed-work refusal behavior
- detect is bounded, deduplicates alarms, alerts protected runaway reviews without closing them
- one-shot `run` leaves no ownership record or heavy lease after cleanup

## Spawn / harness / backend applicability

Session env export is applied once in `bin/fm-spawn.sh` through the shared pane shell path used by every spawn-capable backend:

| Axis | Result |
| --- | --- |
| harness `claude` | Receives pane exports before launch (same path as GOTMPDIR) |
| harness `codex` | Same |
| harness `opencode` | Same |
| harness `pi` / `pi-signed` | Same |
| harness `grok` | Same |
| harness `kimi` | Same (exports before ready wait and brief pointer) |
| backend `tmux` | Applicable; `spawn_send_text_line` |
| backend `herdr` | Applicable; same helper |
| backend `zellij` | Applicable; same helper |
| backend `orca` | Applicable; same helper |
| backend `cmux` | Applicable; same helper |
| Captain-launched browser (no spawn) | Non-applicable by design: no task session export; remains chrome-devtools default |

Secondmate spawns compute the session with `FM_HOME` set to the secondmate home so primary and secondmate identities never collide.

## Real-browser smoke (optional, manual)

When exercised, use exactly one named disposable session, acquire the heavy lease, close in `finally`, and verify no owned descendants remain:

```sh
export FM_HOME=...   # test home only
bin/fm-browser-guard.sh run smoke-task --heavy -- \
  chrome-devtools-axi open about:blank
bin/fm-browser-guard.sh status smoke-task
# ownership absent; no bridge.pid under ~/.chrome-devtools-axi/sessions/fm-*-smoke-task
```

Do not attach to the captain's Chrome, current Lavish review, Colima, simulators, or product apps.

## Safety non-goals (explicit)

- No `pkill -f` or process-name sweeps anywhere in the implementation
- No automatic close of `protected=1` reviews
- No stop of session names outside the Firstmate `fm-<homehash>-*` prefix
- No change to teardown landed-work checks, watcher semantics, or chrome-devtools-axi package installation
