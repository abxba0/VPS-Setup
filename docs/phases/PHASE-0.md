# Phase 0 — Minimum viable tier

> Companion to `docs/PLAN.md` §Phase 0. Authoritative source: `docs/ARCHITECTURE.md`. Track your progress in `docs/SETUP-TRACKER.md`. Do not start Phase 1 until Gate 0 passes.

## Your goal

At the end of Phase 0 the machine is reachable **only** through Tailscale (public SSH closed), both firewall directions are default-deny with logging, Hermes runs non-root in a sandboxed unit with one research profile limited to credential-free web reads, and — critically — a **full restore has been proven from the laptop using offline-held credentials** with a visible backup heartbeat in Healthchecks.io. The two protections this phase builds — a default-deny network perimeter and a *proven* restore — are exactly the ones that fail catastrophically if retrofitted. Nothing in later phases may depend on any unproven assumption made here.

## Non-negotiables this phase enforces

From `PLAN.md` §Non-negotiables, the ones this phase enforces or preconditions:

- **#5 — Egress default-deny; every profile matches the trust table.** Phase 0.3/0.4 build it for the research profile.
- **#7 — A restore must be proven before anything depends on backups.** Phase 0.5 is this proof; Gate 0's restore line is not decorative.
- **#6 (precondition) — Recovery material escrowed offline before any agent runs.** Not fully closed until Phase 2 — see the ordering note below. Phase 0's only agent profile is allowed to run early *because* it is credential-free.
- **#2 — Browser profiles/cookies never in backups.** Enforced from the very first backup (exclusions in `scripts/backup.sh`).
- **#8 (precondition) — Monitoring independent of the VPS.** The backup heartbeat lives in Healthchecks.io from day one.

**Ordering clarification (important):** Non-negotiable #6 says recovery material is escrowed before *any agent runs*. The Phase 0.4 research profile is allowed to run before Phase 2 *only because* it holds no credentials, no private data, and no send-capable tools — the research trust-rule row (ARCHITECTURE §8) is what makes the ordering legal. The moment any profile gains a credential, private data, or an L2+ capability, Phase 2's escrow gate must already be passed. Never relax this by giving the research profile "just one" API key early.

## Why this phase matters

Phase 0 builds the two protections that fail catastrophically if retrofitted: a default-deny network perimeter (both directions) and a *proven* restore. A firewall you can always weaken retroactively is worthless unless the deny is the default; a backup that has never been restored is a hope, not a control. In threat terms (ARCHITECTURE §4 IDs):

- Inbound default-deny + Tailscale-only SSH removes nearly all of **A** (internet attacker exploiting exposed services).
- Egress default-deny is the *primary* containment for **C** (indirect prompt injection → exfiltration) and limits **H** (VPS compromise) from phoning home.
- The tested restore directly targets **I** (operator error) and **K** (backup destruction) by making recovery a demonstrated fact before anything valuable depends on it.

This phase is deliberately the "minimum viable" tier: the research profile it enables is credential-free and private-data-free, so it satisfies the profile trust rule even before the full isolation stack exists (decision logged in ARCHITECTURE §18).

## Before you start

**Prerequisites (Phase 0.1 — mostly DONE per `SETUP-TRACKER.md`):**

- [x] Git repo for IaC + Gitleaks pre-commit hook, verified, history clean (Gate 0a partial).
- [x] OVH account (4 GB VPS paid, awaiting provisioning), Cloudflare + domain, Tailscale, Infisical, Healthchecks.io accounts.
- [ ] **You still owe:** verify OVH TOTP backup + recovery email/phone are set; verify Tailscale passkey/MFA. (Two FIDO2 hardware keys are deferred to Phase 1.)

**Hard ordering constraints:**

- **No L2+ capability, no credential, and no private data in any profile before Phase 2.** The research profile is web-reads-only, credential-free.
- **No public SSH disabling until Tailscale SSH is proven working** (test from your laptop over the tailnet *first*, then restrict).
- **No restic schedule wired into Healthchecks until one full restore from the laptop has succeeded.** Gate 0's restore line is not decorative.
- **Nothing in this phase may write a secret to the Git repo** (Gitleaks hook exists — it must stay first in the hook chain, before the first commit — confirmed done).

**Already built and panel-reviewed — do NOT re-invent (see `scripts/README.md` for the existing runbook):**

- `cloud-init/user-data.yaml` — bootstrap, interim firewall, DNS pin, sshd drop-in.
- `scripts/setup-nftables.sh` — apply / confirm / rollback with 5-minute timed flush.
- `scripts/backup.sh`, `scripts/restore-test.sh`, `scripts/systemd/*` — backup + restore-test machinery.
- `scripts/tailscale-setup.sh` — Tailscale install/auth.

## Credential map

| Credential | Level | Lives where | Must NEVER live |
|---|---|---|---|
| SSH key(s) (admin) | L3 | Laptop; `authorized_keys` on VPS initial user | Git repo, agent workspaces, shared folders |
| Tailscale auth key (node join) | L3 | Used once at 0.2, then discarded/rotated | Git, shell history, agent env |
| Restic repository password | L4 (destroy/restore) | VPS: `/etc/restic-repo.pass`, mode `0600` root-only *until Phase 2*; **also copied to password manager immediately at 0.5** | Git, agent-readable files, plaintext notes, backup payloads themselves |
| R2 bucket writer token (S3 keys) | L3 | VPS `/etc/restic-backup.env`, `0600` root-only | Git, agent profiles, `/srv/hermes/*` |
| R2 recovery/prune-capable credential | L4 | **Laptop / offline kit only** — never sent to the VPS | VPS at any path, any agent context |
| Healthchecks.io check UUIDs | L1 | Backup env on VPS | — (UUIDs are write-beacons; fine on VPS) |
| Cloudflare / OVH / Tailscale / Infisical admin creds | L4 | Your head (passkeys + HW keys); laptop for OpenTofu | VPS, ever (golden rule 30) |

## Steps

Commands run from the VPS unless prefixed "on laptop". `<...>` placeholders are values you keep in your password manager, never in Git. Scripts referenced here already exist and are panel-reviewed — you are using and verifying them, not rewriting them.

### 0.2 — Provision & bootstrap (OVH + cloud-init)

1. **Pre-provision (on laptop, 10 minutes):** open `cloud-init/user-data.yaml`. Replace **every** placeholder — SSH key line, hostname, anything marked `REPLACE`. Gitleaks-check your edit: `gitleaks detect --source .` (the repo hook only fires on commits; run it manually too). Copy the entire YAML to the clipboard. Do **not** paste it into the OVH panel unedited — a stale placeholder key means locked out on first boot.
2. **Provision (OVH panel):** VPS → Reinstall → choose **Ubuntu 24.04 LTS**, paste the user-data into the cloud-init/post-installation field, confirm. Wait for the "installation in progress" to finish (5–15 min).
3. **First contact (from laptop, public IP — the *only* time public SSH is used):**
   ```bash
   ssh deploy@<public-ip>
   ```
4. **Verify cloud-init actually completed** (OVH gotcha: the panel reports "installed" before user-data finishes):
   ```bash
   cloud-init status --wait        # expect: status: done
   sudo less /var/log/cloud-init-output.log   # scan for module failures
   sudo systemctl status ssh --no-pager       # confirm drop-in applied: PasswordAuthentication no
   sudo sshd -T | grep -E 'passwordauthentication|permitrootlogin'   # expect: no / no
   ```
5. **Confirm the interim firewall from user-data is live and note what's open:**
   ```bash
   sudo nft list ruleset | head -60
   sudo ss -tlnp4    # what is listening now? Record it — this is your "before" picture.
   ```
6. **Rescue-mode / KVM verification — DO THIS NOW, while healthy:**
   - OVH panel → VPS → **KVM**: open the KVM console, confirm you can see the login prompt (you don't even need to log in — proof of out-of-band video access). Screenshot it.
   - OVH panel → **Boot in rescue mode** → reboot. OVH emails you temporary rescue credentials. In rescue:
     ```bash
     lsblk                       # your disk(s) visible, untouched
     mount /dev/sda1 /mnt && ls /mnt    # filesystem mounts read-only — proves recovery path works
     umount /mnt
     ```
   - OVH panel → boot back to **from hard disk** → reboot → verify normal SSH resumes. **Write the date in the operations log.** This drill is Phase 1's break-glass rehearsal #1 and it costs ~20 minutes today vs. hours under duress later.
7. **Tailscale.** From the VPS:
   ```bash
   sudo bash scripts/tailscale-setup.sh    # prints an auth URL
   ```
   In the Tailscale admin console: approve the node, apply **`tag:hermes-vps`**, and **disable key expiry** for this node (documented exception — ARCHITECTURE §6: unattended reachability vs. longer-lived node identity; mitigations: tag-scoped ACLs, OVH rescue path, monitoring, rotation). Verify from laptop:
   ```bash
   ssh deploy@<100.x.y.z>          # Tailscale path works
   tailscale status                # node tagged, expiry shown as "—"
   ```
8. **Prove the SSH surface before you lock it down:**
   ```bash
   # On the VPS: prove sshd is reachable via tailnet, and note the public binding
   sudo ss -tlnp | grep :22
   # From laptop (via tailnet):
   tailscale status && ssh <admin-user>@<tailscale-ip> 'echo TAILNET_SSH_OK'
   ```
9. **Non-root Hermes install (Phase 0.4 groundwork):** install Hermes under the `deploy` user or its own `hermes` user (never root). Follow the current Hermes docs; immediately wrap it in the systemd unit with the sandbox drop-ins from step 12 below.

### 0.3 — Firewall (in/out default-deny, timed-flush)

`scripts/setup-nftables.sh` already exists and is reviewed. Do **not** hand-edit rules today. Run every "deny" test from a second SSH session so a mistake can't strand you mid-verification.

10. **Sanity-check the prerequisites the script assumes:**
    ```bash
    systemctl is-active atd || sudo apt install -y at   # timed-flush depends on it
    which nft && nft --version
    ```
11. **Apply with the auto-rollback armed:**
    ```bash
    sudo bash scripts/setup-nftables.sh apply
    ```
    The script writes the known-good ruleset to file, arms an `at now + 5 minutes` restore job, then applies restrictive rules. **You now have a countdown. Work fast.**

    The timed-flush mechanics the script implements (verify the script against these invariants — they are why the pattern works):
    - `at` jobs survive session loss — that is the entire point; a `sleep 300 && nft …` background job dies with your SSH session and is **not** an acceptable substitute.
    - **`atq` empty before applying = you have no failsafe = stop.** Track the job ID; cancel explicitly with `atrm` when done.
    - After `nft flush ruleset` (or applying a file without base chains) the kernel default is **ACCEPT** — flush is always "get back in," never "lock out further," so the worst case of a bad rollback file is still recoverable via OVH console `nft flush ruleset`.
12. **Run the full test battery *within the 5-minute window*** (open a **second** SSH session before applying — keep it as a lifeline during testing):
    - SSH over Tailscale still works.
    - DNS resolves: `dig cloudflare.com +short`
    - Packages reachable: `sudo apt update` (completes without errors)
    - Tailscale control plane OK: `tailscale status` (no errors)
    - Hermes API reachable (if already installed): its health endpoint
    - Negative test — something not allowlisted is denied **and logged**:
      ```bash
      curl -m 5 --connect-timeout 3 https://example.com        # expect: timeout/refused if not allowlisted
      sudo journalctl -k --since '-3 min' | grep -iE 'NFT-DENY|deny|drop'   # logged denials
      ```
13. **All green before the deadline → confirm and disarm:**
    ```bash
    sudo bash scripts/setup-nftables.sh confirm
    sudo systemctl enable nftables && sudo systemctl status nftables   # survives reboot
    sudo reboot      # the REAL test: rules survive a boot
    ```
14. **After reboot, re-run the positive battery** (SSH/DNS/apt/Tailscale). Ruleset count check:
    ```bash
    sudo nft list ruleset | grep -c 'drop'     # compare to pre-reboot count
    ```
15. **Exercise the rollback deliberately at least once (Gate 0b requires it):** run `apply` again, do *not* confirm, do nothing, and watch the `at` job restore the previous ruleset at the deadline — verify in `journalctl -u atd` and that SSH never dropped. This converts the rollback from "theoretical" to "proven". Also test the "all good" path: remove the `at` job before deadline (`atrm <id>`) and confirm the restrictive rules persist.

### 0.4 — Research profile with egress limits

16. **Create the profile user and workspace:**
    ```bash
    sudo useradd -r -m -d /srv/hermes/research -s /usr/sbin/nologin hermes-research
    sudo chmod 0700 /srv/hermes/research
    sudo install -d -m 0750 -o hermes-research -g hermes-research /srv/hermes/quarantine
    ```
17. **Egress rules via nftables `meta skuid`** — extend the reviewed OUTPUT structure, don't fork it:
    ```bash
    # concept (verify against the DECISION block in scripts/setup-nftables.sh):
    # meta skuid hermes-research:
    #   allow: DNS (53 tcp/udp to pinned resolvers), 80/443 out (web reads)
    #   deny:  RFC1918, loopback, link-local, CGNAT, metadata endpoints  -> log
    #   deny:  everything else -> log
    sudo nft -c -f /etc/nftables.conf    # syntax-check BEFORE any reload
    ```

    Two `meta skuid` facts that prevent silent misdesign:
    1. User names in rules (`meta skuid "hermes-research"`) are resolved **at rule-load time** — if you create the user after loading nftables, the rule silently matches nothing. Prefer numeric UIDs captured at provisioning, or reload after user creation. After creating users, reload nftables and re-run one positive test per profile.
    2. `meta skuid` matches only locally-generated packets whose socket has an owner — unowned packets (some ICMP, raw sockets) do **not** match your allow rule and therefore fall through to `policy drop`. That is correct behavior; the final `policy drop` is what enforces the boundary, and your skuid rule is a grant, not the guard.
18. **Apply the extended ruleset through the same timed-flush discipline** (step 11–13 pattern: `apply` → test → `confirm`). The rollback habit does not retire after Phase 0.
19. **Hermes research profile service sandboxing — incremental, test after *each* line added** (restart, exercise Hermes, revert the last addition if it breaks):
    ```ini
    # /etc/systemd/system/hermes-research.service.d/hardening.conf
    [Service]
    User=hermes-research
    NoNewPrivileges=yes
    ProtectSystem=strict
    ReadWritePaths=/srv/hermes/research /srv/hermes/quarantine
    ProtectHome=yes
    PrivateTmp=yes
    PrivateDevices=yes
    ProtectKernelTunables=yes
    ProtectKernelModules=yes
    RestrictSUIDSGID=yes
    RestrictNamespaces=yes
    CapabilityBoundingSet=
    TasksMax=100
    MemoryMax=700M
    ```
    ```bash
    sudo systemctl daemon-reload && sudo systemctl restart hermes-research
    systemctl show hermes-research -p User,ProtectSystem,MemoryMax   # verify what's live
    ```
20. **Confirm `/etc/nftables.conf`, `/etc/systemd/system/hermes*`, `/root` are unreadable by agent users:**
    ```bash
    sudo -u hermes-research cat /etc/nftables.conf        # expect: Permission denied
    sudo -u hermes-research ls /root                      # expect: Permission denied
    ```
21. **Per-user egress (`meta skuid`) verification:**
    ```bash
    # Allowed: public web read
    sudo -u hermes-research curl -m 8 -sSI https://example.net | head -1   # expect HTTP/2 200

    # Denied: RFC1918, metadata, loopback, tailnet — every one must FAIL and be LOGGED
    sudo -u hermes-research curl -m 5 -sS http://<10.0.0.1>/ ; echo "rc=$?"                          # rc=28 or 7; NOT 200
    sudo -u hermes-research curl -m 5 -sS http://<172.16.0.1>/ ; echo "rc=$?"                       # rc!=200
    sudo -u hermes-research curl -m 5 -sS http://<169.254.169.254>/latest/meta-data/ ; echo "rc=$?" # rc!=200
    sudo -u hermes-research curl -m 5 -sS http://<127.0.0.1>:<PORT>/ ; echo "rc=$?"                 # any local service: denied
    sudo -u hermes-research curl -m 5 -sS http://<100.x.y.z>:<PORT>/ ; echo "rc=$?"                 # tailnet peer: denied

    # The denial was actually logged (Gate 0b "logged denials")
    sudo journalctl -k --since '-5 min' | grep 'NFT-DENY' | tail -5

    # Profile file boundary
    stat -c '%a %U' /srv/hermes/research                              # expect 700 hermes-research
    sudo -u hermes-research cat /etc/nftables.conf ; echo "rc=$?"     # rc=13 (permission denied)
    sudo -u hermes-research ls /root ; echo "rc=$?"                   # rc=13

    # Quarantine is write-only land: no exec
    findmnt -T /srv/hermes/quarantine -o TARGET,OPTIONS               # expect noexec,nosuid,nodev present
    ```

### 0.5 — First backup + tested restore

Follow `scripts/README.md` Step 4 exactly. Operational checklist in order:

22. **On laptop — R2:** create bucket with **bucket lock / retention** (object-level protection, enforced server-side by Cloudflare — this is what makes the writer credential non-destructive). Create a **bucket-scoped API token** — read/write on *that bucket only*, no account scope, no delete-admin scope (restic needs repo-metadata read; deletion protection comes from the bucket lock).
23. **On laptop — Healthchecks.io:** create check `hermes-backup`; period **1 day**, grace **≥ 2 h** (timer randomizes ±15 min, backup takes time). Copy the ping URL.
24. **On VPS:** install the scripts and unit files per `scripts/README.md`, generate the repo password, write the env file (`0600` root-only), then:
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

    restic version                            # >= 0.16
    sudo bash -c 'set -a; . /etc/restic-backup.env; restic init'
    sudo systemctl daemon-reload
    sudo systemctl enable --now hermes-backup.timer
    sudo /usr/local/sbin/hermes-backup.sh     # first manual run
    sudo /usr/local/sbin/hermes-restore-test.sh --deep    # GATE 0 — must PASS
    ```
    **Ordering matters:** `restic init` *before* enabling the timer — the timer has `Persistent=true` and would fire the service against an uninitialized repo.
25. **Verify the heartbeat landed:**
    ```bash
    sudo journalctl -u hermes-backup.service -n 30 --no-pager
    ```
    And see the check go green in Healthchecks.io ("Last ping" < 24 h).
26. **The true Gate 0 DR test — restore on the laptop with offline-held credentials:**
    ```bash
    # on laptop; recovery credential + repo password from password manager (kit comes in Phase 2)
    export RESTIC_REPOSITORY="s3:https://<account>.r2.cloudflarestorage.com/<bucket>"
    export RESTIC_PASSWORD="..."
    export AWS_ACCESS_KEY_ID="<recovery-cred-id>"       # restore-capable credential
    export AWS_SECRET_ACCESS_KEY="..."
    restic snapshots
    restic restore latest --target /tmp/hermes-restore-check
    ```
    Then compare checksums against a source directory you control (or against the checksum manifest the `restore-test.sh` run produced):
    ```bash
    cd /tmp/hermes-restore-check && find . -type f ! -name '*.sha256' -exec sha256sum {} \; | sort > got.txt
    diff got.txt expected-manifest.sha256       # empty output = PASS
    # or directly, if the VPS dir is reachable for comparison material:
    diff -qr /srv/hermes/research /tmp/hermes-restore-check/srv/hermes/research && echo RESTORE_VERIFIED
    ```
27. **Prove the writer token can't destroy** (adjust expectation to what the R2 token actually allows; record result):
    ```bash
    aws s3api delete-object --endpoint-url "https://<account>.r2.cloudflarestorage.com" \
      --bucket <bucket> --key test-delete-forbidden || echo "WRITER_CANNOT_DELETE (good)"
    ```
28. **Immediately** copy the restic repo password into your password manager *now* (formal escrow is Phase 2, but a backup whose password lives only on the VPS is currently unrestorable — this closes that window today).

### Verification & expected output

| Check | Command | Expected |
|---|---|---|
| cloud-init done | `cloud-init status` | `status: done` |
| SSH hardening | `sudo sshd -T \| grep passwordauthentication` | `no` |
| Firewall armed | `sudo nft list ruleset \| grep -c drop` | >0; INPUT/OUTPUT policies `drop` |
| Denials logged | `sudo journalctl -k \| grep -i deny` | non-empty after negative test |
| Rollback proven | `journalctl -u atd` | restore job ran; SSH survived |
| Backup heartbeat | Healthchecks.io dashboard | check green, "Last ping" < 24 h |
| Restore gate | `restore-test.sh --deep` | `PASS`; laptop diff empty |

### 4 GB budget reality

Baseline cost at end of Phase 0: ~350–500 MB (kernel/systemd/sshd) + Tailscale ~30 MB + nftables 0 + Hermes research ~200–700 MB (`MemoryMax=700M`) + restic during backup runs (spiky; the provided unit carries `MemoryMax=512M` and the timer runs at a quiet hour — a 4 GB box with a cold page cache handles this fine). Nothing here threatens the budget. **Flag:** do not install a browser or any container runtime in Phase 0 — that is Phase 3 work and needs the memory plan from that section.

### Failure modes & recovery

- **cloud-init runs once.** If the paste had a typo or the placeholder key was stale, the fix is OVH → Reinstall (wipes disk, re-runs user-data). Cheap now, catastrophic later — hence "verify placeholders" is step 1.
- **OVH injects its own SSH key for `ubuntu`/root** on some images — do not treat that key as yours; verify your `deploy` key works, then confirm password auth off. If both keys fail: **KVM console** (step 6) — log in as root with the password from the rescue mail, repair `authorized_keys`, reboot.
- **`apply` locked you out:** the `at` job restores the old ruleset in ≤5 min **only if `atd` was running** (hence step 10). If even that failed: OVH KVM/rescue → run `sudo bash scripts/setup-nftables.sh rollback` from the console.
- **You confirmed but forgot to re-test after reboot:** nftables loads at boot only if `systemctl enable nftables` was run; a silent boot-without-firewall is detectable by the `nft list ruleset` count check — keep it in the reboot drill.
- **`restic init` skipped / timer fired first:** service fails, Healthchecks goes red within grace — that *is* the monitoring working. Diagnose with `journalctl -u hermes-backup.service`; init the repo; re-run manually.
- **R2 endpoint/token mismatch:** `access denied` or `HeadObject 403` on first backup → check the token is bucket-scoped to the exact bucket and the S3 endpoint matches the bucket's account/jurisdiction.
- **Restore-test checksum mismatch:** do not "fix" forward. Stop, keep the failed artifact, diff *which* files differ (`comm` on the two manifests), and determine backup-time vs. restore-time corruption before proceeding. A passing `--deep` that you didn't watch is not a passing `--deep`.

## Adversarial verification (run these attacks)

Run every attack from an external vantage point where indicated (laptop on a non-Tailscale network, or a cheap second VPS/VM — never the box under test, unless the attack is explicitly "from inside a profile").

**A0-1 · External inbound port scan (Gate 0b).**
From an external host (laptop on a different network):

```bash
# Full TCP sweep of all 65535 ports — slow but complete. ~10-20 min.
nmap -Pn -p- -sT -T4 --reason -oN phase0-tcp-scan.txt <VPS_PUBLIC_IP>
# Quick sanity pass on the well-known UDP services attackers probe first
sudo nmap -Pn -sU --top-ports 200 --reason <VPS_PUBLIC_IP>
```

- **PASS:** every port returns `filtered` (drop, not reject — you should see no RSTs), or `closed` only for services you deliberately still expose during 0.2 (e.g., SSH before you flip to Tailscale-only). After the Tailscale-only cutover: **zero open/any-state ports publicly**. Also record: no port shows `open` on UDP 53/123/161/500 (classic forgotten services).
- **FAIL:** any `open` port you did not consciously allow; any port showing `open|filtered` on UDP without you knowing why; the scan itself being reflected in logs only on Tailscale (it shouldn't be reachable there from outside).
- **Fake-pass warning:** run the scan from a network you don't administer (phone hotspot), never from inside OVH's LAN or the same LAN as the VPS — a local scan sees nothing because of local routing, not because of the firewall.

**A0-2 · Outbound denial probe (Gate 0b).**
With the restrictive OUTPUT ruleset active:

```bash
# From the VPS, as a normal user — destination must NOT be allowlisted
curl -m 8 -v http://<203.0.113.1>/                 # TEST-NET-3 IP, nothing there, not allowlisted
nc -vz -w 5 <203.0.113.1> 4444                     # raw TCP attempt
dig +short @<203.0.113.1> example.com              # DNS to a non-configured resolver
```

Then find the evidence:

```bash
# nftables rule must have a `log prefix` + `counter` — read what it emitted:
journalctl -k --since "10 minutes ago" | grep -iE 'nft|drop|block'
# Per-rule hit counters (look for the counter on the OUTPUT drop/deny rules):
sudo nft list ruleset | grep -B2 -A2 counter
```

- **PASS:** every probe times out (`curl: (28) Connection timed out` / `nc: timeout`); journal shows a kernel log line with your log prefix containing the destination IP and ports; the matching nft rule's `counter` packet count incremented by exactly the number of probes you sent. `dig` to non-configured resolvers must also fail (accepted residual: public DoH/DoT resolvers and DNS-tunneling risk — documented in `setup-nftables.sh` DECISION block; don't mark this FAIL, but note it).
- **FAIL:** probe succeeds; packet dropped silently with **no log line and no counter increment** (you cannot alert on what you can't see — a Phase 7 blocked-egress spike alert depends on this); or only one of the two (drop works, logging doesn't).
- **Fake-pass warning:** a "denied" test hitting an address that's unreachable anyway (fake IP times out at network level, not at nftables) proves nothing — confirm the `NFT-DENY` kernel log line for the *exact* destination.

**A0-3 · Prove the timed-flush rollback actually fires.**
Do this deliberately *at least once* — the gate requires it be exercised, not just trusted:

1. Schedule the rollback: `echo 'sudo nft -f /etc/nftables.d/known-good.nft' | at now + 5 minutes` (or confirm the scheduled job from `setup-nftables.sh`: `atq` shows the job — an empty `atq` means you have no failsafe; DO NOT proceed).
2. Apply the restrictive ruleset. Break something small on purpose first (e.g., omit the NTP allow) and verify that symptom exists.
3. Wait. At the deadline:

```bash
atq                                  # must be empty after the job runs
journalctl -u atd --since "10 minutes ago"
sudo nft list ruleset                # confirm known-good ruleset is back
```

- **PASS:** the previously-broken symptom self-heals at the deadline without you touching anything; `atq` is empty; journalctl shows the atd job executing.
- **FAIL:** nothing happens at deadline (atd not running? script not executable? wrong path?) — **this is a critical FAIL**: the rollback is your only safety net against self-lockout, and an unproven safety net is decoration.
- **Extra discipline:** also test the "all good" path — remove the `at` job before deadline (`atrm <id>`) and confirm the restrictive rules persist.

**A0-4 · Gate 0a — Gitleaks blocks a real secret:**

```bash
git checkout -b gitleaks-test
echo "[SECRET:aws-access-key-id]=real-looking-aws-key" > fake.env
git add fake.env && git commit -m "test secret"     # must be BLOCKED by pre-commit hook
git checkout - && git branch -D gitleaks-test
```

- **PASS:** commit rejected with a gitleaks finding.
- **FAIL:** commit lands — re-fix the hook before any real config is committed.

**A0-5 · Early profile probes (end of 0.4):**

```bash
# As root, drop into the profile identity:
sudo -u hermes-research bash -c '
  curl -m 5 http://<169.254.169.254>/latest/meta-data/ ;   # cloud metadata
  curl -m 5 http://<10.0.0.1>/ ;                           # RFC1918
  curl -m 5 http://<127.0.0.1>:8080/ ;                     # loopback
  curl -m 8 https://no-such-allowlisted-host.example/ ;    # non-allowlisted domain
'
sudo journalctl -k --since "5 min ago" | grep -i nft
```

- **PASS:** all four fail (timeout/connection refused/denied) and the private-IP attempts appear in the nftables log (or the proxy log, if egress already goes through one).
- **FAIL:** any private/metadata address returns HTTP content; any non-allowlisted domain fetches silently.

**A0-6 · Restore proof (Gate 0, non-negotiable).**
From your **laptop**, using only offline-held material (repo password + recovery credential) — a restore run on the VPS with VPS-held credentials is a fake pass:

```bash
export RESTIC_REPOSITORY=... RESTIC_PASSWORD=...
restic snapshots
restic restore latest --target /tmp/restore-test
diff -r --brief /tmp/restore-test/srv/hermes/research /srv/hermes/research   # or sha256sum -c manifest
```

- **PASS:** restore completes from the laptop with only offline material; checksums match; **nothing** in the pipeline needed the VPS, Infisical, or Cloudflare dashboard.
- **FAIL:** restore needs any live system you didn't have (this is the circular-dependency trap ARCHITECTURE §7 exists to kill). Also run `restic ls latest | grep -iE 'cookie|profile|browser'` — **FAIL** if browser data appears.

## Pitfalls

1. **Setting `OUTPUT DROP` without a live rollback.** One typo in a DNS or Tailscale rule and you're rebuilding the box from the OVH console. The `at` bomb is not optional; it is only a failsafe if `atq` shows the job *before* you apply the rules. Track the job ID; cancel explicitly. Fix: `systemctl is-active atd` first, always apply → test → `confirm`, never edit-and-reload directly.
2. **Testing egress from root.** `sudo curl …` validates root's policy, not the agent's — root passes almost any ruleset you could write. Fix: every profile check runs `sudo -u <profile-user>`.
3. **Skuid rule loaded before the user exists** (or user renamed) — the grant matches nothing and the profile appears "fully blocked," which reads as success but is a config error that will later be "fixed" by loosening rules. Fix: reload nftables after creating users, re-run one positive test per profile.
4. **Restic password or R2 token committed to Git or written into `backup.sh`.** Keep env files `0600` root-owned and sourced; Gitleaks only helps if the secret hasn't already been pushed. Fix: never put the repo password inside the tree it backs up; copy it to the password manager immediately (step 28).
5. **"Restore tested" = ran `restic snapshots`.** Listing snapshots proves nothing. Fix: the gate demands `restic restore … && diff` from the laptop with the offline credential — a fake pass here is the single most expensive mistake in the whole plan.
6. **Inbound scan run from the same LAN as the VPS** (nmap sees nothing because of local routing). Fix: scan from a phone hotspot.
7. **`restic init` skipped / timer fired first:** the service fails against an uninitialized repo and Healthchecks goes red within grace. Fix: init the repo *before* `systemctl enable --now hermes-backup.timer` (the timer is `Persistent=true`).
8. **Booting without the firewall after a reboot.** nftables loads at boot only if `systemctl enable nftables` was run — a silent boot-without-firewall. Fix: keep the `nft list ruleset | grep -c drop` count check in the reboot drill.

## Gate 0 — honest pass checklist

From `PLAN.md` Gate 0, plus the fake-pass warnings:

- [ ] SSH only via Tailscale; password SSH disabled.
- [ ] Firewall default-deny both directions, with logged denials.
- [ ] Hermes running non-root, sandboxed, with one research profile limited to web reads.
- [ ] A restore from backup succeeded **from the laptop using offline-held credentials**.
- [ ] Backup heartbeat visible in Healthchecks.io.

**Fake passes to hunt for — each one silently fails the gate:**

- [ ] Inbound scan was run from a network you don't administer (hotspot), not the same LAN as the VPS.
- [ ] Every "denied" egress probe confirmed by an `NFT-DENY` kernel log line naming the *exact* destination — not just a network-level timeout.
- [ ] The restore ran on the **laptop** using only offline-kit material — not on the VPS with VPS-held credentials.
- [ ] The timed-flush flush **actually fired at least once**: scheduled, deadline deliberately passed, egress re-opened, re-applied. An unexercised rollback procedure is an untested control.
- [ ] The `--deep` restore test was watched, not assumed: a passing `--deep` you didn't observe is not a passing `--deep`.

**Evidence to record in `SETUP-TRACKER.md` / ops log:**

- [ ] Gate 0a: Gitleaks fake-secret commit blocked (A0-4), dated.
- [ ] Gate 0b: `phase0-tcp-scan.txt` (or its summary) + scan vantage point and date; the negative-egress log line (destination, prefix, counter delta); the atd journal excerpt proving the rollback fired.
- [ ] Rescue/KVM drill date (Phase 0.2 step 6) — this is break-glass rehearsal #1.
- [ ] The laptop restore transcript (`restic restore` + `diff` output, checksum manifest comparison), dated.
- [ ] Healthchecks.io check ID and first green ping timestamp.
- [ ] The "before" listening-socket picture (`sudo ss -tlnp4` from step 5) for later surface audits.

## Learner's corner

**What you'll learn in this phase**

- nftables policy semantics: base chains, priorities, `policy drop` vs `policy accept`, and why `counter` + `log` must be attached to deny rules.
- Outbound filtering as a *distinct* discipline: most people only ever firewall inbound; egress default-deny is what actually stops exfiltration.
- The timed-flush / dead-man's-switch pattern — how to make a risky change safely reversible.
- nftables `meta skuid` — matching packets by the owning process's Linux user.
- Restic's snapshot model: content-addressed dedup, repo password as the root of trust, why "write-only" is a restorable setup.
- Heartbeat (dead-man's-switch) monitoring versus polling monitors.

**Concept primer.** An nftables rule is evaluated per-packet, top-down, and a base chain's `policy drop` is what catches everything no rule accepted. `meta skuid <uid>` matches a packet only when the kernel can attribute it to a socket owned by that Linux user — which is why you map each Hermes profile to a *user*, not just a container: the firewall then distinguishes "traffic from the research profile" from "traffic from root" at the packet level. The counter on a rule is a live byte/packet tally — your future alerting (Phase 7 "blocked-egress spikes") is literally reading this counter. The timed-flush pattern works because `atd` runs *outside* the firewall change: even if your new ruleset breaks your own SSH session, the scheduled `at` job still restores the known-good file from disk. And restic inverts the usual backup risk: dedup means the repo stores chunks keyed by content hash, so a credential that can only *append* snapshots can still give you a complete restore — but cannot rewrite history or prune. That's why "write-only writer" and "restore from laptop" are compatible.

**Check-your-understanding**

1. Why must deny rules carry `counter` and `log` — what specifically breaks later if they don't?

   *Answer: Phase 7's "blocked-egress spike" alert has no signal source. A drop without a counter is invisible; you'd never distinguish "agent is quiet" from "agent is being noisy and blocked," which is the difference between normal operation and the first symptom of a prompt-injection exfiltration attempt.*

2. Why does `meta skuid` require matching *Linux users* rather than relying on container network isolation alone — and what kind of traffic would skuid *not* match?

   *Answer: skuid is a host-kernel-level attribution independent of namespaces, so it catches anything a process emits regardless of container network config. It will not match packets with no owning socket (e.g., some raw-socket traffic, kernel-generated replies) — which is also why agent users must not have CAP_NET_RAW.*

3. If you set `OUTPUT DROP` and your rule set has a typo that blocks DNS, what saves you — and why does the save work even if your SSH session is dead?

   *Answer: the `at`-scheduled flush. atd executes the restore from a queue file independent of your network session, so a ruleset that locks out the operator still self-reverts.*

4. The writer credential can create snapshots but not prune. Why does deleting the writer credential from the VPS (Phase 6 worry: stolen key) *not* destroy your backups — and what credential *could*?

   *Answer: restic prune/forget is an operation against repo history requiring a credential with those rights; the writer can only append. The prune/admin credential — which must live off-VPS — is the dangerous one, hence it never goes on the box.*

**Do-it-yourself habit.** Before running `setup-nftables.sh`, print it and annotate every rule in the margin: direction, match, action, and *why it exists* (which allowlisted service needs it). Then, on paper from memory, write the OUTPUT allowlist yourself (DNS, Tailscale, cloudflared, package repos, NTP, Infisical, backup endpoint, model providers) and diff against the script. Any rule in the script you can't justify, or any allow in your head missing from the script, is a finding.

## Steady state added by this phase

| Cadence | Task | Wiring |
|---|---|---|
| Daily | Backup run | `hermes-backup.timer` (exists) + Healthchecks heartbeat (exists) |
| On any major change | OVH snapshot first | manual discipline — checklist item in your change template |
| Weekly (start habit now; formalized in Phase 6) | `restic check` | Phase 6 timer |
| Quarterly | Re-run rescue/KVM drill (formalized in Phase 1) | calendar |