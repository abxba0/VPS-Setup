# Phase 7 — Observability

> Companion to `docs/PLAN.md` §Phase 7. Authoritative source: `docs/ARCHITECTURE.md` (§13 monitoring & audit, §11 logging privacy). Track your progress in `docs/SETUP-TRACKER.md`. Do not start the next phase until Gate 7 passes.

## Your goal

Monitoring that **dies with the VPS is no monitoring** — so every critical signal is a Healthchecks.io dead-man's switch or an off-box alert routed to your phone; audit logs ship off-box redacted; canaries are planted where agents can reach them; and the gate proves each alert path with a deliberate test, not a plan. On-box monitoring dies with the box — an attacker (**H**) or a wedged agent (**L**) can silence the alarm along with the crime. Every signal gets an off-box leg.

## Non-negotiables this phase enforces

- **#8 — Monitoring independent of the VPS.** No alert that requires the VPS to be healthy in order to fire: every check is a dead-man's switch or off-box (uptime monitor, Healthchecks grace periods).
- **#9 — Break-glass tested** (precondition): observability must survive whatever the break-glass path survives.
- **Golden rule: monitoring has external heartbeat.** A job that logs its own success is the agent grading itself again — detection is external.
- **No raw secrets in shipped logs** — ship redacted, structured events; the audit pipeline must not become the credential thief's (threat **G**) one-stop shop.
- **Canaries must be detectable *and* harmless:** a fake key that actually authenticates somewhere is a real secret, which violates the rule that canaries must not become attack paths.

## Why this phase matters

Phase 7 puts detection *outside* the blast radius: Healthchecks dead-man's switches, off-box log shipping, canaries, and threshold alerts. It converts your earlier deny logs from "data" into *signal*: a spike in `NFT-DENY` lines is your primary evidence of **C**/**F** in progress (an agent trying to exfiltrate), and canary usage is a tripwire for **G**/**D** (credential scanning). It also mandates the data map — retention as a privacy policy (§11), because "log everything forever" is itself a liability.

Threats reduced: **C/F** (exfiltration attempts become visible spikes), **G/D** (canary trips), **H/K** (backup silence detected even if the box is dead), **L** (spend-threshold and repeated-restart alerts).

## Before you start

- Gate 6 passed: backup hardening live, `hermes-restic-check.timer` pinging Healthchecks.
- Healthchecks.io account with integrations available (free tier: web UI + email/Telegram/webhooks).
- Broker audit logs exist at `/var/lib/hermes-broker/audit/` (Phase 3.5) and need shipping.
- The Phase 0 `NFT-DENY` log prefix and per-rule `counter` lines are present and verified (A0-2) — the spike alert in this phase reads exactly those counters.
- Thinkst canarytokens.org account reachable (free, external — independent of the VPS).

## Credential map

| Credential | Level | Lives where | Must NEVER live |
|---|---|---|---|
| Healthchecks.io check UUIDs (ping URLs) | L1 | VPS scripts (write-only beacons) | — (UUIDs are write-beacons; fine on VPS) |
| Log-shipping endpoint credential (off-box) | L2 | VPS shipper config, `0600` | Agent contexts |
| Canary tokens / decoy files | L1 (decoys) | Agent-reachable locations, *clearly fake by construction* | Real scopes anywhere; provider accounts tied to real data |
| auditd rules / syslog config | L3-adjacent | Root-only; audited itself (`-w /etc/audit/rules.d -p wa`) | World-readable |

## Steps

### 1. Healthchecks.io check inventory (create these; free tier)

| Check | Period / grace | Pinged by |
|---|---|---|
| `hermes-backup` | 1 d / 2 h | backup.sh (exists) — `/start` + success/fail |
| `hermes-restic-check` | 7 d / 4 h | check timer service |
| `hermes-restic-deep` | 31 d / 12 h | monthly subset timer |
| `hermes-<job>` per scheduled job | per job schedule + slack | job completion hook |
| `hermes-dash-uptime` | 5 min / 10 min | Healthchecks built-in URL ping from their side (a `ping` check GETting your dash URL) |
| `hermes-box-alive` | 5 min / 15 min | tiny on-box cron: `curl -fsS -m 10 <hc-url>` — proves the box itself is up; combined with dash-uptime distinguishes "box dead" from "app dead" |
| `broker-audit-review`, `break-glass-drill`, `recovery-kit-review` | manual, long periods | you, after doing the task |
| `disk-space` | 1 d | on-box script pings only when `df` OK ("ping = all good" pattern) |

**Integration patterns:**

```bash
# start/finish pattern in job wrappers:
curl -fsS -m 10 "$HC_URL/start"
if job; then curl -fsS -m 10 "$HC_URL"; else curl -fsS -m 10 "$HC_URL/fail"; fi
# exit-code pings (Healthchecks records the code):
myjob; curl -fsS -m 10 "$HC_URL/$?"
```

Healthchecks free tier gives you the web UI + email/Telegram/webhook integrations — use them all (next step).

### 2. Alert routing to a phone

1. Healthchecks.io → Integrations: add **Telegram** (their bot; 2-way so you can `/pause` a check from the phone during drills) **and** email (belt). Test each integration with the "send test notification" button. **Prove it end-to-end:** pause your wifi for 15 min against a 5-min check → phone buzzes. This is the gate; a silent integration is a false sense.
2. Alert channels: backup failures, missed heartbeats, spend alerts (provider webhooks → Healthchecks webhook integration or direct Telegram bot for broker approvals — the broker's approval prompt *is* already a phone alert by design, Phase 3.5).
3. Add the remaining PLAN §7 alert rules: canary token use (via Thinkst → Telegram webhook), blocked-egress spikes, new listening ports, broker approvals outside normal hours, spend threshold breaches, repeated service restarts (systemd `StartLimitBurst=5` / `StartLimitIntervalSec=300` on units + a restart-counter check).

### 3. auditd

```bash
sudo apt install -y auditd audispd-plugins
```

`/etc/audit/rules.d/hermes.rules`:

```
-w /etc/nftables.conf -p wa -k firewall-change
-w /etc/systemd/system/ -p wa -k systemd-change
-w /etc/ssh/ -p wa -k sshd-config
-w /etc/sudoers -p wa -k sudoers-change
-w /etc/sudoers.d/ -p wa -k sudoers-change
-w /usr/local/sbin/ -p wa -k local-sbin-change
-a always,exit -F arch=b64 -S bind -F a2!=0 -k listen-port
-a always,exit -F arch=b32 -S bind -F a2!=0 -k listen-port
-D -b 8192
-f 1
```

(Keep the bind rule broad-but-noisy initially, trim after a week of profiling; `a2!=0` filters port 0. If noise is unmanageable, drop to watching `/usr/sbin/` + the `ss` sweep below.)

```bash
sudo augenrules --load && sudo auditctl -l     # verify loaded
sudo ausearch -k firewall-change -i | tail      # generate an event: touch /etc/nftables.conf → event appears
```

Space safety on 4 GB: `/etc/audit/auditd.conf` → `max_log_file_action = rotate`, `num_logs = 5`, `space_left_action = email` (or `exec` a ping to a dedicated HC check `auditd-disk`).

### 4. New listening ports (belt-and-suspenders, cheap and reliable)

Weekly script:

```bash
ss -tlnp | sort > /run/ports.now
diff /var/lib/hermes-ops/ports.baseline /run/ports.now && curl -fsS "$HC_PORTS_URL" || curl -fsS "$HC_PORTS_URL/fail"
cp /run/ports.now /var/lib/hermes-ops/ports.baseline
```

### 5. Off-box log shipping (redacted)

Simplest robust solo-operator pattern: **rsyslog forward over Tailscale** to a listener on your laptop/home mini-host, or — if you'd rather not run a receiver — systemd-journal-remote to the same. Ship: auth (`ssh`/sudo), auditd (via `audispd` → rsyslog `:programname`), broker audit files (a small shipper tailing them, stripping secrets — never raw env/token values), backup events; Cloudflare events stay in CF's own off-box logs. **Redaction rule: ship the *event*, never the *credential*** — a leak in the log channel must not become a credential leak.

Verify: make a noise event (`sudo systemctl restart hermes-research`), see it arrive on the collector within seconds.

```bash
sudo tail -3 /var/log/hermes/shipped.log        # on-box side
# on the receiver: confirm events arrived WITHOUT secrets:
grep -rE '(sk-|hf_|AKIA|Bearer )' /remote/log/store | wc -l   # expect 0
```

### 6. Canary tokens

Plant **Thinkst canarytokens** (free, external — independent of the VPS, satisfying the off-box rule): fake AWS-style key, fake webhook URL, and a decoy file (`/srv/hermes/research/invoices-2026-Q3-notes.txt` containing a URL-token). Place 2–3 in agent-reachable paths per profile. Any HTTP hit on a token → Thinkst alerts (email/webhook → route into your Telegram via their webhook integration). **Canaries must not be real-looking enough to be used as attack material** — they're fake by construction, and record them in the kit inventory so you never mistake one for a real key during an incident.

Never ship canary *values* into logs you forward off-box.

### 7. Data map

One page, in the repo (`docs/data-map.md`): per data class (conversations, browser data, downloads, agent logs, security logs, audit logs, backups) — what's stored, where, how long, who reads it. Backup retention (7/4/6–12) cross-referenced. This is the privacy-facing artifact; review it with the kit.

### 8. 4 GB budget notes

Everything on-box here is cron-sized scripts and auditd — tens of MB total. **Resist adding a metrics agent (node_exporter+Prometheus, Grafana agent, Datadog):** 100–300 MB that 4 GB doesn't have, and VPS-hosted monitoring dies with the VPS. Healthchecks + auditd + rsyslog forwarding is the designed stack. If you ever want metrics, a free-tier external synthetic monitor beats an on-box agent.

## Adversarial verification (run these attacks)

**A7-1 · Backup-silence alert latency (dead-man's switch).**

```bash
sudo systemctl stop restic-backup.timer        # or kill the running job mid-run
date -u +%s > /tmp/kill-time
```

Then watch: when does the Healthchecks.io alert (email/push) arrive? Record `alert_time - expected_success_time`.

- **PASS:** alert fires within period+grace as configured (e.g., daily check with 1h grace → alert ≤25h after last success; measure the *actual* number and write it down — this is your measured backup-detection latency). The alert reaches a channel independent of the VPS (phone push, not a VPS-hosted notifier).
- **FAIL:** no alert (check was pinged by something else, or grace is absurdly long); or alert only visible if you happen to log into Healthchecks (you were never notified).

**A7-2 · Canary trip.** Place canaries (decoy file with a fake "API key" in `/srv/hermes/research/decoy-credentials.txt`; a fake AWS-format key in an agent-readable path; a decoy webhook URL). Then, as the red team: `sudo -u hermes-research cat /srv/hermes/research/decoy-credentials.txt` and *use* the fake key against the canary's collector endpoint (that's what a real attacker does with a found key).

- **PASS:** alert fires (email/push) within minutes, identifying which canary; the alert itself contains no real secrets (canaries must not become leak paths).
- **FAIL:** used key produces no alert — check the canary's reporting path; or the alert ships the canary's "secret" value in cleartext to a channel an agent could read (canary self-defeating).

**A7-3 · Egress-denial spike.** Script a burst of denied connections from a profile:

```bash
for i in $(seq 1 500); do sudo -u hermes-research curl -m 2 -s http://203.0.113.$((i%200+10))/ -o /dev/null; done
```

- **PASS:** your alert rule (nft counter delta threshold, or log-grep on the off-box shipper) fires a human-visible alert; rate of denials visible in your monitoring.
- **FAIL:** 500 denials logged but no human notified — the log line exists (Phase 0 A0-2 proved it) but nothing reads it.

**A7-4 · Availability + auditd negative tests.**

```bash
sudo systemctl stop cloudflared ; sleep 60 ; sudo systemctl start cloudflared   # uptime check must alert
echo 'Port 22' | sudo tee -a /etc/ssh/sshd_config                                # auditd watch on sshd_config must fire
sudo tail -5 /var/log/audit/audit.log                                            # confirm the event
```

(Revert the sshd line afterwards.) Also start a rogue listener as a profile user: `sudo -u hermes-personal python3 -m http.server 8899` — new-listening-port alert must fire; then kill it.

- **PASS:** each tampering produces the expected external alert; auditd events for `/etc/systemd`, firewall, and SSH config changes appear off-box.
- **FAIL:** changes invisible; auditd present but rules not matching; audit logs only on-box.

**A7-5 · Broker off-hours approval alert.** Trigger a broker approval request at an unusual hour (or via the test profile).

- **PASS:** "approval outside normal hours" alert fires to you.
- **FAIL:** silent.

**Extra cross-check (dead-man's switch mechanics):**

```bash
# stop the backup job deliberately, wait past the Healthchecks grace period
# -> alert MUST arrive on your device. Then re-enable:
sudo systemctl stop hermes-backup.timer
sudo systemctl start hermes-backup.timer
```

## Pitfalls

1. **Monitoring the VPS from the VPS** (a cron that emails you from the box). When the box is the incident, the mailer is the first casualty. Every signal has an off-box leg.
2. **Heartbeats without grace periods.** A 24h backup cadence with a 5-minute grace period alert-fires constantly until you ignore it. Set grace ≈ 1–2× interval; alert fatigue is how real alarms get missed.
3. **Canaries that are real credentials.** A "canary" API key with actual scope is an attack path you planted yourself. Decoys: fake format, fake provider endpoint you control, or read-baited decoy files — detectable, useless to the attacker.
4. **Shipping raw logs off-box** (cookies, bearer headers, provider keys in stack traces). Redact at the shipper; the remote store must be assumed readable-by-insider.
5. **Alerts with no owner/latency check.** Test each alert path *once* end-to-end (trigger → phone buzz) and record latency; an untested alert rule is a wish.
6. **Alert fatigue → rubber-stamping:** tune after the first month (reduce check count, lengthen manual-review periods) rather than muting the channel. A muted channel is worse than none.
7. **Healthchecks.io outage:** heartbeats ping into the void — false negatives only (you'd miss a *real* failure), no false alarms. Acceptable for free tier; the quarterly drills double as implicit "is monitoring alive" checks (note the *absence* of HC summary emails).
8. **auditd disk pressure:** space_left actions configured above; check `sudo auditctl -s` for `lost_events` > 0 — lost events = tune rules down, not ignore.
9. **rsyslog forward queue backup** when the laptop collector is offline: default in-memory queue buffers; verify with `rsyslogd -N1` and a deliberate offline test; old queued logs are better than lost, but set a queue cap so a week-long outage doesn't fill `/var`.

## Gate 7 — honest pass checklist

From `docs/PLAN.md` Gate 7: *kill the backup job deliberately → external alert fires within its grace period; touch a canary → alert fires; a denied egress spike produces an alert.*

- [ ] Dead-man's switch proven: backup job stopped → alert arrived on your phone within period+grace; **measured latency written down** (A7-1); timer re-enabled.
- [ ] Canary touched → Thinkst alert arrived identifying which canary; alert content contains no real secret (A7-2).
- [ ] Denied-egress spike: 500-probe burst produced denials in `journalctl -k` **and** a human-visible alert (A7-3).
- [ ] Uptime check flap: `cloudflared` stopped 60 s → external alert; restored → green (A7-4).
- [ ] auditd: `ausearch -k sshd-config` (and firewall/systemd keys) shows the tamper events; events also arrive off-box.
- [ ] New-listening-port alert fired on the rogue `python3 -m http.server 8899` listener.
- [ ] Broker off-hours approval alert fired (A7-5).
- [ ] Off-box shipping live and **redacted**: pattern battery (`sk-`, `hf_`, `AKIA`, `Bearer`, email addresses) greps to zero on the remote store.
- [ ] All Healthchecks checks green on the dashboard in a single view; the *manual* review checks (kit review etc.) are the only yellow ones mid-cycle, by design.
- [ ] `docs/data-map.md` published and dated.

**Fake-pass warnings:**
- (a) "The alert system works" tested by looking at dashboards instead of *receiving the alert on the actual device you'd have at 3 a.m.*
- (b) Spike test using a destination that generates no `NFT-DENY` lines (network-level timeout) — count the log lines first, then check the alert corresponds to *logged* denials.
- (c) Redaction "verified" by grepping for one known secret — grep for a *pattern battery* (sk-, AKIA, Bearer, email addresses) in the remote store.

**Evidence to record in `docs/SETUP-TRACKER.md` + ops log:** per-alert test log (trigger command, time triggered, time received, channel) — this becomes the quarterly re-verification list; HC check inventory with periods/graces; auditd rule file path; shipper config location; canary inventory (names + where planted, never values).

## Learner's corner

**What you'll learn in this phase**

- Dead-man's-switch monitoring: detecting *absence* of events, the only reliable way to monitor a system that may be dead.
- Alert design for a solo operator: each alert must be actionable, external, and tested by *causing* the condition.
- auditd watch rules (`-w` on paths) and why raw secrets never ship off-box (log redaction).
- Canary tokens as tripwires: placement, reporting path, self-containment.
- Threshold alerting on counters (nftables denials) — turning logs into signals.

**Concept primer.** A monitor that *polls* a dead system reports "down" — but a monitor you never query, or whose querying path also died, reports nothing at all. The dead-man's switch inverts the dependency: Healthchecks.io expects a ping by time T; silence *is* the signal, and since Healthchecks lives off the VPS, the silence is observable even when the VPS is fully dead. Every control in this phase follows the same shape — make the condition *externally observable*: a killed backup (no ping), a touched canary (call to a collector you don't host), a denial spike (counter delta crossing a threshold), an off-hours approval (timestamp outside a window). The red-team rule for monitoring is that an untested alert is a wish: each alert is only "installed" after you've deliberately triggered it and *received the notification*. Canaries obey one extra constraint: they must be attractive to an attacker but harmless to you — a fake key whose only power is to phone home, never a real-looking credential that could actually authenticate anywhere.

**Check-your-understanding**

1. Why must the backup-failure alert path not run on the VPS itself?
   *Answer: the most important moment to know the backup failed is exactly when the VPS is compromised or dead — the same event likely takes out an on-box notifier. External heartbeat keeps the detector in a different failure domain from the thing detected.*
2. A canary is a fake credential in an agent-reachable location. Why must it never look *too* real (e.g., a valid-format key that happens to work somewhere)?
   *Answer: canaries are tripwires, not credentials — if a canary can authenticate anywhere, it has become a real secret in agent reach (a new attack path, violating the phase's own constraint). Its entire capability must be "alert when touched."*
3. You get an egress-denial alert. Name two very different causes it could indicate and what you'd check first for each.
   *Answer: (a) benign — a scheduled job hitting a domain you forgot to allowlist (check which profile/UID and destination, correlate with job schedule); (b) hostile — prompt-injection exfiltration attempt (check the destination against known-bad, inspect what the profile was ingesting, look for repeated same-destination pattern). The alert's payload should carry UID + destination to let you triage in seconds.*
4. Why alert on "broker approvals outside normal hours" when every approval already required out-of-band human action?
   *Answer: approvals are human-approved, but the *timing pattern* is a compromise signal — an attacker who socially-engineered or fatigued you into rubber-stamping, or is probing the broker, shows up as anomalous request timing. The alert watches the process, not just the outcomes.*

**Do-it-yourself habit.** Build an "alert test log" — one row per alert: trigger method (exact command), time triggered, time received, channel. Then set a quarterly calendar reminder to re-run every row. An alert that hasn't fired in 6 months is unverified; re-prove each one or delete it.

## Steady state added by this phase

| Cadence | Task | Wiring |
|---|---|---|
| Continuous | heartbeats, uptime, canaries | Healthchecks (above) |
| Weekly | ports-baseline script + audit skim + HC manual checks | timers + calendar slot |
| Monthly | auditd rules noise-trim; data-map touch-up if data classes changed | calendar |
| Quarterly | re-run every row of the alert test log | calendar |
| On incidents | post-incident: add the missing alert | incident template |
