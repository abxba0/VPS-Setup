# Setup Tracker

Live progress against `docs/PLAN.md`. Updated by the user; gates must pass before advancing.

**Phase guides:** per-phase step-by-step docs live in `docs/phases/` (`PHASE-0.md` … `PHASE-8.md`) — follow them top-to-bottom; each has an adversarial-verification section and an honest gate checklist.

**Current phase: 0.2/0.3 — SSH access cutover (in progress)**

---

## Phase 0 — Minimum viable tier

### 0.1 Accounts & prerequisites

| Item | Status | Notes |
|---|---|---|
| Git repo for IaC | **DONE** | `github.com/abxba0/VPS-Setup` (private) |
| Gitleaks pre-commit hook | **DONE** | v8.24.3, hook verified, history clean (Gate 0a partial) |
| OVH account | **DONE** | Created; 4 GB VPS **provisioned and live** |
| OVH passkey/FIDO2 + TOTP backup + recovery email/phone | ☐ TODO | Verify all four are set |
| Two FIDO2 hardware keys (one offline) | ☐ TODO | Passkey on device OK for now; hardware keys before Phase 1 |
| Cloudflare account + domain | **DONE** | Subdomain created; MFA/passkey added |
| Tailscale account | **DONE** | Verify passkey/MFA enabled |
| Infisical account | **DONE** | MFA added |
| Healthchecks.io account | **DONE** | Created (free tier) |

### [0.2 Provision & bootstrap VPS](phases/PHASE-0.md) — ◐ IN PROGRESS (VPS live; Tailscale SSH + tunnel SSH cutover pending)
> **LIVE STATE:** VPS provisioned; Cloudflare Tunnel + Access SSH working; direct SSH by public IP still open. Founder decision 2026-09-26: exactly two identity-gated SSH paths (CF Access tunnel → localhost:22, Tailscale SSH). Cutover via `scripts/restrict-ssh.sh` (below); OVH KVM/rescue drill still owed (PHASE-0 step 6).

### [0.3 Firewall (in/out default-deny, timed-flush)](phases/PHASE-0.md) — ◐ IN PROGRESS (interim UFW + fail2ban live; reviewed nftables policy pending)
> **READY:** `scripts/setup-nftables.sh` (apply/confirm/rollback with 5-min timed-flush) built and panel-reviewed.
> **NOTE:** `scripts/hardenning.sh` was run on the box (UFW default-deny in/allow out + "allow 22/tcp" public, fail2ban sshd jail, 15-min Bash TMOUT). The UFW port-22 rule is superseded by `scripts/restrict-ssh.sh` (timed-flush apply/confirm/rollback/status) and later by the reviewed nftables policy, after which UFW is retired (`ufw disable` once `systemctl enable nftables` + reboot test pass). fail2ban may remain.

### [0.4 Research profile + egress limits](phases/PHASE-0.md) — ☐ TODO

### [0.5 First backup + tested restore](phases/PHASE-0.md) — ☐ TODO
> **READY:** `scripts/backup.sh`, `scripts/restore-test.sh`, `scripts/systemd/*`, `scripts/README.md` runbook built and panel-reviewed. Needs: R2 bucket + bucket-scoped token + Healthchecks.io check URL.

**Expert review:** 3-expert panel (security architect / SRE / red-team) + follow-up verification pass — all CRITICAL/HIGH findings fixed; verdict APPROVED after R1–R3 runbook/consistency fixes. Accepted interim risks (443-any, DoH bypass, DNS tunneling via resolvers, loopback) are documented in the DECISION block of `scripts/setup-nftables.sh`.

**Gate 0:** ☐ not reached

## Phases 1–8 — ☐ not started

1. Break-glass & identity hardening — ☐ → [PHASE-1.md](phases/PHASE-1.md)
2. Recovery escrow & spend caps — ☐ → [PHASE-2.md](phases/PHASE-2.md)
3. Isolation baseline — ☐ → [PHASE-3.md](phases/PHASE-3.md)
3.5 Approval broker — ☐ → [PHASE-3.5.md](phases/PHASE-3.5.md)
4. Full Hermes capability — ☐ → [PHASE-4.md](phases/PHASE-4.md)
5. Origin validation (CF Access JWT) — ☐ → [PHASE-5.md](phases/PHASE-5.md)
6. Backup hardening — ☐ → [PHASE-6.md](phases/PHASE-6.md)
7. Observability — ☐ → [PHASE-7.md](phases/PHASE-7.md)
8. Adversarial testing & rebuild — ☐ → [PHASE-8.md](phases/PHASE-8.md)

---

## Immediate next actions

1. **You:** confirm OVH has TOTP backup + verified recovery email/phone (passkey primary if the panel offers it); verify Tailscale passkey/MFA.
2. **You (deferred to Phase 1):** two FIDO2 hardware keys, one stored offline.
3. **You:** open BOTH approved SSH paths (Cloudflare Access session + Tailscale SSH after `scripts/tailscale-setup.sh`), then run `sudo bash scripts/restrict-ssh.sh apply` → verify direct-IP SSH is denied/logged (hotspot nmap + `ssh-guard-drop:` journal line) → `confirm` within 5 minutes (runbook: `scripts/README.md` Step 2.5).
4. **You:** migrate to the full reviewed nftables policy (`scripts/setup-nftables.sh` Step 3 flow incl. reboot test), then `sudo ufw disable`; record Gate 0b evidence in this tracker.
