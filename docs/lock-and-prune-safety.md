# Lock, interrupted-backup and consent recovery

`install.sh --restart-scheduler` waits for running work. The explicit
`--restart-scheduler --force` option terminates a verified backup-lock job with
TERM, waits up to 10 seconds, then sends KILL to remaining processes before
queuing the restart. Linux pidfds pin process identities, so PID reuse cannot
redirect signals. Inherited lock descriptors and escaped child process groups
are included. A free lock or an unverifiable holder is refused. This is an
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
means timeout/termination; 137 means KILL after the termination grace. Prune waits
for a complete hourly backup so interrupted uploads' packs can be reused.
Unknown or failed results also block prune. Quick jobs cannot clear this gate.

Snapshots start tagged `incomplete`; only completed snapshots gain `auto` or
`quick`. Retention also strips those tags from legacy incomplete snapshots.
Incomplete snapshots remain available for manual inspection and are not counted
by retention. The first unreadable-file run is incomplete. Repeated identical
permission-denied errors on regular files may complete with warnings on later
runs, listing up to 20 omitted paths. Directory and unclassified errors never
qualify. A changed error set is incomplete again.

A failed integrity check sets `state/CHECK_FAILED`. The next passing check clears
it. Prune always follows a passing check in the same run, and also respects the
backup, stale-guard and SQLite gates. `state/last-check.result` records the check
result and whether prune succeeded.

Drive consent holds the backup lock and edits a private candidate config. The
original config is copied and byte-compared before consent. Verification retries
three times; folder-creation failure is explicit. Only a verified candidate is
atomically installed. `--test` never cleans up a concurrent consent flow's files.
