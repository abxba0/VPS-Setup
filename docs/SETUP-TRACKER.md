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

### 0.3 Firewall (in/out default-deny, timed-flush) — ☐ TODO

### 0.4 Research profile + egress limits — ☐ TODO

### 0.5 First backup + tested restore — ☐ TODO

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
