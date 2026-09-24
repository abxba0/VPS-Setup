# AGENTS.md

Ground rules for any AI agent (Kilo CLI or otherwise) working in this repository.

## What this repo is

Documentation and IaC for a Hermes Agent secure VPS platform: a self-hosted personal AI-agent platform on a small OVH VPS (~£5/mo, 4 GB, Ubuntu LTS), built to be secure, recoverable, and cheap. The VPS is **disposable** — identity, secrets, data, infrastructure definition, and recovery capability must survive its loss. The golden rule governs every decision here: *never rely on an AI agent to enforce a security boundary that the AI agent itself has the power to bypass.* See `README.md` and `docs/PLAN.md`.

## Repo layout

| Path | Role |
|---|---|
| `docs/` | Authoritative docs: `CONTEXT_HYBRID` (source of truth), `ARCHITECTURE.md`, `PLAN.md`, `SETUP-TRACKER.md`, and `phases/PHASE-*.md` per-phase guides. |
| `cloud-init/` | Phase 0 bootstrap user-data for the OVH install panel. |
| `scripts/` | Operational scripts (`setup-nftables.sh`, backup/restore, systemd units) + `scripts/README.md` runbook. |
| `ansible/` | OS hardening, Hermes install, sandboxing, firewall — **planned, not yet built** (`.gitkeep` placeholder). |
| `tofu/` | OpenTofu — **planned, not yet built** (`.gitkeep`); runs from the laptop ONLY, L4 creds never on the VPS. |

## Working rules for agents

- **Read before proposing.** `docs/PLAN.md` (order of work), `docs/ARCHITECTURE.md` (architecture source of truth), `docs/SETUP-TRACKER.md` (live progress). Don't propose anything until you've read all three.
- **Phases are gated and ordered.** Never suggest skipping ahead; never weaken a gate to make a step pass; never relax phase ordering.
- **Never write secrets into this repo.** No tokens, recovery codes, sensitive IPs, keys, or production `.env` — ever. Gitleaks pre-commit is enforced and must stay that way. The offline recovery kit stays offline; it never enters Git.
- **Conventions:** test servers listen on port **8330** and are killed after each session; repos live in `~/repo/`; GitHub user is `abxba0`; repos are **private**; target OS is Ubuntu LTS; VPS class is 4 GB.
- **The founder executes all setup personally to learn.** Agents prepare, explain, and verify — they do not take over hands-on provisioning.
- **Changing scripts:** keep the timed-flush rollback pattern and the `apply` / `confirm` / `rollback` interface intact. Update `docs/SETUP-TRACKER.md` READY notes and the relevant `docs/phases/PHASE-*.md` in the same change.
- **Security review:** any significant change gets the one-page checklist in `ARCHITECTURE.md` §16 (boundary, threat, trust rule, credentials, worst case, recovery, egress, cost, monitoring, rollback, testing, docs).
- **Non-negotiables** (from `docs/PLAN.md`; violating any = stop and fix first):
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

**When uncertain — stop and ask the founder.** Do not improvise around security boundaries.
