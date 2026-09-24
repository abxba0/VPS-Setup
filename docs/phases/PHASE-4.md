# Phase 4 — Full Hermes capability

> Companion to `docs/PLAN.md` §Phase 4. Authoritative source: `docs/ARCHITECTURE.md`. Track your progress in `docs/SETUP-TRACKER.md`. Do not start Phase 5 until Gate 4 passes.

## Your goal

All four profiles (personal, research, automation, high-risk) are live in Hermes mapped to their Linux users and Infisical machine identities; every Hermes built-in control claim is verified against current docs and compensated at the host/network layer where false; Bot Screen (Xvnc + Xfce) is localhost-only with idle shutdown; messaging/email run on explicit allowlists; every scheduled job has budgets, a kill switch, and an external heartbeat; model routing and token logging are live; and no unvetted MCP or skill exists on the box. Phase 4 turns on the attack surface the whole threat model has been waiting for: browsers, messaging/email, MCP/skills, and scheduled autonomy — untrusted input *with* tools attached.

## Non-negotiables this phase enforces

From `PLAN.md` §Non-negotiables, the ones this phase enforces:

- **#10 — No unreviewed MCP or skill.** The §15 vetting checklist (ARCHITECTURE) must be *in the path* before any install, and re-vet on every version bump — a "minor" MCP update is new code with the old trust budget.
- **#4 — No agent self-approval; out-of-band human approval always.** Broker routes from Phase 3.5 now carry every "send/restart/rotate" capability. Hermes' built-in approvals stay enabled as an *additional* layer, never as the final authority.
- **#3 — L3/L4 credentials never enter any agent context.** Messaging platform tokens (L2) are profile-scoped in Infisical; MCP credentials match their *vetted blast radius*, nothing wider.
- **Golden rule 15 — no unrestricted browser session to sensitive accounts.** Dedicated accounts/scoped tokens first; the operate→logout→clear→terminate→destroy sequence is mandatory if a sensitive login is unavoidable.
- **Golden rule 16 — no open messaging gateway.** Explicit sender allowlists per platform; unknown sender → deny/pairing, enforced in Hermes *and* observable in logs.

## Why this phase matters

Phase 4 is where Hermes starts touching untrusted input with tools attached, and every control added here is compensation for that fact. In threat terms (ARCHITECTURE §4 IDs):

- Browsers turn on **B** (malicious website → browser exploitation / prompt injection).
- Messaging/email turn on **F** in a new way — an attacker who can message your agent *is* a session, even unauthenticated.
- MCP/skills turn on **D** (malicious tool → code execution, credential theft).
- Scheduled autonomy makes **L** (runaway cost) and **C** (prompt injection persisting over time) chronic risks instead of one-shot ones.

Verifying Hermes' own security claims (the §79 list in ARCHITECTURE §10) matters because built-in protections are defense-in-depth, not boundaries: if a claimed control (e.g., SSRF protection) is absent or bypassable, you must compensate at the network/host layer you built in Phases 0.4/3 — never by trusting Hermes harder.

## Before you start

**Prerequisites:**

- [ ] Gates 0, 1, 2, 3 **and 3.5 (approval broker)** all passed per `docs/SETUP-TRACKER.md`. Nothing here ships before the Phase 3.5 gate — any "send/restart/rotate" capability routes through the broker.
- [ ] All four Linux users + 0700 workspaces exist (Phase 3); per-user egress default-deny is live and logged.
- [ ] Infisical machine identities exist per profile (Phase 2); spend caps set.

**Hard ordering constraints:**

- **No MCP or skill is added before completing the §15 vetting checklist**, and re-vet on every version bump.
- **No scheduled job runs without an external heartbeat and a kill switch** — a looping job is a high-probability failure, not an edge case.
- **No Bot Screen login to sensitive personal accounts** — dedicated accounts/scoped tokens first; if a sensitive login is truly unavoidable, the operate→logout→clear→terminate→destroy sequence is mandatory.
- No browser and no tool goes live in a profile whose sandboxing isn't done (Phase 3) — containers from day one, not "containers later".

## Credential map

| Credential | Level | Lives where | Must NEVER live |
|---|---|---|---|
| Hermes dashboard OAuth (via Cloudflare Access → OIDC) | L3 | CF Access + Hermes | Shared accounts; "everyone" Access policy |
| Messaging platform tokens (per platform, per profile) | L2 | Infisical, profile-scoped | Agent chat history, Git |
| `agent@domain` mailbox credentials | L2 | Infisical | Personal mailbox, profile browsers |
| Bot Screen browser profiles/cookies | L2 | `/srv/hermes/<p>/browser`, `0700`, **Restic-excluded** | Backups (rule 31), other profiles, host-wide locations |
| Scheduled-job tool/credential allowlists | — | Hermes config (git-tracked, no secrets) | Inline in job definitions |
| MCP server credentials | L2–L3 | Infisical scope matched to *vetted blast radius* | Shared with other MCPs |

## Steps

Commands run from the VPS unless prefixed "on laptop". `<...>` placeholders are values you keep in your password manager, never in Git.

### 4.1 — Configure the remaining profiles

1. Configure personal, automation, high-risk in Hermes; each bound to its Linux user and its Infisical machine identity from Phase 2. The high-risk profile's outbound = **broker endpoint only** — verify with an egress test from that user:
   ```bash
   sudo -u hermes-highrisk curl -m 8 -sS https://example.com ; echo "rc=$?"   # broker-only: must FAIL
   sudo journalctl -k --since '-5 min' | grep NFT-DENY | tail -3
   ```

### 4.2 — Verify Hermes built-in control claims (§79)

2. Verify each claim against **current** Hermes docs — one by one, with a test, not a changelog read:
   - *Bot Screen:* where sessions live, cleanup behavior → find the session dir, confirm it's under the profile user and excluded from backups.
   - *Built-in approvals:* try a dangerous command in each profile, confirm the prompt; note what bypasses it (that's your compensation list).
   - *SSRF protection:* ask the research profile to fetch `http://<[METADATA-IP]>/latest/meta-data/` and `http://<[LOOPBACK]>:<dashboard-port>/` — expect blocked. Whatever Hermes blocks, the nftables layer must *also* block (you already do in OUTPUT) — belt and suspenders.
   - *MCP credential filtering:* add a test MCP that echoes env; confirm provider keys are absent from its context.
   - *Website blocklist:* add one internal dashboard to the blocklist, attempt the fetch, confirm enforcement; *also* add the same domain to a nftables/proxy-level deny if Hermes enforcement is only advisory.
   - *Messaging DM pairing:* send a DM from an unknown account → expect deny/pairing flow.
3. Record verdicts in a `docs/hermes-claims.md` matrix. Any **false** claim → compensate at host/network layer (nftables/systemd), never "inside Hermes config", and log the compensation in the decisions log.

### 4.3 — Bot Screen via Xvnc + Xfce (localhost only, per-profile, idle shutdown)

4. Install and template the session stack:
   ```bash
   sudo apt install -y tigervnc-standalone-server xfce4 xfce4-terminal
   sudo -u hermes-research vncpasswd    # per-profile password, stored via profile's secret scope
   ```
   systemd template unit `hermes-xvnc@<profile>.service`:
   ```ini
   [Service]
   ExecStart=/usr/bin/Xvnc :90%i -localhost yes -SecurityTypes VncAuth -rfbport 0 ...
   #   (rfbport 0 + -localhost yes: only the local Hermes/WayVNC bridge connects)
   User=%i
   MemoryMax=1.1G
   TasksMax=180         # Xvnc + Xfce + browser under one roof
   ```
   Add an idle-shutdown unit (`hermes-xvnc-idle@.timer`) that checks input/session idle and stops the unit after N minutes. Idle shutdown is **not optional** on 4 GB — it is a budget control, not a nicety.
5. Access to the screen = via the Hermes Bot Screen integration over the localhost socket; **never** expose the VNC port beyond loopback. Enforce **one headed session at a time** with a tiny wrapper (starting session B stops session A) — don't rely on memory:
   ```bash
   ss -tlnp | grep -E '59[0-9][0-9]|vnc'   # every Xvnc listener bound to loopback ONLY
   systemctl show hermes-xvnc@research -p MemoryMax -p TasksMax -p User
   ```

### 4.4 — Browser session hygiene

6. Prefer scoped OAuth/API tokens and dedicated accounts. If a sensitive login is unavoidable, the operating procedure (put it on a laminated card next to the keyboard if needed): **operate → log out → clear cookies → terminate session → destroy temp creds.** Browser profiles live at `/srv/hermes/<p>/browser` — already excluded from Restic; verify the exclusion still matches after any change:
   ```bash
   sudo bash -c 'set -a; . /etc/restic-backup.env; restic backup /srv/hermes --dry-run -n' 2>&1 | grep -i 'browser'   # expect: no browser paths listed
   ```

### 4.5 — Messaging/email allowlists

7. Messaging: per-platform **explicit sender allowlists**; unknown sender → deny or pairing flow (tested in 4.2). Verify the denial is observable:
   ```bash
   sudo journalctl -u 'hermes*' --since '-5 min' | grep -iE 'deny|pairing|unknown sender'
   ```
8. Email: dedicated `agent@domain` mailbox (never the personal mailbox), approved senders only; human approval required for sensitive outgoing mail — route through the broker's `send_approved_email` schema if you want automation at all.

### 4.6 — Website blocklist

9. Blocklist: internal dashboards, cloud admin pages (OVH/Cloudflare/Tailscale consoles), secret-management UIs (Infisical), private infra — enforced in Hermes *and* at network layer where feasible. Probe it: ask the personal profile's browser to visit `https://dash.cloudflare.com` → expect block, logged.

### 4.7 — Scheduled jobs: the ten mandatory fields

10. Every job definition must carry **all ten** fields before it goes live — no exceptions, no "temporary" jobs missing one:
    1. max runtime
    2. max frequency
    3. tool-call budget
    4. token budget
    5. allowed tools/domains/credentials
    6. cost budget
    7. output limit
    8. failure handling
    9. kill switch (`systemctl stop hermes-job@<name>` reachable from Tailscale **and** the OVH console path)
    10. **external heartbeat** (Healthchecks ping on completion — Phase 7 pattern)
    ```bash
    grep -rE 'hc-ping|max_runtime|cost_budget|kill' /etc/hermes/jobs/ | wc -l   # each job file matches; count == job count
    ```
    Trigger the failure path once: temporarily break one job's heartbeat and verify Healthchecks flags it LATE (grace period), not never.

### 4.8 — Model routing

11. Cheap tier for routine work, strong tier for high-risk reasoning/privileged prep; token counts logged per task (feeds the spend-cap alerts from Phase 2):
    ```bash
    sudo journalctl -u 'hermes*' --since '-1 day' | grep -ci 'tokens'   # per-task token counts present
    ```

### 4.9 — MCP/skill vetting

12. Run the ARCHITECTURE §15 checklist for every candidate **before** `podman pull`/install. Failing the trust rule → high-risk profile or nothing. Pin versions; re-review on every version bump (Renovate proposals go through the Phase 8 update workflow — never "just merge, it's minor"). Keep the current inventory auditable:
    ```bash
    hermes mcp list ; hermes skills list   # cross-check EVERY entry against the dated vetted list in the ops log; zero unexplained entries
    ```

### Hermes claims verification — exact checks

```bash
# SSRF: point a Hermes web-fetch at an internal address; expect refusal:
hermes fetch http://<[METADATA-IP]>/latest/meta-data/    # expect: blocked (AND network-layer deny logged)
sudo journalctl -k --since '-2 min' | grep NFT-DENY | tail -1     # defense-in-depth proof
# Any claim that fails -> compensating control at nftables/systemd level, documented in the decisions log.

# Bot Screen: localhost only, per-profile, memory-capped
ss -ltnp | grep -E '59[0-9][0-9]|vnc'            # every Xvnc listener on loopback ONLY
systemctl show hermes-xvnc@personal -p MemoryMax -p TasksMax -p PrivateDevices
# Idle shutdown exists: test that an idle session actually terminates.

# Messaging allowlist — from a NON-allowlisted account, DM the agent:
sudo journalctl -u 'hermes*' --since '-5 min' | grep -iE 'deny|pairing|unknown sender'

# Scheduled jobs: every one has budget + heartbeat + kill switch
grep -rE 'hc-ping|max_runtime|cost_budget|kill' /etc/hermes/jobs/ | wc -l

# Model routing & token logging
sudo journalctl -u 'hermes*' --since '-1 day' | grep -ci 'tokens'

# No unvetted MCP/skill present
hermes mcp list ; hermes skills list
```

### Verification & expected output

| Check | Command | Expected |
|---|---|---|
| High-risk egress | `sudo -u hermes-highrisk curl https://example.com` | fails + `NFT-DENY` log line |
| Bot Screen binding | `ss -tlnp \| grep -E '59[0-9]{2}'` | loopback only |
| Idle shutdown | start session, wait N min, `systemctl status hermes-xvnc@research` | inactive; `free -h` shows RAM returned |
| Messaging deny | DM from unknown account | no response; deny/pairing + log line |
| Blocklist | fetch cloud admin page | blocked + logged |
| Job fields | `grep -rE 'hc-ping\|max_runtime…' /etc/hermes/jobs/` | count == job count |
| Heartbeat | Healthchecks dashboard | one green check per scheduled job |
| Claims matrix | `docs/hermes-claims.md` | every §79 item has ✅/❌/compensation note |
| MCP inventory | `hermes mcp list` | only entries with dated vetting records |

### 4 GB budget reality

This is the phase that can sink the box:

- **Xvnc + Xfce session:** ~250–400 MB idle, 500 MB–1 GB with a browser inside. `MemoryMax=1.1G` on the template unit. **One headed session at a time** — enforce with a lock/wrapper, not discipline.
- Per-profile Hermes service `MemoryMax=700M`, browser container `MemoryMax=900M`, Xvnc `MemoryMax=1.1G`: worst-case concurrent (one service + one browser container + one Xvnc + broker + base) ≈ 3.6 GB + zram headroom — workable but tight. **Two headed sessions, or browser container + headed Xvnc simultaneously: will not fit.** Sequence them.
- If you're throttled weekly, the *measured* evidence (earlyoom kills, `MemoryHigh` throttle events in `journalctl -u <unit>`) is the upgrade case to 8 GB — record it, don't upgrade on vibes.

### Failure modes & recovery

- **Xvnc unit leaks sessions** (timers missed, memory crept): `systemctl list-units 'hermes-xvnc@*'` in the weekly maintenance; alarm if any session is both active and idle for hours.
- **VNC accidentally bound non-localhost** (mis-edit): `ss -tlnp | grep -E '59[0-9]{2}'` must show loopback only — add this exact check to the weekly script; even if it slipped, the firewall's INPUT policy blocks external reach (defense in depth, verified at Gate 0b).
- **A job ran away:** kill switch (`systemctl stop hermes-job@<name>` + `pkill -u hermes-<profile>`), check the spend dashboard, rotate that job's key if its budget is burned, review audit logs for what it actually did.
- **MCP vetted-then-updated upstream:** version pins + Renovate mean bumps arrive as proposals; re-vetting is triggered by the diff — never "just merge, it's minor".

## Adversarial verification (run these attacks)

Run every attack from an external vantage point where indicated (laptop on a non-Tailscale network, or a cheap second VPS/VM — never the box under test, unless the attack is explicitly "from inside a profile").

**A4-1 · SSRF probes through Hermes itself.** In each profile, ask Hermes to fetch (its built-in fetch/website tool *and* the browser):

```text
http://<[METADATA-IP]>/latest/meta-data/                 # cloud metadata endpoint
http://<[RFC1918-1]>/                                    # private network
http://<[LOOPBACK]>:8080/   http://[::1]/                # loopback, incl. IPv6 form
http://<[RFC1918-2]>/   http://<[RFC1918-3]>/            # other private ranges
http://0x7f000001/   http://2130706433/                  # encoding-bypass forms of the loopback address
http://<your-vps>.<tailnet-name>.ts.net/                 # own tailnet services
```

- **PASS:** Hermes' SSRF protection refuses (error, never content) **and** the network layer independently drops the packets (nft log shows the denial). Two independent catches — the app layer may miss a form; the net layer may not.
- **FAIL:** any response body returned; app layer blocks but net layer didn't (or vice versa — you claimed two layers, verify both).

**A4-2 · Website blocklist enforcement.** From the *personal* profile, ask Hermes to visit a blocklisted category URL (e.g., your Cloudflare dashboard URL, your secret-manager UI, an internal dashboard).

- **PASS:** refused by Hermes' blocklist layer; attempt logged.
- **FAIL:** reachable (blocklist not enforced at this layer — compensate at network/host per ARCHITECTURE §10 and re-test).

**A4-3 · Unallowlisted website from personal/automation.** Ask Hermes (personal) to browse `https://some-random-site.example`.

- **PASS:** network-layer denial + log; Hermes surfaces a clean error.
- **FAIL:** fetched.

**A4-4 · Unknown messaging sender.** From a second messaging account (friend's account or a test account you create), DM the agent bot.

- **PASS:** no response; sender denied/queued for pairing; event logged. Approved sender still works (positive control).
- **FAIL:** agent converses with or obeys the unknown sender — an open messaging gateway is remote code execution by anyone with your bot's handle.

**A4-5 · Email path.** Send mail to `agent@<domain>` from an unapproved address → ignored/quarantined + logged. Ask Hermes (personal) to email a non-allowlisted recipient → blocked or requires approval per policy.

- **PASS:** unapproved inbound quarantined + logged; unapproved outbound blocked/approval-gated.
- **FAIL:** unknown sender's mail enters the agent context; outbound mail leaves without approval.

**A4-6 · Scheduled-job guardrails.** Create a test scheduled job deliberately violating policy (no max runtime; no kill switch; disallowed tool).

- **PASS:** Hermes/platform rejects or flags it at creation; a *valid* job shows heartbeat + kill switch + budget; actually trip the kill switch once and confirm the job dies.
- **FAIL:** policy-violating job accepted silently.

**A4-7 · Unvetted MCP/skill.** Attempt to install an unsigned random MCP server into research.

- **PASS:** blocked by your vetting workflow (this is procedural: the checklist must be *in the path*), or it lands only in high-risk after review.
- **FAIL:** it runs in any profile without the §15 checklist completed.

**A4-8 · Surfaces through Access only.** From an external host: hit the dashboard's public hostname with no Access session → redirect to Access login; scan the VPS again (`nmap -Pn -p- <VPS_PUBLIC_IP>`) → still zero open ports (cloudflared is outbound-only).

- **PASS:** no direct-connect path exists; only the tunnel. (Full origin JWT validation is Phase 5 — at this gate, at minimum the dashboard is Tailscale/Access-only and `ss -ltnp` shows no public listener.)
- **FAIL:** any origin port open for the dashboard.

## Pitfalls

1. **Trusting Hermes' claims without probing** (SSRF, approvals coverage, MCP credential filtering). Docs describe defaults, not guarantees. Fix: every §79 claim gets a reproduction test; failures are compensated at nftables/systemd, and the compensation is documented.
2. **MCP "quick test" in the personal profile** instead of high-risk. A new MCP is untrusted code with credentials nearby; the §15 checklist exists precisely because the trust rule forbids untrusted+private in one profile. Fix: vetted in high-risk first.
3. **Sensitive login in Bot Screen "just this once."** The cookie jar persists, lands in a browser profile, and (if you ever get an exclusion wrong) in a backup. The hygiene sequence exists because "just this once" is how it always starts. Fix: laminated card procedure; re-verify the Restic exclusion (`restic backup --dry-run -n`) after any change.
4. **Scheduled jobs with generous budgets "so they don't fail mid-task."** A runaway job's cost is capped by *your* config, not by the task's sense of proportion. Fix: max runtime, frequency, tool calls, tokens, cost — all bounded, all externally monitored, kill switch tested.
5. **Open messaging gateway** ("anyone can DM the bot, I'll filter in prompts"). Prompt filtering is not identity. Fix: allowlists + pairing enforced by Hermes *and* observable in logs.
6. **Idle shutdown skipped "to save setup time"** — on 4 GB an idle Xvnc session is the difference between a working box and an earlyoom lottery. Fix: idle timer is mandatory; check `systemctl list-units 'hermes-xvnc@*'` weekly.
7. **Job "monitored" because the job logs its own success.** Fix: monitoring must be external (Healthchecks) with a grace window — a job that reports its own success is the agent grading itself again.
8. **MCP inventory rot:** "reviewed recently" is not a vetting record. Fix: a current mapping of every present MCP/skill to a *dated* vetting record; anything without one is unvetted by definition.

## Gate 4 — honest pass checklist

From `PLAN.md` Gate 4, plus the fake-pass warnings:

- [ ] All Hermes surfaces reachable only through Cloudflare Access → OAuth (until Phase 5 wiring is done: at minimum via Tailscale only, with `ss -ltnp` showing no public listener).
- [ ] Allowlists enforced per platform (messaging senders, email senders/recipients, website blocklist) — negative tests logged.
- [ ] Every scheduled job externally monitored — one green Healthchecks check per job, kill switch tested, all ten fields present.
- [ ] No unvetted MCP/skill present — every entry maps to a dated vetting record.

**Fake passes to hunt for — each one silently fails the gate:**

- [ ] "Access protects the dashboard" asserted while the origin also listens on a public interface — check `ss -ltnp` now; don't build on sand (Phase 5 will catch it, but Phase 4 must not assume it).
- [ ] Scheduled jobs "monitored" because they log their own success — monitoring must be external, with a grace window; one job's heartbeat was deliberately broken and Healthchecks flagged it LATE.
- [ ] MCP list reviewed "recently" — the gate demands a current, dated vetting record per entry.
- [ ] Hermes claims "verified" by reading docs — every §79 claim must have a reproduction test in the claims matrix (✅/❌/compensation).
- [ ] New MCP tested in the personal profile — vetting happens in high-risk first, per the trust rule.
- [ ] A Bot Screen session was left idle-running overnight — idle shutdown must be demonstrated, not configured.

**Evidence to record in `SETUP-TRACKER.md` / ops log:**

- [ ] `docs/hermes-claims.md` matrix, dated, with compensation notes for any ❌.
- [ ] Healthchecks.io check IDs for every scheduled job + the heartbeat-failure (LATE) test transcript.
- [ ] MCP/skill inventory + dated vetting records (§15 checklists) per entry.
- [ ] `ss -tlnp` output showing all Xvnc listeners on loopback only + the idle-shutdown test transcript.
- [ ] Messaging deny log line (unknown sender) and blocklist test transcript.
- [ ] Token-count logging sample (feeds Phase 2 spend-cap alerts).
- [ ] A4-1…A4-8 results, dated, in the ops log.

## Learner's corner

**What you'll learn in this phase**

- Verifying vendor security claims empirically (the §79/§10 caveat discipline): test, don't read the changelog.
- SSRF defense-in-depth: why app-layer protection and network-layer denial must *both* fire.
- Messaging/email as agent attack surface: allowlists, DM pairing, sender identity.
- Scheduled-job governance: limits, budgets, heartbeats, kill switches.
- MCP/skill supply-chain vetting as a repeatable checklist.

**Concept primer.** A vendor claim like "we have SSRF protection" is a hypothesis; your job is to turn it into a tested fact by throwing the canonical payloads at it — including the bypass forms (hex/decimal-encoded loopback, IPv6 brackets, rebinding-prone hostnames) that pattern-matching filters miss. That's why the net layer backs it up: nftables doesn't care how the URL was written, only that a packet from UID `hermes-personal` is heading to a private address, and it drops that with a log line regardless of what Hermes believed. Messaging inverts the usual trust direction: a bot that reads DMs has, by design, a channel where strangers can inject instructions — allowlists and DM pairing convert "anyone can talk to the agent" into "nobody can, until a human pairs them," which is the messaging equivalent of default-deny. Scheduled jobs deserve the same treatment because a *successful* job running unattended is the most common way agents do damage slowly: budget caps bound the money, heartbeats bound the silence, kill switches bound the blast radius.

**Check-your-understanding**

1. Hermes correctly blocked a private-range fetch, but your nft log shows the packet went out and was dropped at the net layer. Is that PASS or a problem?

   *Answer: PASS for this payload, but a finding: two layers caught it at different points, meaning the app layer's verdict arrived after the connection attempt. That's fine — but verify a payload the app layer *misses* (e.g., encoded loopback) still dies at the net layer. The invariant is: net layer must catch 100% of private-range destinations regardless of app behavior.*

2. Why is "unknown sender → deny" stronger than "unknown sender → agent asks Hermes if it looks suspicious"?

   *Answer: the second puts a prompt-injectable model in the trust path — a well-crafted first message can convince the model it's a known contact. Deny is a non-AI control (address list) the model has no power to override; it sits at a layer the agent cannot bypass (golden rule).*

3. What three properties must every scheduled job have so that a *silently looping* job is impossible, and which threat (§4) does each address?

   *Answer: external heartbeat (detects the job you thought was running/died — reliability + L), hard cost/runtime budget (bounds runaway spend — L), kill switch reachable without the agent (bounds blast radius during any compromise — F/H). Failure handling defines behavior on error so it doesn't retry forever.*

**Do-it-yourself habit.** For each §10 "unverified claim" you test this phase, write one line in the ops log: `CLAIM → TEST → OBSERVED → COMPENSATION (or none)`. This builds the habit of empirical verification and gives you a regression checklist for every Hermes upgrade (re-run the list after version bumps).

## Steady state added by this phase

| Cadence | Task | Wiring |
|---|---|---|
| Per job run | heartbeat pings | Healthchecks per job (Phase 7 wiring) |
| Weekly | Xvnc session hygiene (`list-units 'hermes-xvnc@*'`, loopback binding check) + MCP inventory skim | weekly maintenance slot |
| On every MCP/skill/platform/browser change | §15 vetting + threat-model re-review | change checklist |
| After every Hermes upgrade | re-run the claims matrix regression list | ops log habit: `CLAIM → TEST → OBSERVED → COMPENSATION` |
