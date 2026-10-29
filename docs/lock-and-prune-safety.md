# Lock, interrupted-backup and consent recovery

`install.sh --restart-scheduler` waits for running work. The explicit
`--restart-scheduler --force` option terminates a verified backup-lock job with
TERM, waits up to 10 seconds, then sends KILL to remaining processes before
queuing the restart. Linux pidfds pin process identities, so PID reuse cannot
redirect signals. Inherited lock descriptors and escaped child process groups
are included. A free lock or an unverifiable holder is refused, and so is a lock
held by `restore.sh`: restores have no timeout, so only the human who started one
should stop it. This is an
emergency action: inspect status, and use it only past the job timeout plus grace
or when the heartbeat is stale for more than two hours.

Status checks the lock inode through `/proc/<pid>/fd` and the flock descriptor,
not merely whether a PID exists. It waits two seconds before reporting a missing
or invalid holder record. An orphan retains the valid recorded age; the alert
lists remaining holder PIDs and process names, never command lines. Nothing is
automatically killed. A scheduler heartbeat is excused only for its own verified
child within the job budget. Check jobs receive a longer budget because check,
prune, and other repository calls execute sequentially.

Hourly results are atomically written to `state/last-backup.result`. Timeout 124
means timeout/termination; 137 means SIGKILL, either timeout escalation or an external kill (such as OOM). Prune waits
for a complete hourly backup so interrupted uploads' packs can be reused.
Unknown or failed results also block prune. Quick jobs cannot clear this gate.

Snapshots start tagged `incomplete`; only completed snapshots gain `auto` or
`quick`. Retention also strips those tags from legacy incomplete snapshots.
Incomplete snapshots are excluded from the complete-snapshot retention counts.
A separate `forget --tag incomplete --keep-within 7d` policy bounds their history
to seven days relative to the newest incomplete snapshot in each retention group.
Safety latches also block this policy. The first unreadable-file run is incomplete. Repeated identical
permission-denied errors on regular files may complete with warnings on later
runs, listing up to 20 omitted paths. Directory and unclassified errors never
qualify. A changed error set is incomplete again.

A failed integrity check sets `state/CHECK_FAILED`. The next passing check clears
it. While set, it blocks forget as well as prune. Prune always follows a passing check in the same run, and also respects the
backup, stale-guard and SQLite gates. `state/last-check.result` records the check
result and whether prune succeeded.

Drive consent holds the backup lock and edits a private candidate config. The
original config is copied and byte-compared before consent. Verification retries
three times; folder-creation failure is explicit. Only a verified candidate is
atomically installed. `--test` never cleans up a concurrent consent flow's files.

## Snapshot promotion and stale locks

Before promotion the backup lists repository locks (read-only). The backup's own restic process has
exited by then, so a lock still present is stale; if there is one, a plain `restic unlock` (stale locks only) clears it
quietly (logged, no alert, spends the shared unlock budget below).
Promotion waits up to `PROMOTE_LOCK_WAIT` (default `2m`) for an exclusive lock.
After the first failure it retries once with the snapshot's current ID,
using the shared plain-unlock budget below.
Success requires verifying that `incomplete` is gone and `auto` or `quick` is present.
Read-only snapshot, file and size listings use `--no-lock`.
Backup snapshot listings retry once after `SNAPSHOT_LIST_RETRY_S` (default `5` seconds).
Each restic call logs its caller, wrapper, PID and arguments to the monthly log.

Backup, forget and retention tag cleanup wait up to `LOCK_RETRY_WAIT` (default `2m`)
per attempt. A lock error triggers one retry; at most one plain `restic unlock`
(stale locks only) runs across backup, promotion and retention in a script run.
An unlock before retry raises an alert; daily check's startup unlock uses the same budget.
An hourly backup with `--wait` (as used by the scheduler) that gives up waiting for
`backup.lock` exits successfully but alerts
and records time, mode, reason, holder and waited seconds in `state/backup-skipped`.
Manual runs without `--wait` and quick runs only log a busy-lock skip and exit 0;
they create no skip record or skip alert. The next successful hourly backup clears that file.

Drive transport calls use `RCLONE_NET_ARGS` (default `--contimeout 30s --timeout 2m --low-level-retries 5`), before `RCLONE_SERVE_ARGS` so explicit flags there win; an empty value disables these defaults. `RESTIC_TIMEOUT_META` (default `10m`) bounds tag, unlock, snapshots and cat; `RESTIC_TIMEOUT_FORGET` (default `30m`) bounds forget. Other calls retain `RESTIC_TIMEOUT`, and explicit `R_TIMEOUT` overrides all defaults (including `0` for no limit). Timeouts alert and terminate the process group, escalating to KILL after 60 seconds; promotion retries once with the shared plain-unlock budget and re-resolves the snapshot before retrying.
