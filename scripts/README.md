# Phase 0 operator runbook — scripts/

Order matters. Follow PLAN.md `docs/PLAN.md` Phase 0. Each numbered step maps
to a PLAN.md subsection. Nothing here places secrets in the repo.

## Script index — what each one does, in the order you run them

| # | Script | When (Phase) | What it does | Safety net |
|---|---|---|---|---|
| 1 | `cloud-init/user-data.yaml` | First boot (0.2) | Pasted into the OVH install panel. Creates the `deploy` sudo user (your SSH key only, password auth off), installs packages, writes an sshd hardening drop-in, an **interim** nftables INPUT firewall (22 open from anywhere so first contact works), pinned DNS, unattended security updates. | Runs once at install; a stale placeholder key = lockout, so verify before pasting. |
| 2 | `scripts/tailscale-setup.sh` | Phase 0.2 | Installs Tailscale on the VPS, joins your tailnet with `--advertise-tags=tag:hermes-vps --ssh` (Tailscale SSH enabled), prints an auth URL. After you approve the node in the admin console: disable key expiry, restrict ACLs. | Break-glass = OVH KVM/rescue, independent of Tailscale. |
| 3 | `scripts/restrict-ssh.sh` | Phase 0.2/0.3 — **run this NOW; your box's next step** | The SSH cutover: adds an nftables `ssh_guard` table that accepts tcp/22 ONLY via loopback (Cloudflare Access → cloudflared tunnel → `ssh://localhost:22`) and `tailscale0` (Tailscale SSH). Direct SSH by public IP is logged (`ssh-guard-drop: `) and dropped. Coexists with UFW (its allow-22 is superseded; drop in any base chain is final) and fail2ban. Subcommands: `apply` / `confirm` / `rollback` / `status`. | 5-minute `at` timed-flush rollback; resilient restore (nft snapshot, or flush + UFW restart if UFW is active — tested 2026-09-26). |
| 4 | `scripts/setup-nftables.sh` | Phase 0.3 (after step 3 is confirmed) | The FULL reviewed firewall policy, replacing the interim one: INPUT/FORWARD/**OUTPUT** default-drop; INPUT allows loopback, established, rate-limited ICMP, Tailscale UDP, tcp/22 **only via tailscale0**; OUTPUT allows loopback, established, tailnet, pinned DNS resolvers, pinned NTP, HTTPS/HTTP (interim, narrowed in Phase 3), Tailscale transport — private/metadata ranges hard-dropped first; all denials logged with counters. Subcommands: `apply` / `confirm` / `rollback`. | 5-minute `at` timed-flush rollback (`atq` MUST show the job before you rely on it). Warns if UFW would break its snapshot. |
| 5 | `scripts/backup.sh` (+ `restore-test.sh`, `systemd/*`) | Phase 0.5 | Daily Restic backup of the platform to Cloudflare R2 (browser profiles/cookies excluded) with a Healthchecks.io heartbeat; `restore-test.sh --deep` proves the restore. | Write-only R2 writer token; prune/admin creds never on the VPS. |

`scripts/hardenning.sh` is the UFW/fail2ban/TMOUT baseline you already ran (kept
as a record; not part of the forward runbook — its UFW layer is retired in
Step 3's follow-up).


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

## Your current position (as of 2026-09-26)

- VPS provisioned; Cloudflare Tunnel + Access SSH working; Tailscale installed
  next (or already). `scripts/hardenning.sh` applied: UFW (deny in / allow out,
  **public "allow 22/tcp"**), fail2ban sshd jail, 15-min Bash TMOUT.
- **Next action = Step 2.5** (the `restrict-ssh.sh` cutover). Step 3 follows,
  then its UFW-retirement follow-up. Steps 1 and 4 remain as documented.

## Step 2.5 — SSH access cutover: two identity-gated paths (Phase 0.2/0.3)

Target model (founder decision 2026-09-26; ARCHITECTURE §6/§18): SSH is
reachable ONLY via two identity-gated paths — (1) Cloudflare Access →
cloudflared tunnel → `ssh://localhost:22` (arrives on loopback), (2) Tailscale
SSH (arrives on tailscale0). Direct SSH by public IP is denied and logged.

BEFORE applying, open and verify BOTH approved paths in separate terminals:

```bash
# Path 1 — Cloudflare Access SSH (from laptop):
cloudflared access ssh --hostname ssh.<domain>   # or the browser SSH app
# Path 2 — Tailscale SSH (from laptop):
sudo bash scripts/tailscale-setup.sh             # prints an auth URL
ssh deploy@<100.x.y.z>
```

Then, from an APPROVED session (never from direct-IP SSH — existing direct-IP
sessions terminate on apply):

```bash
sudo bash scripts/restrict-ssh.sh apply          # 5-min auto-rollback armed
# WARNING: direct-IP SSH sessions terminate on apply.
```

Verification inside the 5-minute window:

```bash
sudo bash scripts/restrict-ssh.sh status         # guard table + recent drops
# From a phone hotspot / external network (never the VPS):
nmap -Pn -p22 <public-ip>                        # expect: filtered
ssh deploy@<public-ip>                           # expect: timeout (denied)
# Both approved paths still work: CF Access session + tailnet session.
sudo bash scripts/restrict-ssh.sh confirm        # keep rules + disarm rollback
```

Follow-up (recommended): the full Phase 0.3 policy in Step 3 supersedes this
guard (its INPUT rules already restrict tcp/22 the same way). After that
policy is confirmed + `systemctl enable nftables` + a reboot test pass, run
`sudo ufw disable` to retire the UFW layer from `scripts/hardenning.sh` (its
"allow 22/tcp" is superseded either way; one firewall manager only). fail2ban
may stay.

Break-glass: OVH KVM console and rescue mode boot an independent environment —
unaffected by this change.

Evidence: record the scan output, a `ssh-guard-drop:` journal line, and dates
in docs/SETUP-TRACKER.md (Gate 0b evidence). **Sandbox-tested 2026-09-26**
(Ubuntu 24.04 + systemd + nftables 1.0.9 + atd + UFW): external 22 denied and
counted; loopback banner OK; guard coexists with UFW; timed flush restores
the prior state; rollback/idempotency verified.

## Step 3 — Firewall (Phase 0.3)

```bash
sudo bash scripts/setup-nftables.sh apply     # 5-min auto-rollback armed
# atq MUST show the job before you proceed — empty atq = no failsafe = stop.
# TEST: SSH still works via Tailscale; DNS works; apt update works;
#       outbound to a non-allowed port is logged/dropped (check dmesg/journal).
sudo bash scripts/setup-nftables.sh confirm   # keep rules + disarm rollback
sudo systemctl enable nftables                # survive reboot (then reboot + re-test)
# If you got locked out: the 'at' job already restored the old rules, or
# (OVH console/KVM): sudo bash scripts/setup-nftables.sh rollback
```

After Step 3 is confirmed and reboot-tested — retire the UFW layer:

```bash
sudo ufw disable                              # one firewall manager only
sudo systemctl disable ufw                    # (fail2ban may stay)
```

The timed-flush rollback was exercised end-to-end in the 2026-09-26 sandbox
battery (apply → deadline → auto-restore, with and without UFW present).

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

## Run order cheat-sheet (from your current state)

```bash
# 0. (once) Verify BOTH approved SSH paths from your laptop:
cloudflared access ssh --hostname ssh.<domain>     # Path 1: CF Access
sudo bash scripts/tailscale-setup.sh               # Path 2 (skip if done); then:
ssh deploy@<100.x.y.z>

# 1. Close public SSH (run FROM an approved session, NOT direct-IP SSH):
sudo bash scripts/restrict-ssh.sh apply            # 5-min rollback armed
#    verify from a hotspot: nmap -Pn -p22 <public-ip> (filtered),
#    ssh deploy@<public-ip> (timeout); approved paths still OK
sudo bash scripts/restrict-ssh.sh confirm          # within 5 minutes

# 2. Full firewall (in AND out default-deny):
sudo bash scripts/setup-nftables.sh apply          # atq must show the job
#    test: tailnet SSH, DNS, apt update, outbound deny+log
sudo bash scripts/setup-nftables.sh confirm
sudo systemctl enable nftables && sudo reboot      # re-test after reboot

# 3. Retire UFW (after the reboot test):
sudo ufw disable && sudo systemctl disable ufw     # fail2ban may stay

# 4. Backups (after R2 bucket + Healthchecks.io check exist):
sudo bash scripts/... (see Step 4 block below)     # restic init BEFORE the timer
sudo /usr/local/sbin/hermes-restore-test.sh --deep # GATE 0: must PASS
```

## Hard reminders

- Backup writer credential: write-only; **no prune/delete ever on the VPS**.
- Healthchecks.io ping URL is in the env file; the check must alert on missed
  heartbeat (set the grace period in Healthchecks.io).
- OVH snapshot before any major upgrade (Phase 6 discipline, start early).
- Direct/public SSH by IP is denied (restrict-ssh.sh); admin SSH is
  identity-gated only (CF Access + Tailscale).
