# Phase 0 operator runbook — scripts/

Order matters. Follow PLAN.md `docs/PLAN.md` Phase 0. Each numbered step maps
to a PLAN.md subsection. Nothing here places secrets in the repo.

## Step 1 — First login after OVH provisioning (Phase 0.2)

OVH panel -> install with `cloud-init/user-data.yaml` (replace the SSH key
placeholder first). Then from your laptop:

```bash
ssh deploy@<public-ip>        # first contact via public IP
```

## Step 2 — Tailscale (Phase 0.2)

```bash
sudo bash scripts/tailscale-setup.sh        # prints an auth URL
# In Tailscale admin console: approve node, DISABLE KEY EXPIRY (documented
# exception, ARCHITECTURE §6), restrict ACLs to operator devices.
# From now on: ssh deploy@<100.x.y.z> via Tailscale; public SSH is blocked next.
```

## Step 3 — Firewall (Phase 0.3)

```bash
sudo bash scripts/setup-nftables.sh apply     # 5-min auto-rollback armed
# TEST: SSH still works via Tailscale; DNS works; apt update works;
#       outbound to a non-allowed port is logged/dropped (check dmesg/journal).
sudo bash scripts/setup-nftables.sh confirm   # keep rules + disarm rollback
# If you got locked out: the 'at' job already restored the old rules, or
# (OVH console/KVM): sudo bash scripts/setup-nftables.sh rollback
```

## Step 4 — Backup + restore test (Phase 0.5)

Prerequisites (you, outside the VPS):
1. Cloudflare R2: create bucket with **bucket lock/retention**; create a
   **bucket-scoped, write-only** API token for it. (Admin/prune creds stay
   off the VPS — ARCHITECTURE §7.)
2. Healthchecks.io: create a check; note its ping URL.

On the VPS (values from step 1 — these are the ONLY places secrets live,
root-owned 0600, never in this repo):

```bash
sudo install -m 700 scripts/backup.sh /usr/local/sbin/hermes-backup.sh
sudo install -m 700 scripts/restore-test.sh /usr/local/sbin/hermes-restore-test.sh
sudo install -m 644 scripts/systemd/hermes-backup.service /etc/systemd/system/
sudo install -m 644 scripts/systemd/hermes-backup.timer /etc/systemd/system/

sudo tee /etc/restic-repo.pass >/dev/null <<< "$(openssl rand -base64 32)"
sudo chmod 600 /etc/restic-repo.pass

sudo tee /etc/restic-backup.env >/dev/null <<'EOF'
export RESTIC_REPOSITORY="s3:https://<account>.r2.cloudflarestorage.com/<bucket>"
export RESTIC_PASSWORD_FILE="/etc/restic-repo.pass"
export AWS_ACCESS_KEY_ID="<r2-writer-key-id>"
export AWS_SECRET_ACCESS_KEY="<r2-writer-secret>"
export HEALTHCHECKS_URL="https://hc-ping.com/<uuid>"
EOF
sudo chmod 600 /etc/restic-backup.env

# restic is installed by cloud-init; verify, then INITIALIZE the repo
# BEFORE enabling the timer (panel follow-up: restic init is required before
# the first backup, and Persistent=true would fire the service immediately).
restic version   # requires >= 0.16 (older versions need extra R2 env)
sudo bash -c 'set -a; . /etc/restic-backup.env; restic init'
sudo systemctl daemon-reload
sudo systemctl enable --now hermes-backup.timer
sudo /usr/local/sbin/hermes-backup.sh          # first run
sudo /usr/local/sbin/hermes-restore-test.sh --deep   # GATE 0: must PASS
```

Notes:
- In Healthchecks.io set the check to period 1 day / grace ≥ 2 h (the timer
  randomizes by up to 15 min and the backup itself takes time).
- The repo password (`/etc/restic-repo.pass`) must ALSO be recorded in the
  offline recovery kit (Phase 2) — without it the backup is unrestorable.
- After this passes, perform the LAPTOP-side restore with the offline
  recovery credential — that is the true Gate 0 DR test (Phase 2/8).
- R2 credential scoping (panel finding, corrected): the writer token is
  bucket-scoped read/write (restic must read repo metadata) but must NOT be
  able to delete or administer. Deletion protection comes from the R2
  bucket lock/retention, enforced server-side by Cloudflare.

Record the result in docs/SETUP-TRACKER.md. Gate 0 requires a PASS.

## Hard reminders

- Backup writer credential: write-only; **no prune/delete ever on the VPS**.
- Healthchecks.io ping URL is in the env file; the check must alert on missed
  heartbeat (set the grace period in Healthchecks.io).
- OVH snapshot before any major upgrade (Phase 6 discipline, start early).
