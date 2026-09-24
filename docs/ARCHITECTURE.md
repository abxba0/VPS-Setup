# Hermes Agent Secure VPS Platform — Architecture

**Source of truth:** `CONTEXT_HYBRID` v0.3 (2026-09-24). This document is a condensed, implementation-facing view of that spec. Where this file and CONTEXT_HYBRID disagree, CONTEXT_HYBRID wins.

---

## 1. What this is

A self-hosted personal AI-agent platform (Hermes Agent) on a small OVH VPS (~£5/mo, 4 GB RAM), supporting research, coding, browser/terminal automation, computer use, scheduled tasks, messaging, email, MCP, skills, persistent memory, and human browser takeover.

**Fundamental design principle:** the VPS is disposable. Identity, secrets, data, infrastructure definition, and recovery capability must survive its loss.

**Golden rule:** *Never rely on an AI agent to enforce a security boundary that the AI agent itself has the power to bypass.*

Priority order: security → credential protection → recoverability → reliability → privacy → capability → efficiency → cost.

---

## 2. System overview

```text
USER DEVICES (passkey/FIDO2)
        │  Identity + MFA
        ▼
    Tailscale ──► Admin plane (SSH, emergency access)
        │
        ▼
┌───────────────────────── OVH VPS ─────────────────────────┐
│  nftables: default-deny inbound AND default-deny egress   │
│                                                            │
│  Tailscale (tagged node) ── admin only                     │
│  cloudflared ──► Cloudflare Access ──► Hermes Dashboard    │
│                                          │ OAuth/OIDC      │
│                                          ▼                 │
│                                     Hermes Agent           │
│                    (profiles: personal / research /        │
│                     automation / high-risk)                │
│                            │                               │
│                       Bot Screen                           │
│              (Xvnc + Xfce, localhost only)                 │
│                                                            │
│  Approval Broker ──► narrow privileged executor            │
│  Infisical ── runtime secrets (per-profile machine creds)  │
│  Restic ──► encrypted backup ──► Cloudflare R2             │
│             (browser profiles/cookies EXCLUDED)            │
└────────────────────────────────────────────────────────────┘

INDEPENDENT SYSTEMS (must survive VPS loss):
• Healthchecks.io — dead-man's switch / heartbeats
• Offline recovery kit — printed + encrypted, separate locations
• Off-box Level-4 credential store — Cloudflare/OVH/R2 admin
  never on the VPS; driven from laptop via OpenTofu
```

---

## 3. Security boundaries (8 independent layers)

| # | Boundary | Technology | Purpose |
|---|----------|-----------|---------|
| 3.1 | Infrastructure identity | Tailscale | SSH, admin, emergency access |
| 3.2 | Public app identity | Cloudflare Access | Dashboard, browser-facing access |
| 3.3 | Application identity | Hermes OAuth/OIDC | App auth, defense in depth |
| 3.4 | Secret identity | Infisical | Runtime creds/API keys; **machine credential scoped per profile** — never one shared credential per box |
| 3.5 | Agent execution | Linux users + systemd sandbox + rootless containers | Profile/browser/terminal/filesystem isolation |
| 3.6 | Network | nftables + network namespaces + proxy policy | Inbound + outbound filtering, per-user (`meta skuid`) egress |
| 3.7 | Privileged action | External approval broker | Financial, DNS, Cloudflare, infra, destructive actions. **Level 4 credentials never on the VPS** |
| 3.8 | Recovery | Offline kit + independent provider access | VPS loss, Tailscale/IdP/Infisical/R2 lockout |

Each boundary must sit at a layer the component it protects cannot bypass.

---

## 4. Threat model (mandatory)

**Assets:** credentials & API keys, personal data, money & accounts, infrastructure control (Cloudflare/Tailscale/DNS), the agent's email/messaging identity, backups.

**Adversaries / failure modes:**

| ID | Threat | Worst case |
|----|--------|-----------|
| A | Internet attacker | Exploits exposed services |
| B | Malicious website | Browser exploitation / prompt injection |
| C | Indirect prompt injector | Data exfiltration, harmful action |
| D | Malicious MCP/tool | Code execution, credential theft |
| E | Compromised API/service | Silent persistence on VPS |
| F | Compromised agent session | Attacker acts as you/agent |
| G | Credential thief | Stolen keys/cookies/backups creds |
| H | VPS compromise | Persistence, backup destruction |
| I | Operator error | Lockout, deleted backups, exposed port |
| J | Provider failure | OVH/CF/Tailscale/Infisical/R2 outage |
| K | Backup destruction | Ransomware / stolen R2 keys |
| L | Runaway cost | Looping scheduled task burns budget |

**Rule:** every new component must state which threat (§4.2 ID) it reduces.

**Worst-case scenarios** (15) that must be considered include: prompt-injection exfiltration, agent obtaining privileged creds, agent sending money, agent changing DNS, agent deleting backups, VPS compromise, provider lockout, attacker destroying VPS + backups, looping scheduled job creating large bills, browser exploit escaping its environment.

---

## 5. Network security

### Host firewall (nftables)
Default: `INPUT DROP`, `FORWARD DROP`, `OUTPUT DROP`; explicitly allow what's required. **Test `OUTPUT DROP` with an `at` job that flushes after ~5 minutes** so a bad rule can't lock you out.

### Infrastructure egress
Explicitly defined only: DNS, Tailscale, cloudflared, package repos, NTP, Infisical, backup storage, monitoring, model providers.

### Agent egress (per-profile, matched by Linux user)
```text
Hermes profile → Linux user (meta skuid) → network namespace
  → egress proxy/policy gateway → domain/action policy → Internet
```
- Strict profiles (personal, automation): allowlist of LLM APIs, Infisical, Cloudflare, R2, named service domains.
- Research profile: open web **reads** through a logging proxy; no credentials; no send-capable tools.
- Log blocked egress; alert on repeated denials; controlled/logged DNS resolver.

### SSRF
Keep Hermes' built-in protections on (verify against current docs first — see §10 caveats), plus network-layer blocking of RFC1918/loopback/link-local/CGNAT/metadata endpoints and `fc00::/7`.

---

## 6. Access & identity

### Cloudflare Access origin validation
Never assume tunnel = trusted. Validate `Cf-Access-Jwt-Assertion` (signature, issuer, audience, expiry, claims). Short Access session lifetime; stricter policy for admin/approval routes.

### Tailscale
Tagged node (`tag:hermes-vps`), least-privilege grants, passkeys/FIDO2, device posture, check mode for sensitive SSH. **Key expiry intentionally disabled** for the tagged server — documented exception (why: unattended reachability; risk: longer-lived node identity; mitigations: tags, restricted grants, MFA, OVH rescue, monitoring, rotation).

### Break-glass (independent emergency access)
- OVH control panel, KVM/console, rescue mode; documented procedure.
- Protected by hardware key + separate strong credential; **two hardware keys, one offline**.
- **Test quarterly.**

### Human auth
Passkeys/FIDO2 preferred over SMS; TOTP backup only; ≥2 independent auth/recovery methods.

---

## 7. Recovery architecture

### Circular dependency (solved by escrow)
Restore needs Restic password + Infisical + IdP codes. If those live only inside the systems being recovered, recovery is impossible. **Fix: offline recovery escrow, never on the VPS.**

### Offline recovery kit contents
OVH/Tailscale/IdP/Infisical/R2/Cloudflare/domain recovery material, Restic repo password, emergency contacts, architecture diagram, recovery procedure, last known-good config commit.
**Storage:** encrypted, offline, password manager **plus** printed copy in a separate physical location; reviewed twice a year; never raw secrets in Git.

### Restic credential separation
| Credential | Can | Cannot | Lives |
|---|---|---|---|
| Backup writer | write snapshots | prune/delete/destroy | VPS (scoped) |
| Backup admin | forget/prune/restore | — | trusted machine, off-VPS |
| Recovery credential | restore + maintenance | — | offline kit |
| Cloudflare admin | everything | — | **never on VPS** (Level 4) |

### R2 protection
Bucket-scoped least-privilege credentials, retention policies, **bucket locks** (prevent deletion/overwrite for a period). Writer must not have account-wide permissions. **Browser profiles and cookies are excluded from Restic** — a leaked backup must not be a leaked login.

### Backups — five layers
1. OVH snapshot (fast rollback)
2. Hermes-native backup
3. Restic encrypted backup (browser data excluded)
4. Cloudflare R2 protected repository
5. Independent secondary backup (different provider + credentials, append-only if possible)

**Checks & policy:** scheduled `restic check` + `--read-data-subset`; failure = incident. Retention 7 daily / 4 weekly / 6–12 monthly — retention is also a privacy policy; set it deliberately. RPO 24h max (<6h preferred); RTO 4h initial, 1–2h after rebuild automation. **Quarterly scheduled rebuild test:** temp VPS → IaC bootstrap → restore → verify → destroy. Success = no undocumented manual steps.

### Recovery independence
Recovery must work without Hermes, VPS, Tailscale, Infisical, Cloudflare, browser sessions, or the primary IdP.

---

## 8. Agent isolation

### Profile trust rule (core invariant)
No profile may combine all three of: **(1) private data/credentials, (2) untrusted content, (3) outbound communication.** Two of three OK; three = direct exfiltration path.

| Profile | Private data | Untrusted content | Outbound | Egress policy |
|---|---|---|---|---|
| personal | yes | no | limited | strict allowlist |
| research | no | yes | web read only | open web, no creds, no send tools |
| automation | scoped | limited | specific APIs | strict allowlist |
| high-risk | temporary | no | via broker only | broker only |

### Linux users
`hermes-personal`, `hermes-research`, `hermes-automation`, `hermes-highrisk` — each with own workspace, browser profile, X resources, credentials, and Infisical secret scope. Mode 0700, no cross-profile reads.

### systemd sandboxing (incremental, test after each step)
`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`, `RestrictSUIDSGID`, `RestrictNamespaces`, `CapabilityBoundingSet=`, `SystemCallFilter`, `MemoryMax` (browser especially), `TasksMax`, explicit `ReadWritePaths`.

### Browser & terminal isolation
Browsers in **rootless containers from day one** — one container per trust level, restricted mounts, **no host Docker socket**, restricted network, disposable profiles. Terminal workloads in containers with limited filesystem + restricted network. Downloads land in a **quarantine** directory; never auto-executed.

### Filesystem layout
```text
/srv/hermes/personal|research|automation|highrisk   # per-profile, 0700
/srv/hermes/quarantine                              # downloads, never auto-executed
/srv/hermes/backups/staging
/var/lib/hermes        # Hermes core state
/var/log/hermes        # redacted logs, shipped off-box
/srv/hermes/<p>/browser|cookies    # isolated, EXCLUDED from Restic
# Never agent-readable: /etc/nftables.conf, /etc/systemd/system/hermes*, /root
```

### Browser session policy
Avoid logging into sensitive personal accounts via Bot Screen. Prefer scoped OAuth/API tokens/dedicated accounts. If unavoidable: operate → log out → clear cookies → terminate session → destroy temp creds. Bot Screen sessions are per-profile, localhost-only.

---

## 9. Approval architecture (anti self-approval)

**Problem:** if Hermes decides which actions are risky, the model grades its own homework and an injected agent can skip its own check. The model must never classify → approve → execute.

```text
Hermes → request (exact action/args/target/reason)
       → Approval Broker (no LLM, fixed schemas)
       → human OUT-OF-BAND (Telegram button / push on another device;
         a "YES" in chat is insufficient)
       → signed, single-use, short-lived approval token
       → narrow privileged executor (typed ops only, e.g. create_dns_record();
         never run_as_root(command_string))
       → tamper-resistant audit log, shipped off-box
```

**Broker rules:** small, single-purpose, no LLM, no arbitrary shell, explicit operation schemas, single-use expiring tokens bound to exact action+target+params, rate limits, replay protection, own user, strong auth.

**Approval request must contain:** action, exact arguments, target, account, requested credential, reason, originating profile, timestamp, expiry, risk category. No ambiguous approvals ("allow Hermes to do DNS" is forbidden).

**Credential placement (v0.3, critical):**
- **Level 4 credentials (Cloudflare admin, OVH, R2 admin): off the VPS entirely.** You make those changes yourself via OpenTofu from your laptop. Delegated L3/4 automation, if genuinely wanted, runs on separate infrastructure.
- **Level 3 credentials live only in the broker** — never in agent contexts, env vars, or agent-readable files.
- Hermes must never possess: unrestricted Cloudflare/DNS/OVH/R2/Infisical credentials, payment credentials, or unrestricted infra credentials.

**Risk levels:** L0 read/research · L1 create/edit non-sensitive files · L2 send messages/email/modify external docs (allowlists + rate limits, no per-action approval) · L3 financial/account/credential changes · L4 DNS/Cloudflare/firewall/infra/secrets/backup destruction/root. **L3/L4 require external approval and must be kept rare** — approval fatigue leads to rubber-stamping.

**Audit trail per action:** request ID, timestamp, profile, action, target, arguments, human identity, decision, executor, result.

### Emergency kill switch
Executable without trusting Hermes: stop Hermes, stop browser, stop scheduled jobs, disable external access, revoke credentials. Available via Tailscale/admin path **and** OVH console/rescue path.

---

## 10. Hermes configuration & caveats

Keep Hermes built-in security enabled (defense layers, not replacements for host/network isolation): dangerous-command approvals, manual approval mode, file-write safety, write sandbox, container isolation, MCP credential filtering, context-file scanning, cross-session isolation, terminal cwd validation, SSRF protection, website blocklist, messaging allowlists, DM pairing.

**⚠ Unverified claims (§79 of spec) — verify against current Hermes docs before designing around them:**
- [ ] Bot Screen (behaviour, session storage, cleanup)
- [ ] Built-in approvals (coverage, bypassability)
- [ ] SSRF protection (defaults, coverage)
- [ ] Tool gateway / MCP credential filtering
- [ ] Website blocklist enforcement layer
- [ ] Messaging DM pairing

If any claim is wrong, compensate at the network/host layer, not inside Hermes.

Blocklist internal dashboards, cloud admin pages, secret-management UIs, private infrastructure. Messaging: explicit allowlists only — unknown sender → deny/pairing. Email: dedicated `agent@domain` mailbox, never personal mailbox; approved senders; approval for sensitive outgoing mail.

---

## 11. Cost & operational safety

- **API segmentation:** separate keys per profile (personal/research/automation/development). Never one master key.
- **Spend caps:** hard monthly cap per API key and per profile, provider-side limit where supported; alert at 50% and 80%; auto-disable at 100%.
- **Scheduled jobs:** every autonomous task has max runtime/frequency/tool calls/tokens, allowed tools/domains/credentials, cost budget, output limits, failure handling, **kill switch**, external monitoring. A looping job is a high-probability failure.
- **Model routing:** cheap/fast models for routine tasks; strong models for high-risk reasoning and privileged-action prep; log tokens per task.
- **LLM privacy:** document each provider's training/retention/ZDR/logging/region policies; enable strictest settings (ZDR/no-training); review on terms changes.
- **Logging privacy:** structured, redacted (no keys/tokens/cookies/auth headers/PII), defined retention. Data map published (what/where/how long/who reads).
- **Data retention** defined separately for conversations, browser data, downloads, agent logs, security logs, audit logs, backups — deleted data persists in snapshots until expiry.
- **Performance (4 GB):** zram, conservative swap, earlyoom (browser dies before system stalls), systemd `MemoryMax`/`TasksMax`, one headed browser at a time, idle Bot Screen shutdown. Upgrade to 8 GB when workload requires.

---

## 12. Infrastructure as Code

| Layer | Tool | Scope |
|---|---|---|
| Provisioning | cloud-init | Bootstrap, initial user/network/packages |
| Infra | OpenTofu (from **laptop**, never VPS) | OVH where supported, Cloudflare (tunnel/DNS/Access), R2, Tailscale tags/grants |
| Config | Ansible | OS hardening, users, packages, firewall, systemd, Hermes install, monitoring |
| Secrets | Infisical runtime injection | Never rendered into Git |
| Updates | Renovate/Dependabot | Via staging path |
| Git hygiene | Gitleaks (pre-commit + CI), pre-commit hooks, version pinning, signed commits | No secrets/tokens/recovery codes/private keys/prod `.env` in Git |

**Update workflow:** backup + OVH snapshot → staging → test → production → health check → monitor → confirm. Snapshot = fast rollback; Restic = durable DR; neither replaces the other.

---

## 13. Monitoring & audit

- **Off-box monitoring is mandatory** — on-box monitoring dies with the box. Healthchecks.io for backup heartbeat, uptime, critical job heartbeats; monitor cert expiry.
- **Alerts on:** canary token use, blocked-egress spikes, new listening ports, broker approvals outside normal hours, spend threshold breaches. Repeated service restarts → human alert + systemd `StartLimit`.
- **Audit log offloading:** auth, sudo, privileged-action requests/decisions, broker logs, backup events, Cloudflare events, significant agent activity — copied off-box, append-only where possible, redacted. auditd rules for sudo, new listening ports, changes to `/etc/systemd`, firewall, SSH config.
- **Canary tokens:** fake API keys / decoy files in agent-reachable locations; any use alerts. Must not become secrets or attack paths themselves.

---

## 14. Incident response

**Suspected agent compromise:** stop agent → stop browser → revoke profile credentials → inspect logs + network events → rotate affected creds → inspect backups → determine blast radius.

**Suspected VPS compromise:** isolate → preserve evidence → revoke creds (Tailscale/Cloudflare if needed) → provision new VPS → restore known-good → rotate secrets → verify.

**Privacy incident:** identify provider/data/period → revoke/rotate → delete copies → inspect logs → review backup retention → document.

---

## 15. MCP / skill vetting (gating checklist)

No unreviewed MCP. No unreviewed skill. Before adding:
- [ ] What code runs? Source, publisher, commit-pinned?
- [ ] What credentials can it see (env, files, secret scope)?
- [ ] Network access needed — each domain justified?
- [ ] Filesystem access needed — each path justified?
- [ ] Tools exposed — any send data outward?
- [ ] Survives the profile trust rule (§8)?
- [ ] Which §4 threat does it reduce — or worsen?
- [ ] Blast radius if malicious/compromised? Removal/rotation path?
- [ ] Re-review after every version bump.

A skill/MCP failing the trust rule runs in the **high-risk profile or not at all**. Re-review the threat model after any new MCP/skill/platform/browser capability/privileged operation/credential/public endpoint, or major Hermes/OS update.

---

## 16. Review process

**One-page review checklist** (run before any significant change — replaces the fifteen-expert model for one-person operation):
1. **Boundary** — which boundary sits behind; can the agent bypass it?
2. **Threat** — which §4 threat does it reduce (if none, why add it)?
3. **Trust rule** — does it create private+untrusted+outbound in one profile?
4. **Credentials** — what new creds exist, where, who/what reads them?
5. **Worst case** — blast radius if compromised?
6. **Recovery** — if it fails/vanishes, can we still recover?
7. **Egress** — network access needed; allowlisted and logged?
8. **Cost** — cost and cap?
9. **Monitoring** — how do we know it misbehaves?
10. **Rollback** — how to undo safely?
11. **Testing** — what proves it works?
12. **Docs** — data map, decisions log, threat model updated?

Full fifteen-expert review retained for genuinely major changes.

---

## 17. Golden security rules (31)

**v0.1 (1–20):** No public VNC · no unnecessary public SSH · no Hermes as root · no secrets in Git · no unrestricted sudo · no unrestricted agent egress · no profile combining unrestricted private data + untrusted content + outbound · no privileged credentials in Hermes · no agent-controlled final approval · no single recovery dependency · no backup without restore testing · no single destructive backup credential · no unreviewed MCP · no unreviewed skill · no unrestricted browser session to sensitive accounts · no open messaging gateway · no unaudited privileged action · no assumption Cloudflare alone = app identity · no VPS-only monitoring · no VPS-dependent recovery.

**v0.2 (21–29):** No profile combines private+untrusted+outbound · outbound default-deny · L3/L4 credentials never enter agent context (broker only) · approvals enforced out-of-band · recovery secrets escrowed offline · monitoring has external heartbeat · every key/profile has spend cap · break-glass exists and is tested · every component names the threat it reduces.

**v0.3 (30–31):** **L4 credentials never on the VPS — not even in the broker** · **browser profiles/cookies never in backups**.

---

## 18. Key decisions log (summary)

| Decision | Reason | Rollback |
|---|---|---|
| External broker enforces approvals | Injected agent can fake its own risk assessment | Disable broker routes; L3/4 unavailable |
| Default-deny egress per Linux user | Primary exfiltration path of hijacked agent | Relax per-profile rules |
| Offline recovery escrow | Restore can't depend on systems being restored | N/A |
| L4 credentials off-VPS (v0.3) | VPS root compromise must not imply infra compromise | Return creds to broker (not recommended) |
| Browser data excluded from backups (v0.3) | Leaked backup ≠ leaked login | Re-include with separate encryption if needed |
| Minimum tier first — Phase 0 (v0.3) | Full isolation stack too heavy for 4 GB; tested restore early > late perfection | N/A (ordering) |

---

## 19. Target operating model

```text
LOW TRUST  ↑  web content → browser agent → research → automation
           → personal → privileged broker → HUMAN  ↓  HIGH TRUST
```

The model never becomes the ultimate authority.
