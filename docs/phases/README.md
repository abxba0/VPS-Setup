# Phase Guides

These docs expand each phase of `docs/PLAN.md` into a step-by-step guide produced by a 3-expert panel (Security Architect / SRE / Red-Team+Mentor). The founder executes every step personally; gates must pass, in order, before the next phase begins.

## Index

| Phase | File | Gate | One-line purpose | Key rule |
|---|---|---|---|---|
| 0 — Minimum viable tier | [PHASE-0.md](PHASE-0.md) | Gate 0: identity-gated SSH (Tailscale + Cloudflare Access; direct-IP SSH denied), default-deny both directions, sandboxed non-root Hermes, laptop-side restore proven | Safe working baseline you can already restore | A backup is not a backup until a restore has succeeded. |
| 1 — Break-glass & identity hardening | [PHASE-1.md](PHASE-1.md) | Gate 1: machine reachable without Tailscale; every account enterable without the primary device | Prove emergency access exists before anything depends on it | Untested break-glass is no break-glass — test it end-to-end. |
| 2 — Recovery escrow & spend caps | [PHASE-2.md](PHASE-2.md) | Gate 2: recovery kit verified offline; per-profile machine creds; all keys capped with alerts | Offline recovery kit + Infisical + cost caps, before any agent runs | Recovery can't depend on the systems being recovered. |
| 3 — Isolation baseline | [PHASE-3.md](PHASE-3.md) | Gate 3: cross-profile reads, private-network touches, non-allowlisted egress all fail and log | Linux users, containers, systemd sandboxing, per-profile egress | No profile combines private data + untrusted content + outbound. |
| 3.5 — Approval broker | [PHASE-3.5.md](PHASE-3.5.md) | Gate 3.5: injected profile cannot reach L3/4 creds or complete a privileged action without out-of-band approval | Human-in-the-loop broker before any Level 2+ capability | A "YES" in chat is not an approval. |
| 4 — Full Hermes capability | [PHASE-4.md](PHASE-4.md) | Gate 4: all surfaces behind Cloudflare Access; allowlists enforced; every job externally monitored; no unvetted MCP/skill | All profiles, Bot Screen, messaging, email, scheduled jobs, MCP vetting | Verify Hermes' claims against current docs; compensate at the host/network layer, never inside Hermes. |
| 5 — Cloudflare & origin validation | [PHASE-5.md](PHASE-5.md) | Gate 5: direct-to-origin requests rejected on missing/invalid JWT; approval routes use stricter policy | Tunnel + Access + origin-side JWT validation | Never trust the tunnel — validate `Cf-Access-Jwt-Assertion` at the origin. |
| 6 — Backup hardening | [PHASE-6.md](PHASE-6.md) | Gate 6: stolen writer credential cannot prune/delete (bucket lock); secondary restore succeeds | Credential separation, bucket lock, secondary backup | A stolen writer credential must never destroy backups. |
| 7 — Observability | [PHASE-7.md](PHASE-7.md) | Gate 7: killed backup → external alert; canary touch → alert; egress spike → alert | Off-box monitoring, alerts, auditd, canaries, data map | On-box monitoring dies with the box. |
| 8 — Adversarial testing, rebuild, steady state | [PHASE-8.md](PHASE-8.md) | Gate 8: injection tests blocked; rebuild has zero undocumented steps; RPO/RTO recorded; DoD complete | Attack yourself, then prove the rebuild works | A rebuild with undocumented manual steps is a failed rebuild. |

## How to use these docs

1. Read **"Your goal"**.
2. Follow **"Steps"** in order — the founder executes; the doc explains and warns.
3. Run **"Adversarial verification"** — actively try to break what you just built.
4. Check **"Gate — honest pass checklist"** — every item must pass honestly, no partial credit.
5. Record the evidence in `docs/SETUP-TRACKER.md`.
6. Read **"Learner's corner"** after (or before) execution — it explains *why*, for the learning goal.

> **Warning — ordering is load-bearing.** Phase 0.4's research profile is legal before Phase 2 **only** because it holds no credentials and no private data. Each phase's ordering guarantee rests on the phases before it; never relax it, never skip ahead, never weaken a gate to make a step pass.
