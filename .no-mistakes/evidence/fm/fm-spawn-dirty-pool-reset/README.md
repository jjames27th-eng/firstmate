# Pooled-copy refusal and recorded-copy protection: live evidence

Target commit 5bcf2dc5; unpatched source is the base commit f641b44b, extracted with git archive.
All runs used real bin/fm-spawn.sh, real Git, unmodified Treehouse v3.1.8 and pinned v3.1.5, a private tmux socket or a fm-lab-* Herdr session, and disposable project, pool, home and HOME directories.
Paths are replaced with $LAB; HEAD, status and edit content are recorded before and after each step.

| Scenario | Files |
| --- | --- |
| Unpatched refusal, exit, empty Enter, retry | paired-unpatched-318.txt, paired-unpatched-315.txt |
| Patched refusal, exit, empty Enter, retry, prune, plain return, other task, explicit release | paired-patched-318.txt, paired-patched-315.txt |
| Paused task's recorded copy in another home, on the interactive get path | rec-{patched,unpatched}-{default-tip,unlanded,leased}.txt, rec-patched-default-tip-315.txt |
| Herdr get --lease path: recorded copy, no double lease, dirty refusal, retry | herdr-patched.txt, herdr-unpatched.txt |
| Protection failure names the record and copy, and nothing is acquired | rootchange.txt |
| Treehouse v2.0.1 refused by spawn and bootstrap | old-th.txt, bootstrap.txt |
| Real-Treehouse lease regression, including a symlinked pool root | lease-e2e-v3.1.8.txt, lease-e2e-v3.1.5.txt |
| Live T3 attempts, which were blocked | t3-live-attempts.txt |

The tmux proofs use a bounded outside writer that watches the real pane enter the copy, then edits from outside the pane.
The Herdr dirty proof uses a PATH shim that runs the real Treehouse, then edits immediately after get --lease returns, because no polling writer won that gap in six tries.
Scripts are in driver/.
