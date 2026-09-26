# Hermes Agent Secure VPS Platform — Setup Plan

**How to use this plan:** work top-to-bottom. Each phase ends in a **gate** — do not start the next phase until the gate passes. The ordering is deliberate: a tested restore and offline escrow exist *before* any agent runs; the approval broker exists *before* any Level 2+ capability; Level 4 credentials never touch the VPS at any point.

Reference: `ARCHITECTURE.md` (condensed) ← `CONTEXT_HYBRID` v0.3 (authoritative).

---

## Phase 0 — Minimum viable tier (build this first)

Goal: a safe, working baseline you can already restore — not the full isolation stack. The full stack (per-profile users, rootless containers, egress proxy, broker, Xvnc) is heavy for 4 GB; get a proven foundation first.

### 0.1 Accounts & prerequisites (do these before provisioning)
- [ ] Create/secure OVH account: passkey or FIDO2 primary, TOTP backup, recovery email + phone verified.
- [ ] Register two FIDO2 hardware keys; store one offline, physically separate.
- [ ] Create Cloudflare account (MFA/passkey), add your domain, point nameservers.
- [ ] Create Tailscale account (passkey/MFA).
- [ ] Create Healthchecks.io account (free tier is fine).
- [ ] Create Infisical account (cloud or self-host plan decided; see Phase 2).
- [ ] Choose VPS: OVH ~£5/mo class, 4 GB RAM, Ubuntu LTS.
- [ ] Create a Git repo for IaC (`vps-setup`): Gitleaks pre-commit hook installed **before** first commit.

**Gate 0a:** all accounts exist with passkey/FIDO2 auth; Gitleaks hook verified by attempting a fake-secret commit (must be blocked).

### 0.2 Provision & bootstrap the VPS
- [ ] Provision VPS with cloud-init: initial user, SSH keys only (no password auth), unattended security updates.
- [ ] Verify OVH rescue mode + KVM/console access works **now**, while everything is healthy.
- [ ] Install Tailscale on the VPS; tag the node `tag:hermes-vps`.
- [ ] Tailscale SSH **and Cloudflare Access SSH (tunnel → `ssh://localhost:22`)** as the two identity-gated admin paths; disable direct/public SSH in the firewall (step 0.3). Document the key-expiry exception for this tagged node (why/risk/mitigation — see ARCHITECTURE §6).
- [ ] Non-root Hermes install.

### 0.3 Firewall — inbound and outbound
- [ ] nftables: `INPUT DROP`, `FORWARD DROP` initially; allow Tailscale interface, loopback, established.
- [ ] **OUTPUT policy: do not set `OUTPUT DROP` blind.** Use the timed-flush pattern:
  1. Write the OUTPUT rule set to a known-good file.
  2. Schedule `at now + 5 minutes` job that restores the known-good ruleset.
  3. Apply the restrictive rules, test everything (DNS, updates, tunnel, Tailscale, Hermes APIs).
  4. If all good before deadline, remove the `at` job; otherwise let it flush.
- [ ] Allow only infrastructure egress: DNS, Tailscale, cloudflared, package repos, NTP, Infisical, backup endpoint, model providers.
- [ ] Log denied packets.

**Gate 0b:** inbound scan from outside shows nothing but expected; with `OUTPUT DROP` active, a non-allowlisted outbound connection is logged and denied; the timed-flush rollback was actually exercised at least once.

### 0.4 One research profile with egress limits
- [ ] Create `hermes-research` Linux user; workspace at `/srv/hermes/research` (0700, owned by profile user).
- [ ] Egress policy for this user via nftables `meta skuid`: open web reads, **no** private-network destinations (RFC1918/loopback/metadata), **no** credentials, **no** send-capable tools.
- [ ] Quarantine dir `/srv/hermes/quarantine` — downloads land here, never auto-executed.
- [ ] Install Hermes as non-root service (systemd, `NoNewPrivileges=yes`, `ProtectSystem=strict`, `PrivateTmp=yes` at minimum); test Hermes functionality after each hardening step, add more incrementally.

### 0.5 First backup + **tested restore** (nothing later may rely on an unproven backup)
- [ ] Create R2 bucket + **bucket-scoped, write-only** credential (cannot prune/delete/administer).
- [ ] Install Restic on VPS with the writer credential only. Exclude: browser profiles, cookies, caches.
- [ ] Schedule daily backup; set retention (7 daily / 4 weekly / 6–12 monthly) — the prune credential does **not** go on the VPS.
- [ ] Add Healthchecks.io heartbeat ping on backup success/failure.
- [ ] **Do a full restore test to a scratch directory (or a second machine) using the recovery credential from your laptop.** Compare checksums.

**Gate 0 (Phase 0 exit — all must pass):**
- [ ] SSH only via the two identity-gated paths — Tailscale SSH and Cloudflare Access SSH (tunnel → localhost:22); password SSH disabled; direct/public SSH denied and logged.
- [ ] Firewall default-deny both directions, with logged denials.
- [ ] Hermes running non-root, sandboxed, with one research profile limited to web reads.
- [ ] A restore from backup succeeded **from the laptop using offline-held credentials**.
- [ ] Backup heartbeat visible in Healthchecks.io.

---

## Phase 1 — Break-glass and identity hardening

- [ ] Document and physically secure the break-glass path: OVH console/KVM/rescue, protected by hardware key + separate strong credential.
- [ ] Confirm both hardware keys work (primary + offline backup).
- [ ] Passkeys/FIDO2 enforced on: OVH, Cloudflare, Tailscale, Infisical, Healthchecks.io.
- [ ] Tailscale grants: least-privilege, device posture where practical, check mode for sensitive SSH.
- [ ] **Test the full break-glass path end-to-end**: assume Tailscale is unavailable → reach OVH console → log in → run a rescue command.

**Gate 1:** you can get into the machine without Tailscale, and into every account without your primary device. Break-glass test dated in the operations log (repeat quarterly).

---

## Phase 2 — Recovery escrow and cost caps *(before any agent runs)*

### 2.1 Offline recovery kit
- [ ] Write down / escrow, encrypted + printed, stored in **two separate physical locations**:
  - OVH account recovery info; Tailscale recovery info
  - IdP recovery codes + hardware-key backup
  - Infisical recovery/admin credentials
  - **Restic repository password**
  - R2 restore-capable credential; prune credential
  - Cloudflare + OVH account recovery details; domain/DNS recovery
  - Emergency contacts; architecture diagram; recovery procedure; latest known-good config commit hash
- [ ] Verify you can open the encrypted kit **without** the VPS, without Infisical, without Cloudflare.
- [ ] Calendar reminder: review twice a year.

### 2.2 Infisical
- [ ] Set up project with separate environments (dev/prod).
- [ ] **Machine credentials scoped per profile** — never one shared credential per box. Secrets injected only into the process that needs them.
- [ ] Store model-provider keys per profile now (segmentation from day one).

### 2.3 Spend caps
- [ ] Every API key: hard monthly spend cap (provider-side where supported).
- [ ] Per-profile budget recorded; alerts at 50% and 80%; auto-disable at 100%.
- [ ] Each key tagged with the profile it belongs to (personal/research/automation/development — separate keys, never a master key).
- [ ] Document each model provider's privacy policy (training, retention, ZDR availability, region); enable strictest settings.

**Gate 2:** recovery kit verified offline; every agent-bound credential in Infisical behind a per-profile machine credential; all API keys capped with alerts wired.

---

## Phase 3 — Isolation baseline *(before enabling browser or tools)*

- [ ] Create remaining Linux users: `hermes-personal`, `hermes-automation`, `hermes-highrisk` — each 0700 workspace, no cross-profile reads.
- [ ] Implement the **profile trust rule** (no profile combines private data + untrusted content + outbound):

  | Profile | Private data | Untrusted | Outbound | Egress |
  |---|---|---|---|---|
  | personal | yes | no | limited | strict allowlist |
  | research | no | yes | web read only | open web, no creds |
  | automation | scoped | limited | specific APIs | strict allowlist |
  | high-risk | temporary | no | broker only | broker only |

- [ ] Rootless Docker/Podman installed; browsers run in rootless containers **from day one** — one container per trust level, restricted mounts, **no host Docker socket**, restricted network.
- [ ] Terminal workloads in containers: limited filesystem, restricted network.
- [ ] systemd sandboxing extended per unit (full list in ARCHITECTURE §8); `MemoryMax` on browser units; `TasksMax` everywhere.
- [ ] Per-user egress rules for all profiles (`meta skuid`), default-deny, logged.
- [ ] Performance: zram + swap + earlyoom installed (earlyoom must kill the browser before the system stalls). One headed browser at a time.
- [ ] Filesystem layout per ARCHITECTURE §8; `/etc/nftables.conf`, `/etc/systemd/system/hermes*`, `/root` unreadable by all agent users.

**Gate 3:** from inside each profile, attempt: read another profile's dir (fail), touch private networks/metadata (fail, logged), reach a non-allowlisted domain (fail, logged). All four profile trust rows hold.

---

## Phase 3.5 — Approval broker *(before any Level 2+ capability)*

This is the most security-critical component. Keep it boring.

- [ ] Build/deploy the broker as its own Linux user, own service:
  - No LLM. No arbitrary shell. Fixed operation schemas only (`create_dns_record()`, `rotate_specific_secret()`, `restart_specific_service()`… — never `run_as_root(cmd)`).
  - Approval tokens: single-use, short expiry (e.g. 5 min), bound to exact action + target + params, cryptographically verifiable, logged.
  - Rate limits + replay protection.
- [ ] Approval channel is **out-of-band**: Telegram button / push prompt on a different device. Never in the agent's own chat; a plain "YES" is insufficient.
- [ ] Approval cards show the **exact** action and parameters (amount, recipient, record, command) with approve/deny.
- [ ] **Credential placement:**
  - Level 4 (Cloudflare admin, OVH, R2 admin): **off the VPS entirely.** You run OpenTofu from your laptop for these. Do not skip this.
  - Level 3 credentials: only inside the broker, never in agent contexts/env vars/agent-readable files.
  - If you genuinely want delegated L3/4 automation, run that broker part on separate infrastructure.
- [ ] Audit log: request ID, timestamp, profile, action, target, args, human identity, decision, executor, result — shipped off-box, append-only where possible.
- [ ] Wire Hermes so privileged actions route: request → broker → out-of-band human approval → signed token → narrow executor → audit.
- [ ] Keep Hermes' own built-in approvals enabled as an additional layer — but Hermes is never the final authority.

**Gate 3.5:** a prompt-injection test inside a profile **cannot** reach Level 3/4 credentials and cannot complete a privileged action without an out-of-band human approval. Approvals expire and are single-use (verify replay fails). L3/4 approvals kept rare by design.

---

## Phase 4 — Full Hermes capability

- [ ] Remaining profiles (personal, automation, high-risk) configured in Hermes, mapped to their Linux users.
- [ ] Verify Hermes built-in controls, and **verify each claim against current Hermes docs** (spec §79):
  - [ ] Bot Screen (behaviour, session storage location, cleanup)
  - [ ] Built-in approvals (coverage, bypassability)
  - [ ] SSRF protection (defaults, coverage)
  - [ ] Tool gateway / MCP credential filtering
  - [ ] Website blocklist enforcement layer
  - [ ] Messaging DM pairing

  If any claim is wrong, compensate at the network/host layer — never inside Hermes.
- [ ] Bot Screen via Xvnc + Xfce, bound to localhost only, per-profile sessions; idle shutdown enabled.
- [ ] Browser session hygiene policy applied: prefer scoped OAuth/API tokens/dedicated accounts; if a sensitive login is unavoidable → operate, log out, clear cookies, terminate session, destroy temp creds.
- [ ] Messaging: explicit allowlists per platform; unknown sender → deny/pairing.
- [ ] Email: dedicated `agent@domain` mailbox only; approved senders; approval required for sensitive outgoing mail.
- [ ] Website blocklist: internal dashboards, cloud admin pages, secret-management UIs, private infra.
- [ ] Scheduled tasks: every job has max runtime/frequency/tool calls/tokens, allowed tools/domains/credentials, cost budget, output limits, failure handling, kill switch, external heartbeat.
- [ ] Model routing: cheap tier for routine work, strong tier for high-risk reasoning/privileged prep; log tokens per task.
- [ ] **MCP/skill vetting:** run the full checklist (ARCHITECTURE §15) for every MCP server and skill **before** adding; anything failing the trust rule runs in high-risk or not at all; re-review on version bumps.

**Gate 4:** all Hermes surfaces reachable only through Cloudflare Access → OAuth; allowlists enforced; every scheduled job externally monitored; no unvetted MCP/skill present.

---

## Phase 5 — Cloudflare & origin validation

- [ ] Cloudflare Tunnel via `cloudflared` (outbound-only tunnel; no inbound ports — dashboard and the SSH Access hostname both ride it).
- [ ] Cloudflare Access in front of the dashboard: passkey/FIDO2, **short session lifetime**; separate stricter Access policy for admin/approval routes.
- [ ] **Origin validates `Cf-Access-Jwt-Assertion`**: signature, issuer, audience, expiry, claims. Never trust the tunnel or the browser cookie alone.
- [ ] Rate limiting + logging on Cloudflare.
- [ ] The dashboard and SSH-over-Access hostnames are the only public surfaces; everything else admin-plane only.

**Gate 5:** direct request to origin bypassing Cloudflare is rejected (JWT missing/invalid); Access session expires quickly; approval routes require the stricter policy.

---

## Phase 6 — Backup hardening

- [ ] Credential separation confirmed (see table): writer on VPS (write-only), admin/prune on trusted machine, recovery offline, Cloudflare admin **off-VPS**.
- [ ] R2: retention policy + **bucket lock** so recent backups cannot be deleted/overwritten even with the writer (or stolen) credential; lifecycle rules checked against recovery retention.
- [ ] Schedule `restic check` + regular `--read-data-subset`; failure alerts a human (external, not on-box).
- [ ] Add **secondary backup**: different provider, different credentials, append-only if possible.
- [ ] Confirm exclusions: browser profiles, cookies never in backups.
- [ ] OVH snapshot before every major upgrade (snapshot = fast rollback; Restic = durable DR; neither replaces the other).

**Gate 6:** simulate losing the VPS R2 writer credential → prune still impossible with stolen writer credential (bucket lock holds); restore from the secondary copy succeeds.

---

## Phase 7 — Observability

- [ ] Healthchecks.io checks: backup heartbeat, VPS availability, critical scheduled jobs, cert expiry, key service heartbeats. (Monitoring must be independent of the VPS.)
- [ ] Alert rules: canary token use, blocked-egress spikes, new listening ports, broker approvals outside normal hours, spend threshold breaches, repeated service restarts (+ systemd `StartLimit`).
- [ ] auditd rules: sudo, new listening ports, changes to `/etc/systemd`, firewall, SSH config.
- [ ] Off-box audit log shipping (redacted — never ship raw secrets) for: auth, sudo, privileged requests/decisions, broker logs, backup events, Cloudflare events, significant agent activity.
- [ ] Canary tokens: fake API keys / decoy files in agent-reachable locations; any use alerts. Canaries must not themselves become secrets/attack paths.
- [ ] Publish the data map (what stored / where / how long / who reads) and per-class retention (conversations, browser data, downloads, agent logs, security logs, audit logs, backups).

**Gate 7:** kill the backup job deliberately → external alert fires within its grace period; touch a canary → alert fires; a denied egress spike produces an alert.

---

## Phase 8 — Adversarial testing, rebuild, and steady state

### 8.1 Adversarial tests
- [ ] **Prompt-injection → egress exfiltration:** plant malicious instructions in content the research profile ingests; verify the exfiltration attempt is blocked and logged.
- [ ] **Broker bypass:** attempt to trigger a Level 3/4 action from an injected context; verify it cannot succeed without out-of-band human approval.
- [ ] Malicious-skill simulation in a sandbox: verify blast radius is contained to the profile.

### 8.2 Scheduled rebuild (= DR test, quarterly)
1. Create temporary VPS.
2. Bootstrap entirely from cloud-init + OpenTofu + Ansible.
3. Restore from backups (using only offline kit material).
4. Verify platform usable **without undocumented manual steps**.
5. Destroy temp VPS.
- Measure actual RPO (target ≤24h, ideally <6h) and RTO (target 4h, then 1–2h) from this test; adjust.

### 8.3 Steady-state operations
- [ ] Quarterly: break-glass test (Phase 1) + rebuild test (8.2).
- [ ] Twice yearly: recovery kit review; backup retention/privacy review.
- [ ] On every significant change: one-page security review checklist (ARCHITECTURE §16 — boundary, threat, trust rule, credentials, worst case, recovery, egress, cost, monitoring, rollback, testing, docs).
- [ ] Threat-model re-review triggers: new MCP/skill/messaging platform/browser capability/privileged op/credential/public endpoint, or major Hermes/OS update.
- [ ] Update workflow for changes: backup + OVH snapshot → staging → test → production → health check → confirm. Renovate/Dependabot proposals applied through that path.
- [ ] Log every architectural decision in the decisions log (DECISION/REASON/ALTERNATIVES/SECURITY IMPACT/COST IMPACT/ROLLBACK).
- [ ] Run the full Definition of Done checklist (ARCHITECTURE + spec §76) and keep it checked.

**Gate 8 (final):** injection tests blocked, rebuild test passed with no undocumented steps, RPO/RTO measured and recorded, DoD checklist complete.

---

## Cost expectations

| Item | Cost |
|---|---|
| OVH VPS (4 GB) | ~£5/mo |
| Upgrade path (8 GB) | ~£8–£10/mo |
| Domain | ~annual |
| R2 storage + operations | usage-based, small |
| Model/API usage | capped per Phase 2 |
| Healthchecks.io | free tier |
| Secondary backup | usage-based, small |

Do not add expensive infrastructure without measurable benefit; do not introduce Kubernetes.

## Non-negotiables (violating any of these = stop and fix first)

1. Level 4 credentials never live on the VPS — not even in the broker.
2. Browser profiles/cookies never in backups.
3. Level 3/4 credentials never enter any agent context — broker only.
4. No agent self-approval for privileged actions; out-of-band human approval always.
5. Egress default-deny; every profile matches the trust table.
6. Recovery material escrowed offline before any agent runs.
7. A restore must be proven before anything depends on backups.
8. Monitoring independent of the VPS.
9. Break-glass exists and is tested quarterly.
10. No unreviewed MCP or skill.
