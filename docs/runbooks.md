# Operational Runbooks

Step-by-step procedures for recovering from repository check errors, undoing a bad prune from the Google Drive trash, and fixing `BACKUP_HOST` mismatches. For box moves, missing local files, or full disaster recovery on a new box, see [REBUILD.md](../REBUILD.md).

## Safety rules for all runbooks
- **Never print secrets** (`secrets/restic-pass`, `secrets/rclone.conf`, `$RESTIC_BACKUP_PASSWORD`). Load the repo helpers (`source ./lib.sh; set +e; trap - ERR`) and use `R` (restic), `RT` (restic with Drive trash enabled), and `RCL` (rclone).
- **Pause the scheduler first** (`touch state/PAUSE`) and verify no job holds `state/backup.lock` (`./status.sh --local` should show no `Running now:` line) before running repository maintenance commands.
- **Never run `prune` while the repository is failing `check`.** Pruning against a damaged index can delete pack files that snapshots still need.
- **Ask the human first** before running any command that removes or rewrites snapshots (`repair snapshots`, `repair packs`, `rewrite --forget`, `forget`).

---

## 1. Repository repair (`restic check` failed)

Use this runbook when `check.sh` exits with code `5` (`ALERT: restic check FAILED`) or the `state/CHECK_FAILED` latch is set. While `state/CHECK_FAILED` exists, `check.sh` skips `prune` automatically so no pack files are deleted before repair finishes.

### Step 1: Pause backups and confirm the lock is free
```bash
cd /workspace/grokbox
touch state/PAUSE
./status.sh --local   # wait until there is no "Running now:" line
```

### Step 2: Load helpers and clear stale repository locks
```bash
source ./lib.sh; set +e; trap - ERR
R unlock
```

### Step 3: Run a full structure check and read the error type
```bash
R_TIMEOUT=8h R check | tee "$GB_LOGS/repair-check.log"
```
Check what `restic check` reports:
- **Only index errors** (e.g. `pack <id> not referenced in any index`, `index <id> cannot be loaded`, duplicate index entries after an interrupted `prune`): proceed to **Step 4** (`repair index`).
- **Missing pack files** (e.g. `pack <id> does not exist`): if a `prune` or manual deletion ran recently and `PRUNE_USE_TRASH=1` (the default), **stop here and follow [Runbook 2 (Undo a bad prune from the Drive trash)](#2-undo-a-bad-prune-from-the-drive-trash) first**. Restoring missing packs from the Drive trash recovers the data without losing files from any snapshot.

### Step 4: Rebuild the index (`repair index`)
Rebuilding the index is non-destructive: it reads all existing pack headers in the repository and writes a fresh index. (Does **not** require human approval.)
```bash
R_TIMEOUT=8h R repair index
R_TIMEOUT=8h R check
```
*(Note: on older restic versions `repair index` was named `rebuild-index`; both are aliases in restic 0.19+.)*

If `R check` now exits `0` with no errors, jump to **Step 7**.

### Step 5: Salvage damaged pack files (`repair packs`) — **[HUMAN APPROVAL REQUIRED]**
If `R check` (or `R_TIMEOUT=8h R check --read-data-subset 10%`) reports specific corrupted pack IDs that cannot be restored from the Drive trash:
1. Report the damaged pack IDs to the human and ask permission to salvage them.
2. Once the human approves:
   ```bash
   R_TIMEOUT=8h R repair packs <pack-id>...
   ```
   This extracts intact blobs from the damaged packs into new packs and updates the index.

### Step 6: Repair snapshots with permanently missing blobs (`repair snapshots`) — **[HUMAN APPROVAL REQUIRED]**
If `R check` still reports `tree <id> not found` or missing data blobs that are not in the Drive trash:
1. **Ask the human first.** Explain that `restic repair snapshots --forget` modifies the affected snapshots to drop references to unreadable/missing files or directories (so the rest of the snapshot remains restorable) and removes the broken original snapshot objects.
2. Only after explicit human approval:
   ```bash
   R_TIMEOUT=8h R repair snapshots --forget
   R_TIMEOUT=8h R check
   ```
3. Immediately run a fresh backup in Step 7 so any files that still exist on the live box are uploaded again.

### Step 7: Verify, clear latches, and resume
```bash
R_TIMEOUT=8h R check --read-data-subset "$CHECK_SUBSET"
```
Only when `R check` succeeds (exit `0`):
```bash
date +%s > "$GB_STATE/last-check"
rm -f "$GB_STATE/CHECK_FAILED" "$GB_STATE/PAUSE"
./backup.sh
./status.sh
./status.sh --ack
```

---

## 2. Undo a bad prune from the Drive trash

With `PRUNE_USE_TRASH=1` (the default in `config.env.example`), `lib.sh` runs `forget` and `prune` through `RT`, which passes `--drive-use-trash=true` to `rclone`. Files deleted by `forget` (`snapshots/<id>`) and `prune` (`data/xx/<id>`, `index/<id>`) go to the Google Drive trash instead of being permanently erased, and remain recoverable for ~30 days until Google empties the trash.

*(If `PRUNE_USE_TRASH=0` was set when `prune` ran, deleted files bypassed the Drive trash and cannot be recovered from Drive.)*

### Step 1: Pause backups immediately
```bash
cd /workspace/grokbox
touch state/PAUSE
./status.sh --local   # wait until no job is running
source ./lib.sh; set +e; trap - ERR
```

### Step 2: Inspect what is in the Drive trash for the repository
```bash
RCL lsf -R --drive-trashed-only "$GB_REMOTE:$GB_FOLDER"
```
Preview what `rclone backend untrash` would restore:
```bash
RCL backend --dry-run untrash "$GB_REMOTE:$GB_FOLDER"
```

### Step 3: Restore the trashed repository files — **[HUMAN APPROVAL REQUIRED]**
Ask the human before untrashing repository files. Then use either option:

- **Option A — `rclone backend untrash` from the box (recommended):**
  Restores all trashed files and subdirectories under `$GB_REMOTE:$GB_FOLDER` (`data/`, `snapshots/`, `index/`) back to their original paths:
  ```bash
  RCL backend untrash "$GB_REMOTE:$GB_FOLDER"
  ```
- **Option B — Google Drive Web UI (by the human):**
  Open Google Drive -> **Trash**, select the trashed files belonging to the backup folder (default `GrokBox/restic`), and click **Restore**.

### Step 4: Rebuild the restic index and verify
Because `prune` replaced the repository index files when it deleted the packs, restic will not recognize the untrashed `data/` packs until the index is rebuilt (`repair index` / `rebuild-index`):
```bash
R unlock
R_TIMEOUT=8h R repair index
R_TIMEOUT=8h R check --read-data-subset "$CHECK_SUBSET"
R snapshots --host "$BACKUP_HOST"
```

### Step 5: Protect recovered snapshots before resuming
If you untrashed snapshots that would immediately be deleted again by the next scheduled `forget` (`KEEP` / `KEEP_QUICK`):
- Either restore the needed files right away into a scratch directory (`./restore.sh <snapshot-id>`), or
- Adjust `KEEP` in `config.env` before unpausing.

Then unpause and check status:
```bash
rm -f "$GB_STATE/CHECK_FAILED" "$GB_STATE/PAUSE"
./status.sh
```

---

## 3. Wrong host (`BACKUP_HOST` mismatch or box moved)

Restic groups snapshot chains and retention by hostname (`BACKUP_HOST` in `config.env`, default `grokbox`). A host mismatch happens if `config.env` was lost or edited to use a different `BACKUP_HOST`.

Symptoms:
- `./restore.sh list` exits with code `4`:
  `ERROR: no snapshots for host '<name>' in this repository. Hosts in this repository (snapshot count): ...`
- Or `backup.sh` started a new snapshot chain under a new host name (ignoring the previous host's parent snapshot and guard baseline).

### Step 1: See which host names exist in the repository
Run `restore.sh` with `--any-host`:
```bash
cd /workspace/grokbox
./restore.sh --any-host list
```
Or print snapshot counts per host:
```bash
source ./lib.sh; set +e; trap - ERR
R snapshots --json | python3 -c '
import collections, json, sys
c = collections.Counter(s.get("hostname", "?") for s in json.load(sys.stdin))
for h, n in sorted(c.items()): print(f"{h}: {n} snapshots")
'
```

### Step 2: If you only need to browse or restore right now (`restore.sh` host fallback)
You do not need to rewrite snapshots just to restore files from another host name:
```bash
./restore.sh --host <old-host> list
./restore.sh --host <old-host> ls latest /workspace
./restore.sh --host <old-host> latest /workspace/project
./restore.sh --any-host latest              # newest snapshot across all hosts
```

### Step 3: Fix `BACKUP_HOST` in `config.env`
Set `BACKUP_HOST` in `config.env` to the canonical host name (default `BACKUP_HOST=grokbox`):
```bash
grep '^BACKUP_HOST=' config.env
```
If no snapshots were created under the wrong host name yet, you are done — run `./restore.sh list` and `./status.sh` to confirm.

### Step 4: Rewrite snapshots recorded under the wrong host — **[HUMAN APPROVAL REQUIRED]**
If snapshots were already written under `<wrong-host>` and you want them merged into the `<correct-host>` chain (so parent lookups, the stale-computer guard tags `auto`/`quick`/`files=`/`bytes=`/`newest=`, and retention `KEEP` apply to one host):

1. **Pause backups and confirm the lock is free:**
   ```bash
   touch state/PAUSE
   ./status.sh --local   # wait until no job is running
   source ./lib.sh; set +e; trap - ERR
   ```
2. **Confirm `BACKUP_HOST` in `config.env` is set to `<correct-host>`.**
3. **Ask the human before rewriting snapshots.** Then rewrite the `<wrong-host>` snapshots to `$BACKUP_HOST`:
   ```bash
   R unlock
   R_TIMEOUT=3h RT rewrite --host "<wrong-host>" --new-host "$BACKUP_HOST" --forget
   ```
   **How `restic rewrite` handles tags:**
   - `rewrite --new-host` preserves every existing tag on each snapshot (`auto`, `quick`, `profile=...`, `files=...`, `bytes=...`, `newest=...`, `incomplete`), so `backup.sh` and `check.sh` continue to recognize them.
   - Passing `--forget` removes the old `<wrong-host>` snapshot objects immediately and does **not** add the extra `rewrite` tag. (Using `RT` ensures the removed snapshot metadata files go to the Drive trash when `PRUNE_USE_TRASH=1`.)
   - If you run `R rewrite --host "<wrong-host>" --new-host "$BACKUP_HOST"` *without* `--forget` so you can inspect the new snapshots first, restic adds the tag `rewrite` to the new snapshots. Remove that extra tag and clean up the old host snapshots once verified (with human approval):
     ```bash
     R tag --remove rewrite --host "$BACKUP_HOST"
     RT forget --host "<wrong-host>" <old-snapshot-id>...
     ```
4. **Verify and resume:**
   ```bash
   R snapshots --host "$BACKUP_HOST"
   rm -f "$GB_STATE/PAUSE"
   ./backup.sh
   ./status.sh
   ```
   Running `./backup.sh` refreshes `state/snapshots.json` and `state/manifest-remote.json` from the unified `$BACKUP_HOST` chain.
