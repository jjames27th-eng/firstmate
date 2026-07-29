---
name: browser-resource-guard
description: >-
  Agent-only procedure for Firstmate-owned browser workload identity, the
  machine-wide heavy browser lease, exact session cleanup, and resource-pressure
  alarms. Use before disposable chrome-devtools, Playwright, Puppeteer, or other
  browser QA; before registering a long-lived captain review surface; on any
  BROWSER_GUARD diagnostic; and when teardown or heartbeat surfaces orphan or
  runaway browser work.
user-invocable: false
metadata:
  internal: true
---

# browser-resource-guard

Load this before browser or long-lived review work, and when session-start or heartbeat prints a `BROWSER_GUARD:` line.
Exact flags, paths, and proofs are owned by `bin/fm-browser-guard.sh` and `bin/fm-browser-guard-lib.sh` (run `--help`).
Do not restate those mechanics here.

## Why this exists

Disposable browser QA and long-lived review tooling can orphan headless Chrome, bridges, and renderers until the machine swaps and stalls.
Instructions alone and after-the-fact cleanup are not enough.
Firstmate therefore owns identity, a machine-wide heavy lease, exact cleanup, and cheap detection.

## Safety boundaries

- Never use `pkill -f`, process-name sweeps, user Chrome automation, or unverified profile deletion.
- Never kill a process merely because its command resembles Chrome, Playwright, Node, or Lavish.
- Automatic cleanup may touch only exact Firstmate-owned disposable sessions that prove home, task, session, and process/profile binding.
- A protected captain review or any ambiguous process only alerts; it is never automatically closed.
- Do not open, attach to, enumerate into chat, or close unrelated personal tabs or other homes' work.
- Do not put moving PIDs or temporary profile paths into durable backlog prose.

## Worker procedure

1. Prefer the spawn-injected `CHROME_DEVTOOLS_AXI_SESSION` / `FM_BROWSER_SESSION` (task-owned).
   If missing, derive with `bin/fm-browser-guard.sh session-id <task-id>` and export it before any browser command.
2. For one-shot browser commands or test scripts:
   `bin/fm-browser-guard.sh run <task-id> --heavy -- <command...>`
   The helper acquires the heavy lease, sets the session env, and cleans on success, failure, and interrupt.
3. For multi-command sessions:
   `bin/fm-browser-guard.sh start <task-id> --heavy`
   then browser work, then `bin/fm-browser-guard.sh stop <task-id>` before any terminal status.
4. For a long-lived captain review surface that must stay open while a disposable test runs:
   `bin/fm-browser-guard.sh start <task-id> --role review --protected`
   Register at most one heavy disposable lease at a time; the protected surface is light and is never auto-closed.
5. If the task uses direct Playwright or Puppeteer instead of chrome-devtools-axi:
   after launch, `bin/fm-browser-guard.sh register-root <task-id> --pid <root-pid> --kind playwright|puppeteer`
   so cleanup stays exact to that root.
6. Release the heavy lease (via `stop` or `run`'s finally path) before `done`, `failed`, or other terminal results.
7. Never hold the heavy lease across an idle wait that is not active browser work.

## Firstmate procedure on `BROWSER_GUARD:`

1. Read the printed line as the concrete session, task, and consequence.
2. For orphan disposable cleanups already performed by detect: note the outcome; no captain noise unless work was lost.
3. For pressure while a heavy lease is held: steer or stop the owning disposable task; do not kill foreign processes.
4. For protected runaway review: escalate to the captain with the review identity and consequence; do not auto-close.
5. For foreign-home sessions: leave them untouched; they belong to another Firstmate home.

## Detection owner

`bin/fm-browser-guard.sh detect` runs at locked session-start (after Herdr projection cleanup) and from the watcher heartbeat scan.
It is bounded and cheap.
It auto-cleans only unambiguous home-owned disposable orphans.
It never starts a second background daemon.

## Config

Optional local `config/browser-heavy-slots` (positive integer, default 1) raises the machine-wide concurrent heavy browser budget when the machine can support more.
Absent means one heavy browser workload at a time across the main home and every secondmate home.
