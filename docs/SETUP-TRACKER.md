# Setup Tracker

Live progress against `docs/PLAN.md`. Updated by the user; gates must pass before advancing.

**Current phase: 0.1 — Accounts & prerequisites (in progress)**

---

## Phase 0 — Minimum viable tier

### 0.1 Accounts & prerequisites

| Item | Status | Notes |
|---|---|---|
| Git repo for IaC | **DONE** | `github.com/abxba0/VPS-Setup` (private) |
| Gitleaks pre-commit hook | **DONE** | v8.24.3, hook verified, history clean (Gate 0a partial) |
| OVH account | **DONE** | Created; 4 GB VPS **paid, awaiting provisioning** |
| OVH passkey/FIDO2 + TOTP backup + recovery email/phone | ☐ TODO | Verify all four are set |
| Two FIDO2 hardware keys (one offline) | ☐ TODO | Passkey on device OK for now; hardware keys before Phase 1 |
| Cloudflare account + domain | **DONE** | Subdomain created; MFA/passkey added |
| Tailscale account | **DONE** | Verify passkey/MFA enabled |
| Infisical account | **DONE** | MFA added |
| Healthchecks.io account | **DONE** | Created (free tier) |

### 0.2 Provision & bootstrap VPS — ☐ TODO (waiting on OVH provisioning)
> **READY:** `cloud-init/user-data.yaml` (bootstrap + interim firewall + DNS pin + sshd drop-in) is built and panel-reviewed. Replace the SSH key placeholder, paste into the OVH install panel, then follow `scripts/README.md`.

### 0.3 Firewall (in/out default-deny, timed-flush) — ☐ TODO
> **READY:** `scripts/setup-nftables.sh` (apply/confirm/rollback with 5-min timed-flush) built and panel-reviewed.

### 0.4 Research profile + egress limits — ☐ TODO

### 0.5 First backup + tested restore — ☐ TODO
> **READY:** `scripts/backup.sh`, `scripts/restore-test.sh`, `scripts/systemd/*`, `scripts/README.md` runbook built and panel-reviewed. Needs: R2 bucket + bucket-scoped token + Healthchecks.io check URL.

**Expert review:** 3-expert panel (security architect / SRE / red-team) + follow-up verification pass — all CRITICAL/HIGH findings fixed; verdict APPROVED after R1–R3 runbook/consistency fixes. Accepted interim risks (443-any, DoH bypass, DNS tunneling via resolvers, loopback) are documented in the DECISION block of `scripts/setup-nftables.sh`.

**Gate 0:** ☐ not reached

## Phases 1–8 — ☐ not started

1. Break-glass & identity hardening — ☐
2. Recovery escrow & spend caps — ☐
3. Isolation baseline — ☐
3.5 Approval broker — ☐
4. Full Hermes capability — ☐
5. Origin validation (CF Access JWT) — ☐
6. Backup hardening — ☐
7. Observability — ☐
8. Adversarial testing & rebuild — ☐

---

## Immediate next actions

1. **You:** confirm OVH has TOTP backup + verified recovery email/phone (passkey primary if the panel offers it); verify Tailscale passkey/MFA.
2. **You (deferred to Phase 1):** two FIDO2 hardware keys, one stored offline.
3. **Me:** scaffold `cloud-init/` user-data, `scripts/` (nftables + timed flush, backup/restore), ready to paste at OVH install time.
4. **You (when VPS activates):** provision with the cloud-init user-data via OVH panel → Gate 0a closes → Phase 0.2 begins.
