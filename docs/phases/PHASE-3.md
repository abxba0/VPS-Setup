# Phase 3 — Isolation baseline

> Companion to `docs/PLAN.md` §Phase 3. Authoritative source: `docs/ARCHITECTURE.md`. Track your progress in `docs/SETUP-TRACKER.md`. Do not start the next phase until Gate 3 passes.

## Your goal

All four profile users exist with no cross-reads, browsers/terminal workloads run rootless in containers with no host Docker socket, per-user egress is default-deny and logged, and the memory-safety net (zram + swap + earlyoom + `MemoryMax`/`TasksMax`) is installed so a runaway browser degrades one profile instead of the box.

In one sentence: the **profile trust rule** (`ARCHITECTURE.md` §8) becomes enforceable physics instead of policy — each profile gets *its own* Linux user, *its own* 0700 workspace, *its own* allowlisted network, and nothing else.

## Non-negotiables this phase enforces

- **#5 — Egress default-deny; every profile matches the trust table.** Per-user (`meta skuid`) rules, deny + log by default, per profile.
- **#3 (boundary build) — L3/L4 credentials never enter any agent context.** No L3/L4 credentials exist in this phase, but the filesystem/permission boundary is built here so they *can't* enter agent contexts later.
- **Golden rule 21 — no profile combines private data + untrusted content + outbound.** The table below is a specification, not a suggestion. If a future need violates it, the answer is the high-risk profile or "no."

| Profile | Private data | Untrusted content | Outbound | Egress policy |
|---|---|---|---|---|
| personal | yes | no | limited | strict allowlist |
| research | no | yes | web read only | open web, no creds, no send tools |
| automation | scoped | limited | specific APIs | strict allowlist |
| high-risk | temporary | no | via broker only | broker only |

## Why this phase matters

Phase 3 is the containment layer for the threats that arrive with capability:

- **D (malicious MCP/tool)** and **B/C (browser exploitation / prompt injection)**: a compromised profile user gets *its own* files, *its own* allowlisted network, and nothing else — including no path to `/root`, `/etc/nftables.conf`, or the other profiles. Even a fully hijacked research session has nothing sensitive to read and nowhere private to send.
- **L (runaway cost / resource DoS)** on a 4 GB box: `MemoryMax`, `TasksMax`, earlyoom, and zram stop one runaway browser from stalling the whole system. earlyoom specifically guarantees the *browser* dies before the *system* does — which keeps your admin path (SSH over Tailscale, OVH console) alive.

This phase must exist **before** the browser and before tools are enabled: containers from day one, not "containers later."

## Before you start

- Gate 0 passed (firewall default-deny both directions, timed-flush proven, research profile exists, tested restore) and Gate 2 passed (per-profile Infisical machine credentials, spend caps wired). Verify in `docs/SETUP-TRACKER.md`.
- `hermes-research` already exists from Phase 0.4 with its workspace at `/srv/hermes/research` (0700) and its sandbox drop-in — extend that pattern, don't fork it.
- Commands run from the VPS unless prefixed "on laptop" (same convention as `scripts/README.md`). Placeholders in `<angle brackets>` stay in your password manager, never in Git.
- **Keep a second SSH session open for the whole phase** (lifeline during egress/firewall work).
- Hard ordering constraints:
  - **No browser and no tools enabled before this phase's sandboxing exists.**
  - **No cross-profile write access, ever.** Profiles are 0700, distinct UIDs; there is no legitimate shared writable directory between profiles.
  - Every time you touch the nftables ruleset in this phase, use the same timed-flush discipline from Phase 0.3 (`apply` → test → `confirm`). The rollback habit does not retire after Phase 0.

## Credential map

| Credential | Level | Lives where | Must NEVER live |
|---|---|---|---|
| Profile Linux users (`hermes-personal`/`automation`/`highrisk`) + 0700 workspaces | — | VPS | Shared group membership across profiles (this is the classic leak) |
| Infisical machine tokens for the new profiles | L3 | Each profile's systemd unit env only | Other units, agent chat, repo |
| Browser profile/cookie stores (per profile) | L2 (session tokens) | `/srv/hermes/<p>/browser`, `0700`, **excluded from Restic** | Backups (golden rule 31), other profiles |
| Container registries / image pull creds | L1 | Pull-through or anonymous; if private, per-profile | Shared image cache with host-wide creds |
| Docker/Podman daemon | — | Rootless, per-profile | **The host `/var/run/docker.sock` mounted into any container — ever** |

## Steps

### 1. Create the remaining profile users

Repeat the pattern from Phase 0.4 for the three missing profiles:

```bash
for p in personal automation highrisk; do
  sudo useradd -r -m -d /srv/hermes/$p -s /usr/sbin/nologin hermes-$p
  sudo chmod 0700 /srv/hermes/$p
done
```

### 2. Cross-read enforcement check

```bash
sudo -u hermes-personal ls /srv/hermes/research    # Permission denied
sudo -u hermes-research ls /srv/hermes/personal    # Permission denied
```

0700 mode covers it — but also make sure shared group membership never creeps in later: `getent group | grep hermes` (no profile user should share a group with another profile user).

### 3. Per-user egress for all profiles

Extend the reviewed nftables OUTPUT structure (from `scripts/setup-nftables.sh`, see its DECISION block) with a `meta skuid` chain per profile, per the trust table:

```text
# concept (verify against the DECISION block in scripts/setup-nftables.sh):
# meta skuid hermes-personal:   strict allowlist (LLM APIs, Infisical, named endpoints)
# meta skuid hermes-automation: strict allowlist (its specific APIs)
# meta skuid hermes-highrisk:   broker endpoint only
# meta skuid hermes-research:   open web reads (80/443), NO private nets (RFC1918,
#                               loopback, link-local, CGNAT, metadata) — deny + log
```

Apply via the timed-flush discipline — never a bare reload:

```bash
sudo nft -c -f /etc/nftables.conf            # syntax-check BEFORE any reload
sudo bash scripts/setup-nftables.sh apply    # 5-min auto-rollback armed
# ... run the full positive + negative battery within the window ...
sudo bash scripts/setup-nftables.sh confirm
```

Two `meta skuid` facts that prevent silent misdesign:

1. User names in rules are resolved **at rule-load time** — if you create the user after loading nftables, the rule silently matches nothing. Create the users first (step 1), then load, then re-run one positive test per profile.
2. `meta skuid` matches only locally-generated packets whose socket has an owner. Unowned packets (some ICMP, raw sockets) fall through to the final `policy drop`. That is correct behavior: the policy drop enforces the boundary; your skuid rule is a grant, not the guard. (It is also why agent users must not have `CAP_NET_RAW`.)

Note: container egress still traverses the host OUTPUT chain with `meta skuid` = the profile user, so the per-user policy keeps applying *inside* containers — the Gate 3 tests verify this.

### 4. Rootless containers (Podman)

```bash
sudo apt install -y podman slirp4netns
# each profile user runs their own rootless daemon; no /var/run/docker.sock anywhere
sudo -u hermes-research podman run --rm alpine ping -c1 1.1.1.1   # smoke test
```

Rules:

- One container per trust level; mounts restricted to that profile's workspace + `/srv/hermes/quarantine`.
- **Never** mount `/var/run/docker.sock` or any host socket into a container — the socket is root-equivalent; one mount collapses the whole isolation layer.
- Network via rootless slirp4netns (no host-network containers).
- Browsers run in rootless containers **from day one**; downloads land in `/srv/hermes/quarantine` (`noexec,nosuid,nodev`), never auto-executed. Verify the agent's download dir actually points there.

### 5. Memory safety net (zram + swap + earlyoom)

```bash
sudo apt install -y zram-tools earlyoom
```

zram config — `/etc/default/zramswap`:

```ini
ALGO=zstd
PERCENT=50          # ~2 GB zram on a 4 GB box
PRIORITY=100
```

```bash
sudo systemctl restart zramswap && zramctl         # ~2G device, zstd
# small disk-backed swapfile as the slow tier (zram stays the fast tier)
sudo fallocate -l 1G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw,pri=10 0 0' | sudo tee -a /etc/fstab
```

earlyoom config — `/etc/default/earlyoom`:

```ini
DAEMON_OPTS="--prefer '(chromium|chrome|firefox|Xvnc)' --avoid '(sshd|tailscaled|systemd|restic|cloudflared)' -m 4 -s 4 -N /usr/bin/logger -n 'earlyoom: killed'"
```

```bash
sudo systemctl restart earlyoom && systemctl status earlyoom --no-pager
free -h          # expect: ~2G zram swap + 1G disk swap
```

Prove earlyoom does what it says: allocate past the threshold with a test process and confirm the victim is the *browser-like* process, not sshd/tailscaled:

```bash
stress-ng --vm 2 --vm-bytes 3G --timeout 90s &
journalctl -u earlyoom -f        # expect 'earlyoom: killed' naming the test/browser-like victim
```

### 6. systemd hardening per unit

Extend the Phase 0.4 drop-in pattern to every hermes unit. Reference drop-in (the research unit from 0.4 — copy the shape to each profile unit):

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

Browser/container units get the tightest caps:

```ini
# browser/container units additionally:
[Service]
MemoryMax=900M          # browser units; ~700M for plain profile services
MemoryHigh=700M         # soft throttle before the hard stop
TasksMax=120            # browser units; 100 for services; stops fork-bombs
```

Harden **incrementally**: add one directive, restart, exercise Hermes, verify, next. If a directive breaks Hermes, bisect the drop-in (comment half, restart, retest) — never fix sandbox errors by removing the sandbox. The usual culprits are `ProtectSystem=strict` (forgot `ReadWritePaths`) and `SystemCallFilter` (missing `@default` groups).

```bash
sudo systemctl daemon-reload && sudo systemctl restart hermes-research
systemctl show hermes-research -p User,ProtectSystem,MemoryMax   # verify what's live
```

**4 GB guidance:** the sum of all `MemoryMax` **should exceed** physical RAM+swap slightly — systemd enforces per-unit caps; you want the *earlyoom ordering*, not `MemoryMax`, to decide who dies first (`MemoryMax` = per-unit cap; earlyoom = global ranking). Never set a unit's `MemoryMax` so high that two concurrent maxed units can OOM the kernel before earlyoom reacts: keep browser `MemoryMax ≤ 900M`, and "one headed browser at a time" (Phase 4) is what makes that budget real.

### 7. 4 GB memory ledger (the central constraint)

Rough steady-state ledger once all profiles + one container browser are up:

| Component | RAM |
|---|---|
| Kernel + systemd + base daemons | ~350–400 MB |
| Tailscale + cloudflared | ~60–80 MB |
| Hermes services ×4 (capped) | ~600 MB–2.4 GB depending on activity |
| One rootless browser container (headless) | 250–500 MB |
| One **headed** browser via Xvnc (Phase 4) | 500 MB–1 GB |
| restic during backup window | ≤512 MB (capped) |
| zram | +2 GB effective virtual |

**What does not fit on 4 GB:**

- Two concurrent headed browsers: **no** — hard rule, one at a time.
- Self-hosted Infisical, Prometheus/Grafana stack, or a second always-on container: **no** — monitoring stays off-box (Healthchecks) by design.
- If sustained usage pins `MemoryHigh` throttles daily: that is the *measured* trigger for the planned ~£8–10/mo 8 GB upgrade — record the evidence (a week of `journalctl -u earlyoom` + `free` samples) rather than upgrading on vibes.

### 8. Filesystem audit

```bash
sudo -u hermes-research cat /etc/nftables.conf          # denied
sudo -u hermes-automation cat /etc/systemd/system/hermes-research.service.d/hardening.conf   # denied
sudo -u hermes-research ls /root                        # denied
stat -c '%a %U' /srv/hermes/*                           # all 700, own profile user
```

## Adversarial verification (run these attacks)

Run every attack **from inside a profile** unless stated. Evidence goes in the ops log — raw command transcripts, not summaries.

**A3-1 · Cross-profile read (run for every ordered pair):**

```bash
sudo -u hermes-research cat /srv/hermes/personal/private-note.md ; echo "exit=$?"
sudo -u hermes-personal  cat /srv/hermes/research/ingest/feed.md ; echo "exit=$?"
sudo -u hermes-automation ls /srv/hermes/highrisk/ ; echo "exit=$?"
sudo -u hermes-research cat /var/lib/hermes/other-profile-state.db ; echo "exit=$?"
```

- **PASS:** every attempt → `Permission denied` (exit 1). Also verify positively: `ls -ld /srv/hermes/*` shows `0700 <owner> <owner>` per profile, and no shared group.
- **FAIL:** any read succeeds — check for group-write/other-read bits, ACLs (`getfacl`), or Hermes state files living outside the 0700 dirs.

**A3-2 · Private-network / metadata reach (per profile):**

```bash
for target in 169.254.169.254 10.0.0.1 192.168.1.1 172.16.0.1 127.0.0.1 <TAILSCALE_PEER_IP> fd00::1; do
  sudo -u hermes-research curl -m 5 -s -o /dev/null -w "%{http_code} $target\n" "http://$target/" || true
done
```

(`<TAILSCALE_PEER_IP>` is a Tailscale peer — a favorite SSRF target. `fd00::1` covers `fc00::/7`.) Also try the long-form metadata alias: `http://169.254.169.254/latest/meta-data/iam/security-credentials/`.

- **PASS:** every target times out or is refused; every attempt appears in `journalctl -k | grep -i nft` with the source UID implied by your skuid rules, and in any egress-proxy log.
- **FAIL:** any HTTP response body returned; any drop without a log entry; IPv6 targets behaving differently from IPv4 (a classic gap).

**A3-3 · Egress allowlist enforcement (per profile, matching the trust table):**

```bash
sudo -u hermes-personal  curl -m 8 https://example.com/ ; echo "exit=$?"    # not on personal allowlist → must fail
sudo -u hermes-automation curl -m 8 https://example.com/ ; echo "exit=$?"   # same
sudo -u hermes-research  curl -m 8 https://en.wikipedia.org/ ; echo "exit=$?"  # open web READ allowed → must succeed
sudo -u hermes-highrisk  curl -m 8 https://example.com/ ; echo "exit=$?"    # broker-only → must fail
```

- **PASS:** personal/automation/high-risk probes fail + logged; research web read succeeds (and only *reads* — research egress policy permits arbitrary GETs by design; that is the accepted open-web-read posture, and the compensating control is "no creds, no send tools," verified in A3-5).
- **FAIL:** any strict-profile fetch succeeds; research fetch fails (broken baseline — you've over-blocked and will loosen it later in an emergency, which is worse).

**A3-4 · Sandbox/container boundary probes:**

```bash
# Inside a browser/terminal container for a profile:
ls -l /var/run/docker.sock 2>&1          # must NOT exist → "No such file"
mount | grep -E 'srv|root'               # confirm restricted mounts only
cat /proc/1/status | grep -i cap         # no meaningful capabilities
id                                       # container user, not root
# On the host:
sudo -u hermes-research cat /etc/nftables.conf       # Permission denied
sudo -u hermes-research ls /etc/systemd/system/hermes* ; echo "exit=$?"   # denied
sudo -u hermes-research cat /root/.ssh/id_ed25519 ; echo "exit=$?"        # denied
```

- **PASS:** all denied/absent.
- **FAIL:** docker.sock present (that's a root-equivalent escape); any protected path readable.

**A3-5 · "No send-capable tools / no credentials" for research:**

```bash
sudo -u hermes-research env | sort            # no API keys, no Infisical tokens, no L3/4 material
sudo -u hermes-research systemctl list-units --type=service --state=running 2>&1  # systemd deny or limited view
sudo -u hermes-research which msmtp sendmail mail 2>&1     # no send-capable binaries reachable
```

- **PASS:** empty env of secrets; no mail tooling; Infisical token absent or scoped read-only to research secrets only.
- **FAIL:** any credential in env or dotfiles (`sudo -u hermes-research grep -rE '(api[_-]?key|token|secret)' ~/ 2>/dev/null`).

**A3-6 · Memory-pressure behavior (4 GB reality check):** start the headed browser in a profile, then `stress-ng --vm 2 --vm-bytes 1G --timeout 60` (or open enough tabs).

- **PASS:** systemd `MemoryMax` or earlyoom kills the *browser unit* first; the system (and your SSH session) survives.
- **FAIL:** OOM killer takes out Hermes core, or the box stalls and you can't SSH in — tune earlyoom `--prefer`/`--avoid` and `MemoryMax`.

## Pitfalls

1. **Adding all four profiles to one common group** for convenience ("hermes" group with a shared folder) — instantly defeats 0700 isolation and gives every compromised profile a read path into the others.
2. **Mounting the Docker socket into a container "just for the build."** The socket is root-equivalent; that single mount collapses the whole isolation layer. Rootless podman, per-profile, never the socket.
3. **Hardening the unit all at once and then disabling the sandbox when Hermes breaks.** The incremental rule exists so you know *which* directive broke what. One directive, one restart, one functional test, next.
4. **Forgetting `ReadWritePaths`/`ProtectHome` interactions** — the service silently can't write its state and gets "fixed" by widening `ProtectSystem`. Diagnose with `journalctl`; never fix sandbox errors by removing the sandbox.
5. **Browser downloads landing in the workspace instead of quarantine** — a "helpful" path fix turns quarantine into a suggestion. Keep `noexec,nosuid,nodev` on `/srv/hermes/quarantine` and verify the agent's download dir actually points there.
6. **Skuid rule loaded before the user exists** (or a user later renamed) — the grant silently matches nothing, the profile appears "fully blocked," which reads as success but is a config error that will later be "fixed" by loosening rules. After creating users, reload nftables and re-run one positive test per profile.
7. **Testing egress from root.** `sudo curl …` validates root's policy, not the agent's. Every profile check must run `sudo -u <profile-user>`.
8. **Egress rule locked out a legit dependency** (e.g. apt after adding strict OUTPUT): the timed-flush pattern is your rollback — **always** `apply` → test → `confirm`, never edit-and-reload directly.
9. **Podman per-user storage grows silently** (`~/.local/share/containers`): `sudo -u <profile> podman system df` monthly; prune stale images in the maintenance window.
10. **zram not surviving reboot:** check `systemctl status zramswap` and the `/etc/fstab` entry after *any* kernel/package update — a silent swap-loss shows up as earlyoom killing browsers at modest loads.
11. **earlyoom kills the wrong victim:** tighten `--prefer`/`--avoid` lists; verify with the deliberate-allocation test.

## Gate 3 — honest pass checklist

The gate (per `docs/PLAN.md`): **from inside each profile, attempt and expect fail + log:** read another profile's dir (fail), touch private networks/metadata (fail, logged), reach a non-allowlisted domain (fail, logged). All four profile trust rows hold.

- [ ] A3-1 cross-profile reads fail for every ordered pair; `ls -ld /srv/hermes/*` shows 0700 per-profile owners; no shared group.
- [ ] A3-2 private-net/metadata probes fail **and appear in the NFT-DENY log** — a timeout without a log line is a network problem, not your control.
- [ ] A3-3 non-allowlisted domains fail + logged; research open-web read still works.
- [ ] A3-4 no Docker socket in containers; `/etc/nftables.conf`, `/etc/systemd/system/hermes*`, `/root` unreadable by all agent users.
- [ ] A3-5 research env has no credentials, no send-capable tools.
- [ ] A3-6 memory pressure kills the browser unit, not the system; zram ~2G active (`zramctl`, `free -h`); earlyoom log clean or only expected victims (`journalctl -u earlyoom --since -7d`).
- [ ] All four profile trust rows hold (read the table, then confirm each row by test, not by reading the config).

**Fake passes to hunt for:**

- Trust-rule "verified" by *reading the config*. The gate demands **attempted violations, per profile** — the A3 attacks above, run and logged.
- An egress "denied" test hitting an address that's unreachable anyway — confirm the `NFT-DENY` kernel log line for the *exact* destination, otherwise you proved nothing.
- `systemd-analyze security` score quoted from memory — run it (`systemd-analyze security hermes-<profile>.service`), record the output, and note any `[✗]` red lines you accepted so the next reviewer sees them.

**Evidence to record in `docs/SETUP-TRACKER.md` + ops log:** raw command transcripts of A3-1…A3-6, `systemd-analyze security` outputs per unit, zram/earlyoom status, and the dated gate line (`Phase 3 gate: isolation baseline tested YYYY-MM-DD`).

## Learner's corner

**What you'll learn in this phase**

- DAC permissions as a security boundary: 0700, user separation, and why "same group" silently defeats it.
- systemd sandboxing directives in practice (`ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`, `CapabilityBoundingSet`, `SystemCallFilter`, `MemoryMax`, `TasksMax`) and how to debug an over-tight unit.
- Rootless containers: mount scoping, why the Docker socket is root-equivalent, per-trust-level networks.
- SSRF as a *network-layer* problem, not just an app-layer bug.
- Memory governance on a 4 GB box: zram, earlyoom, per-unit ceilings.

**Concept primer.** Linux file permissions are the cheapest isolation you have: `0700` owned by the profile user means the kernel itself refuses other users' `open()` calls — no proxy, no policy engine, just mode bits. The trust rule then becomes physical: research literally *cannot read* personal data, so even a fully hijacked research session has nothing sensitive to exfiltrate. systemd's sandbox directives carve the same idea into process space: `ProtectSystem=strict` remounts the entire filesystem read-only except paths you list in `ReadWritePaths`; `NoNewPrivileges` makes setuid escalation impossible; `CapabilityBoundingSet=` empties the process's privilege toolbox; `MemoryMax` turns a runaway browser into a contained OOM instead of a system-wide stall. SSRF defense belongs at the network layer because application-level blocks (blocklists of "bad IPs") are always incomplete — DNS rebinding, decimal-encoded IPs, IPv6 variants, and redirect chains all bypass pattern matching, but a firewall rule that drops RFC1918/loopback/link-local/CGNAT destinations for a UID cannot be reasoned around.

**Check-your-understanding**

1. Why does the research profile get *open* web access while personal gets a strict allowlist, and what makes research's open web non-dangerous?
   *Answer: the trust rule trades the three corners. Research holds no private data and no credentials, so its exfiltration payload is empty — open egress from an empty box leaks nothing. Personal holds private data, so its egress must be restricted to named endpoints; its untrusted-content corner is removed instead (no web ingestion of arbitrary content).*
2. `PrivateTmp=yes` on a unit — what specific attack does that kill?
   *Answer: /tmp symlink races and cross-process tmp snooping: the unit gets a private tmpfs namespace, so an attacker (or another unit) can't pre-place/replace files in /tmp the unit trusts, nor read files it writes there.*
3. Why must `MemoryMax`+earlyoom exist *before* you run the browser, not after the first stall?
   *Answer: because the failure mode of memory exhaustion on 4 GB is an unresponsive box — at which point your management and remediation tools (SSH via Tailscale, OVH console) may also be starved. Prevention must precede the first incident; otherwise the incident is how you learn the setting was wrong.*
4. You find research's curl can reach `https://en.wikipedia.org` but personal's cannot. A colleague says "just give personal the same, it's easier." What trust-rule invariant breaks?
   *Answer: personal holds private data; adding broad outbound web gives an injected/hijacked personal session an exfil channel to any site — that's the direct exfiltration path the trust rule exists to sever. Personal's egress stays on named, justified endpoints.*

**Do-it-yourself habit.** Before applying the systemd hardening increments, write the unit's sandbox stanza yourself from the `ARCHITECTURE.md` §8 list, start the service, then run `systemd-analyze security hermes-<profile>.service` and read the *exposure score breakdown* line by line. Each red line is either (a) something you need to fix, or (b) something you consciously accept — write down which, for every line.

## Steady state added by this phase

| Cadence | Task | Wiring |
|---|---|---|
| Monthly | `podman system df` + prune per profile; `free -h` / earlyoom log skim | Calendar 15-min slot |
| Weekly (add to existing window) | `journalctl -u earlyoom --since -7d` skim | Healthchecks check `earlyoom-quiet` pinged by a weekly on-box script (ping only when log is clean) |
| On profile changes | re-run Gate 3 cross-read/egress tests | change checklist |
