# VPS-Setup — Hermes Agent Secure VPS Platform

Documentation and IaC for the secure, recoverable, low-cost Hermes Agent platform on a small OVH VPS.

## Documents

| File | Role |
|---|---|
| `CONTEXT_HYBRID` | **Source of truth** — full v0.3 architecture spec (merged v0.1/v0.2/v0.3). Where any doc disagrees, this wins. |
| `ARCHITECTURE.md` | Condensed, implementation-facing architecture reference (boundaries, threat model, profiles, broker, backups, golden rules). |
| `PLAN.md` | Phased setup guide (Phase 0 → Phase 8) with per-phase gates and the non-negotiables. Work top-to-bottom; each gate must pass before the next phase. |

## Setup status

Phase 0 prerequisites — see `PLAN.md` §0.1:

- [x] Git repo (`VPS-Setup`, private: github.com/abxba0/VPS-Setup)
- [x] Gitleaks installed (v8.24.3) + pre-commit hook (`.git/hooks/pre-commit`, `gitleaks protect --staged`)
- [x] History scanned clean; hook verified blocking a planted AWS key (Gate 0a)
- [ ] OVH / Cloudflare / Tailscale / Infisical / Healthchecks.io accounts with passkey/FIDO2
- [ ] Two FIDO2 hardware keys (one stored offline)

## Planned IaC layout (as implementation starts)

```text
VPS-Setup/
  CONTEXT_HYBRID          # source-of-truth spec
  ARCHITECTURE.md         # condensed architecture
  PLAN.md                 # phased setup guide
  cloud-init/             # Phase 0 bootstrap user-data
  tofu/                   # OpenTofu (run from laptop ONLY — L4 creds never on VPS)
  ansible/                # OS hardening, Hermes install, sandboxing, firewall
  scripts/                # nftables setup, backup/restore, egress verifier
  docs/decisions-log.md   # DECISION/REASON/ALTERNATIVES/IMPACT/ROLLBACK entries
```

## Hard rules for this repo

- No secrets, tokens, recovery codes, private keys, or production `.env` — ever (enforced by Gitleaks pre-commit; overrides only via `--no-verify`, followed by a full scan).
- Recovery-kit material stays **offline** (encrypted + printed); it never enters this repo.
- Level 4 credentials (Cloudflare admin, OVH, R2 admin) live off the VPS and are used via OpenTofu from a trusted machine — never stored here.
