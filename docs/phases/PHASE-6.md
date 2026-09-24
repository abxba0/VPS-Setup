# Phase 6 — Backup hardening

> Companion to `docs/PLAN.md` §Phase 6. Authoritative source: `docs/ARCHITECTURE.md` (§7 recovery, §17 golden rules). Track your progress in `docs/SETUP-TRACKER.md`. Do not start the next phase until Gate 6 passes.

## Your goal

Backup destruction is impossible even with a stolen writer credential (bucket lock holds server-side), `restic check` runs on schedule with failures alerting a human **off-box**, a **secondary backup at a different provider with different credentials** restores successfully, and the OVH-snapshot-before-upgrade discipline is codified in the change template. Phase 0.5 proved backups *work*; this phase proves they **survive an attacker who has them**.

## Non-negotiables this phase enforces

- **#2 — Browser profiles/cookies never in backups.** Exclusions are *re-verified here*, not assumed from Phase 0 — directory renames and new profiles silently break `--exclude` patterns.
- **#7 — Restore proven before anything depends on backups** — now from the *secondary* copy too.
- **Golden rule: recovery secrets escrowed offline** — the prune/admin credential never lives on the VPS; the credential-separation table (ARCHITECTURE §7) is the specification.
- **Ordering constraint:** no major upgrade (OVH snapshot path) may be taken before this phase's credential separation is confirmed. The secondary backup uses **different credentials and a different provider** — a second copy at the same provider with the same token is a copy, not a backup.

## Why this phase matters

Phase 0.5 proved backups work. Phase 6 proves they survive **G** (stolen writer credential) and **K** (deliberate backup destruction, incl. ransomware-style `forget --prune`). The controls are separation of powers: the VPS holds only a writer that cannot prune or delete; prune/admin lives off-box; retention/lock makes recent snapshots immutable even against the writer; and a second, differently-credentialed copy ensures no single provider or credential theft removes your recovery. This is also where retention becomes a privacy decision — deleted data lives on in snapshots until expiry (§11).

Threats reduced: **G** (credential thief — writer token alone cannot destroy), **K** (backup destruction — bucket lock + append-only writer), **H** (VPS compromise — nothing on the box can delete history), **I** (operator error — scheduled integrity checks catch rot early).

## Before you start

- Gate 0 passed: `hermes-backup.timer` runs daily, Healthchecks heartbeat green, laptop-side restore verified (`scripts/README.md` Step 4).
- Phase 2 passed: offline kit (two locations) contains the restic repo password, the R2 recovery credential, and the R2 prune/admin credential.
- You have a laptop able to run `restic`/`aws` CLI against R2, and a Healthchecks.io account with integrations ready (full wiring lands in Phase 7 — the pings created here will already alert by email).
- Working directory: the `vps-setup` repo; scripts already reviewed per `scripts/README.md`.

## Credential map

| Credential | Level | Lives where | Must NEVER live |
|---|---|---|---|
| R2 writer token (bucket-scoped, write-only) | L3 | VPS, `/etc/restic-backup.env` (0600 root), backup service env only | Git, agent contexts, `/srv/hermes/*` |
| R2 admin/prune token (forget/prune) | L4 | Laptop only (manual ops via OpenTofu/console) | VPS — including the broker |
| Recovery credential (restore-capable) | L4 | Offline kit, both physical locations | VPS |
| Secondary provider credentials | L3/L4 | Laptop + offline kit; `/etc/restic-secondary.env` (0600 root) on VPS for the writer | VPS agent-readable files; co-stored with R2 credentials in one file |
| Restic repo password(s) | L4 | Offline kit (+ `/etc/restic-repo.pass` on VPS for writer use) | In the backed-up tree itself |

**Ordering rule:** the prune/admin token is used from the laptop, manually. Its presence anywhere on the VPS converts any VPS compromise (threat **H**) into total backup loss (**K**).

## Steps

### 1. Credential separation audit (table from ARCHITECTURE §7)

Fill in this table and verify each row empirically — permissions are proven, not inferred:

| Credential | Location | Verified how |
|---|---|---|
| Writer (bucket-scoped rw, no delete-admin) | VPS `/etc/restic-backup.env` | `restic snapshots` works; attempt `restic forget --dry-run` from VPS → **must fail** (bucket lock / no-delete token) |
| Admin (forget/prune) | **laptop only** | `restic forget --prune --dry-run` works from laptop |
| Recovery | offline kit | kit drill (Phase 2) |
| Cloudflare admin | laptop/OpenTofu only | `grep -r` on VPS finds nothing |

### 2. R2 bucket lock + retention

In the R2 bucket settings, enable object retention/lock (compliance mode, e.g. 7–14 days minimum so a thief can't wipe recent snapshots even with account access; 30 d stronger). Reconcile with recovery retention: lifecycle rules must **not** delete objects earlier than the 6–12 monthly tier needs. Document the interplay: restic `forget --prune` from the laptop **will be refused by the lock for recent snapshots** — that is correct behavior; prune operations target only snapshots past the lock window.

### 3. `restic check` scheduling

Create `/etc/systemd/system/hermes-restic-check.service` and `.timer`:

```ini
# hermes-restic-check.service  (MemoryMax=512M, Nice=10, IOSchedulingClass=idle)
[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'set -a; . /etc/restic-backup.env; restic check && curl -fsS -m 10 "$HEALTHCHECKS_CHECK_URL" || curl -fsS -m 10 "$HEALTHCHECKS_CHECK_URL/fail"'
```

```ini
# hermes-restic-check.timer
[Timer]
OnCalendar=Sun *-*-* 03:30
Persistent=true
```

And a monthly deeper read — second timer, `OnCalendar=*-*-01 04:00`, running `restic check --read-data-subset=10%` (or a fixed pack count, e.g. `--read-data-subset=2000`, to bound runtime on a small box).

**Ping pattern:** the check service pings Healthchecks **on completion**; failure → ping `/fail`. A failing check = incident, not a log line. Wire `OnFailure=` to a `hermes-alert@%n.service` helper (Phase 7) as well.

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now hermes-restic-check.timer
restic check ; echo "rc=$?"
restic check --read-data-subset=5% ; echo "rc=$?"
```

**Failure-path test:** run once with a broken repo env var → confirm the `/fail` ping fires and Healthchecks turns red and alerts you.

### 4. Secondary backup provider (different provider, different credentials)

Options for a solo 4 GB box:

- **Backblaze B2:** cheapest per GB, native S3 API, easy second restic repo. Create repo #2, its own password, its own app key scoped to that bucket. Run a second restic backup (same `--tag`, different repo) in the same timer unit, **sequentially after** repo #1 — never in parallel.
- **rsync.net:** explicitly supports **append-only** restic repos (their docs document the restricted-filesystem setup) — the strongest "thief can't destroy history" posture; slightly pricier (~£1–3/mo at this scale).
- **Hetzner Storage Box:** cheap, supports restic/Borg via SFTP; different country/provider from R2 — good jurisdictional diversity.

Recommendation: **rsync.net append-only** if budget allows, else B2. Either way: **different provider, different credentials, never co-stored in the same env file** — the secondary's env goes in `/etc/restic-secondary.env` (0600 root), sourced only by the backup unit:

```bash
sudo tee /etc/restic-secondary.env >/dev/null <<'EOF'
export RESTIC_REPOSITORY="<secondary-repo-url>"
export RESTIC_PASSWORD="<secondary-repo-password>"
export AWS_ACCESS_KEY_ID="<secondary-key-id>"
export AWS_SECRET_ACCESS_KEY="<secondary-key-secret>"
EOF
sudo chmod 600 /etc/restic-secondary.env
sudo bash -c 'set -a; . /etc/restic-secondary.env; restic init'
```

Extend `hermes-backup.sh` to run repo #2 after repo #1 and extend the Healthchecks grace to cover the doubled window.

**Gate test:** full restore from the secondary to laptop with *only kit-held* secondary credentials:

```bash
restic -r <secondary-repo> --password-command 'pass show restic/secondary' \
  restore latest --target /tmp/sec-verify
diff -qr /srv/hermes/research /tmp/sec-verify/srv/hermes/research && echo SECONDARY_RESTORE_OK
```

### 5. Exclusions re-verified (browser profiles/cookies never in backups)

```bash
sudo bash -c 'set -a; . /etc/restic-backup.env; restic backup --dry-run /srv/hermes 2>&1 | grep -iE "browser|cookie"'
# expect: no output (or only the exclude-pattern lines)

restic snapshots --json | jq -r '.[].paths[]' | grep -i 'browser\|cookie' ; echo "rc=$?"
# expect rc=1 (none present)
```

Deep check: restore the latest snapshot to `/tmp` and confirm no cookie files exist in it. Re-run the exclusion checks after **any** profile change or browser-directory rename.

### 6. OVH snapshot discipline

Snapshot before every major upgrade — write it into the change template as a **blocking checkbox** ("OVH snapshot taken, id: ___"). Snapshot = fast rollback; Restic = durable DR; neither replaces the other. Start the habit now, even mid-phase.

### 7. 4 GB budget notes

`restic check --read-data-subset=10%` on a Sunday 03:30 window: network-bound, RAM ≤512 MB capped, disk I/O modest — it doesn't compete with anything in the quiet hour. The secondary backup doubles the backup window's bandwidth and some RAM churn — sequential only. Restic's local cache (`~/.cache/restic` or `/var/cache/restic`) grows with repo size — set `RESTIC_CACHE_DIR` to a capped location and add a monthly `restic cache --cleanup` (or size alert) to the maintenance script.

## Adversarial verification (run these attacks)

**A6-1 · Stolen-writer simulation (the headline test).** Copy the R2 *writer* credential to an "attacker" machine (laptop VM). Attempt destruction with only the writer:

```bash
export AWS_ACCESS_KEY_ID=<writer> AWS_SECRET_ACCESS_KEY=<writer>
aws s3api delete-object --bucket hermes-backups --key <recent-object-key>     # expect AccessDenied
aws s3api put-object --bucket hermes-backups --key restic/config --body /tmp/garbage   # expect denied (overwrite)
restic -r r2-bucket snapshots ; restic forget --keep-last 1 --prune            # expect failure at prune/delete
```

- **PASS:** delete/overwrite/prune all denied by R2 IAM *and* by bucket lock/retention (object lock rejects delete-within-retention even for accounts that otherwise have delete rights on older objects); snapshots intact (`restic snapshots` from recovery credential shows full history).
- **FAIL:** writer can prune, delete, or overwrite the current snapshot — the credential is over-scoped; rescope and re-test.

**A6-2 · Bucket lock / retention proof.** With the *admin* credential (from laptop, not VPS), attempt to delete a snapshot inside the lock window: `restic forget --prune` (or S3 object-delete on the newest object).

- **PASS:** R2 refuses ("object is protected by retention/object lock"); the control holds even against the *admin* for the protected period.
- **FAIL:** admin can delete recent backups (lock not applied — this is the threat-K control; fix before proceeding).

**A6-3 · Secondary backup drill.** Restore a file from the secondary provider using its separate credentials.

- **PASS:** restores; credentials genuinely independent (different provider, different account, not sharing a root key).
- **FAIL:** secondary is a copy inside the same account (single failure domain) or has never been restored.

**A6-4 · Backup content audit (privacy rule 31-#2).**

```bash
restic ls latest | grep -iE 'cookie|profile|\.mozilla|\.config/google-chrome|session'
```

- **PASS:** empty — browser profiles/cookies excluded; also check the exclude list in your backup script config.
- **FAIL:** cookie jars present — a leaked backup would be a leaked login.

**A6-5 · Integrity.** Run `restic check` and `restic check --read-data-subset 5%`; confirm the Healthchecks ping for *check* success is separate from the backup heartbeat.

- **PASS:** check clean; corruption would (in a test — corrupt a scratch repo copy) alert a human off-box.

**A6-6 · OVH snapshot before-upgrade rehearsal.** Take a snapshot, boot a test from it (or verify it exists and mounts/boots per OVH docs).

- **PASS:** snapshot exists, is restorable, and is *not* counted as your durable backup (Restic is; snapshot is fast-rollback only).

**Cross-checks from the architect (run WITH the writer token only):**

```bash
# 1) Writer token cannot prune/delete:
restic forget --keep-last 3 --dry-run ; echo "rc=$?"   # expect failure (S3 DELETE denied) — record output
aws s3api delete-object --endpoint-url "https://<ACCOUNTID>.r2.cloudflarestorage.com" \
  --bucket <bucket> --key $(restic snapshots --json | jq -r '.[0].id') --debug 2>&1 | grep -i denied
# If delete SUCCEEDS, your R2 token is too broad -> re-scope (Object Write-only or bucket-scoped) and re-test.

# 2) Bucket lock: attempt to overwrite a locked recent object -> must fail
aws s3api put-object ... --debug 2>&1 | grep -i 'lock\|denied'
```

## Pitfalls

1. **Writer token that can delete.** R2 token scoping must be verified empirically (the delete-object test above), not inferred from the permission label. If "Object Read & Write" turns out to include delete on your setup, re-scope and lean on bucket lock/retention — and record the residual risk.
2. **Prune credential "conveniently" left on the VPS** after setup. Its presence converts any VPS compromise (H) into total backup loss (K). Off-box, used manually from the laptop.
3. **Exclusions drift.** A new profile or a renamed browser dir silently re-includes cookies in backups. Re-run the exclusion checks after *any* profile change, and do the restore-and-grep deep check periodically.
4. **`restic check` without `--read-data-subset`.** Metadata-only checks miss silent bit-rot in pack files. The data-subset read is what catches a corrupted restore three months before you need it.
5. **Secondary backup wired to the same alerts and same laptop-held password as primary** — shared failure modes. Different provider, different credentials, and confirm its restore path works *without* anything from the primary stack.
6. **Bucket lock blocks a *legitimate* laptop prune:** expected; prune only snapshots past the lock window. If you truly need to delete recent data (privacy incident — ARCHITECTURE §14), the procedure is: R2 dashboard → object retention exception (account admin, from laptop) → delete → log the action in the decisions log. The friction is intentional.
7. **`restic check` finds errors** (`pack ID does not match`, integrity warnings): stop, do **not** prune. Run `restic check --read-data` fully on the affected range; if corruption is confirmed, the correct recovery is **re-backup the affected paths as a new snapshot** from the still-good source, then (from laptop, admin cred) prune the corrupt snapshot after the lock window — and investigate *why* (unattended reboot mid-write? disk error? `dmesg` for I/O errors).
8. **Secondary provider outage during backup:** the sequential unit fails partway → Healthchecks red → fix is wait-and-rerun; repo #1 is independent and green — that independence is the whole design.
9. **Cache directory fills the disk:** disk-full during backup = failed snapshot + possible repo churn; keep `RESTIC_CACHE_DIR` on a monitored path; `df -h /` alert lands in Phase 7.

## Gate 6 — honest pass checklist

From `docs/PLAN.md` Gate 6: *simulate losing the VPS R2 writer credential → prune still impossible with the stolen writer credential (bucket lock holds); restore from the secondary copy succeeds.*

- [ ] Credential-separation audit table filled, every row verified empirically (A6-1 + cross-checks).
- [ ] Stolen-writer simulation: `restic forget`/prune and raw S3 delete **all refused** from the VPS with the writer credential — output captured.
- [ ] Bucket lock/retention active and proven: admin-credential delete inside the lock window refused (A6-2) — denial captured.
- [ ] Writer key **rotated** after the drill (new token, env updated, one manual backup run); prune-from-laptop still works for unlocked snapshots.
- [ ] Secondary copy restore succeeds to laptop with only kit-held secondary credentials; checksums match (same diff method as Phase 0.5) — diff output captured.
- [ ] Exclusion re-verification: dry-run grep empty; `restic snapshots --json` shows no browser/cookie paths (A6-4).
- [ ] `restic check` timer live; forced-failure test turned the Healthchecks check red and alerted you off-box; then green again.
- [ ] OVH snapshot exists and is dated; change template now carries the blocking snapshot checkbox.

**Fake-pass warnings:**
- (a) Running the prune attempt as root with the *admin* token — the test is specifically "with the **writer**."
- (b) Secondary restore tested against the *primary* repo — it must be the secondary's repo URL, password, and credentials.
- (c) Bucket lock "configured" but never tested — attempt the mutation, capture the denial. Every denial you can't produce on demand is a control you don't have.

**Evidence to record in `docs/SETUP-TRACKER.md` + ops log:** date, A6-1…A6-6 results (PASS/FAIL with command transcripts), secondary repo provider + credential independence note, writer-key rotation date, check-timer HC check name, snapshot id.

## Learner's corner

**What you'll learn in this phase**

- Credential capability separation as applied IAM: writer/admin/recovery as three different *identities*, not three passwords.
- R2 object lock / retention ("bucket lock") semantics — WORM storage as ransomware defense.
- Restic integrity model: `restic check`, data-subset verification, why integrity failures are incidents.
- Backup-as-privacy: exclusions are a data-minimization control.
- Snapshot vs. backup: rollback speed vs. durability, and why neither substitutes for the other.

**Concept primer.** The backup threat model changed the moment you asked "what if the *backup credential* is stolen?" (threats G/K). A single credential that can write *and* delete means theft converts to total loss — so you split capabilities across identities: the VPS writer appends snapshots but structurally cannot prune; the admin/prune credential lives on your laptop; the recovery credential (offline) can read. Bucket lock adds a second, independent control: object lock makes recent objects immutable *at the storage layer* for a retention period, so even a correct-pruning attacker (or a bug in your own prune job, or ransomware on the box) cannot delete this week's snapshots — two mechanisms must fail before history is lost. Integrity closes the loop: a backup that restores garbage is worse than none, so `restic check` (and sampled data reads) run on schedule with their own external heartbeat. Finally, exclusions are privacy engineering: browser cookie jars *are* authenticated sessions; including them means any backup compromise is a login compromise.

**Check-your-understanding**

1. Why can a write-only writer credential still produce a fully restorable backup, given it can never prune?
   *Answer: restic's repo is append-only by design — new snapshots only add content-addressed chunks and index entries; deletion is a separate operation (forget/prune) requiring separate rights. Restore needs read + the (offline) repo password, neither of which the writer needs to hold. Appending is sufficient for durability; pruning is the destructive power you've removed.*
2. Bucket lock exists *and* the writer is write-only. Why keep both — what attack does each alone miss?
   *Answer: write-only writer stops a stolen *writer* key from deleting, but can't stop a compromised admin credential or an attacker who escalates in R2 IAM. Bucket lock stops deletion during the lock window regardless of which key is used, but an attacker with admin can still wait out retention or corrupt *future* objects past lock expiry. Together: different failure modes, no common bypass.*
3. Your OVH snapshot is newer than your last Restic snapshot. Why is it not a substitute for the failed Restic backup?
   *Answer: snapshots live in the same account/infrastructure as the VPS (OVH) — a provider problem, billing lapse, account compromise, or regional failure hits both. Snapshots are fast local rollback; Restic-to-R2 (+secondary) is durable, independently-credentialed DR. The failure they insure against (threats J/H/K) is precisely "OVH itself is gone or hostile."*

**Do-it-yourself habit.** Write the "credential capability matrix" by hand before configuring R2: rows = writer/admin/recovery, columns = put/get/delete/prune/list. Fill in allowed/denied for each, then verify the real IAM policy against your matrix — any cell that differs from your intent is a finding to fix or to consciously accept with a written reason.

## Steady state added by this phase

| Cadence | Task | Wiring |
|---|---|---|
| Daily | Primary backup (existing timer) | Healthchecks heartbeat |
| Weekly | `restic check` | `hermes-restic-check.timer` + HC ping |
| Monthly | `--read-data-subset=10%` deep read + cache cleanup + secondary repo verify | second timer + HC |
| Quarterly | Secondary-restore drill to laptop | Calendar + HC `secondary-restore-drill` |
| Biannual | Retention/privacy review (ties to Phase 2 kit review) | Calendar |
| Every upgrade | OVH snapshot first | change template checkbox |
