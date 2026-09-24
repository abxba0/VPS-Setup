# Phase 2 — Recovery escrow and cost caps

> Companion to `docs/PLAN.md` §Phase 2. Authoritative source: `docs/ARCHITECTURE.md` (§7 recovery, §11 API segmentation, §4 threat model). Track your progress in `docs/SETUP-TRACKER.md`. Do not start the next phase until Gate 2 passes.

## Your goal

A physical, encrypted, **offline-verified** recovery kit exists in two locations and can restore the platform *without the VPS, without Infisical, without Cloudflare*; and every agent-bound credential lives in Infisical behind per-profile machine credentials with provider-side spend caps and alerts.

## Non-negotiables this phase enforces

- **#6 — Recovery material escrowed offline before any agent runs** — this phase is where it is *satisfied* (Phase 0's research agent was credential-free; the moment any profile gains a credential, private data, or an L2+ capability, this gate must already be passed).
- **#7 — A restore is proven before anything depends on backups** (the kit drill is the second full restore proof).
- Golden rule 27: every key/profile has a spend cap; the API-segmentation rule (ARCHITECTURE §11: separate keys per profile, never one master key).

**Hard ordering constraints:**

- No profile receives a model-provider key or any private data until the offline kit is verified decodable with zero network access. Verification means: airplane-mode laptop, decrypt the encrypted kit, read the printed copy from location #2.
- No shared "VPS machine credential" in Infisical, ever — one per profile, per environment. If you're tempted to create `vps-all-access`, you're building the credential thief's (threat **G**) master key.
- Spend caps and alerts wired **before** the first key is used, not after the first bill.

## Why this phase matters

Phase 2 converts "recovery is possible" into "recovery is possible **without the VPS, without Infisical, without Cloudflare**" — breaking the circular dependency (ARCHITECTURE §7) that otherwise guarantees you can never recover from the exact incident that took those systems down (threats **J**, **I**, and the recovery half of **K**). The same phase builds the credential *segmentation* layer: per-profile machine credentials in Infisical mean a compromise of one profile's runtime (threats **F**, **D**) yields only that profile's secrets, and provider-side spend caps turn threat **L** (runaway cost) from "unbounded bill" into "bounded alert."

## Before you start

- Gate 1 has passed: break-glass rehearsed and dated, both hardware keys proven on every provider, recovery codes for each account already collected into the kit envelope during Phase 1 step 1.
- The restic repo password is already in your password manager (Phase 0.5 stopgap); the R2 writer credential is on the VPS in `/etc/restic-backup.env`; the R2 recovery/prune credentials have never touched the VPS.
- A laptop (or VM) that can go fully offline for the verification drill, plus one trusted second physical location for the printed copy.

## Credential map

| Credential | Level | Lives where | Must NEVER live |
|---|---|---|---|
| Offline kit (encrypted) — Restic pw, R2 recovery, prune cred, OVH/CF/TS/IdP/Infisical recovery | L4 | Password manager **and** printed, two physical locations | VPS, Git, any cloud drive in plaintext |
| R2 prune/admin credential | L4 | Laptop / offline kit only | VPS at any path, any agent context |
| Infisical machine identity tokens (one per profile: research now; personal/automation/highrisk later, plus `backup`) | L3 | Infisical; token injected into that profile's systemd unit only | Git, other profiles' units, `/etc/environment`, shell rc files |
| Model-provider API keys (per profile, per provider) | L2–L3 | Infisical, scoped to profile; provider-side cap set | VPS files, agent chat, browser profiles |
| Spend caps / budget alerts | — | Provider dashboards + calendar reminders | Only in a spreadsheet nobody checks |

## Steps

### 2.1 — Offline recovery kit

1. **Assemble the kit contents** (per PLAN §2.1): OVH recovery info, Tailscale recovery info, IdP recovery codes + hardware-key backup note, Infisical admin/recovery credentials, **restic repository password**, **R2 restore-capable credential**, **R2 prune/admin credential** (stays off-VPS permanently), Cloudflare + OVH account recovery details, domain/DNS recovery, emergency contacts, architecture diagram pointer, recovery procedure, latest known-good config commit hash.
2. **Format:** an encrypted archive whose passphrase you can *also* derive without any of the compromised systems, **plus a printed copy** of the critical secrets (restic password, recovery credentials, recovery codes) — paper survives everything digital:

   ```bash
   # on the laptop, in a scratch dir OUTSIDE the Git repo
   age -r <your-public-key> -o kit.enc kit/          # or: gpg -e -r <you> -o kit.tar.gpg kit.tar
   sha256sum kit.enc > kit.enc.sha256                # checksum line goes in BOTH copies
   ```

   Keep the passphrase-derivation method itself in the kit (if you need a hint to remember the passphrase, the hint is part of the kit).
3. **Store in two separate physical locations** (e.g. home safe + trusted person / bank box). Neither location may be "inside the VPS", "in the browser", or "in the cloud only".
4. **Offline verification drill (the gate).** On a machine with **no** access to the VPS, signed out of Infisical and Cloudflare, confirm you can open the encrypted kit, read the restic password, and — using the R2 recovery credential — run a real restore:

   ```bash
   nmcli networking off        # or physically disconnect — airplane-mode laptop
   gpg --decrypt kit.tar.gpg | tar -tv       # or: age -d kit.enc | tar -tv
   # Read the printed copy at location #2 and confirm it matches (checksum line in both copies).

   export RESTIC_REPOSITORY="s3:https://<ACCOUNTID>.r2.cloudflarestorage.com/<bucket>"
   export RESTIC_PASSWORD="..."                          # from the kit
   export AWS_ACCESS_KEY_ID="<r2-recovery-cred-id>"      # restore-capable credential from the kit
   export AWS_SECRET_ACCESS_KEY="..."
   restic snapshots
   restic restore latest --target /tmp/kit-verify
   diff -qr /srv/hermes/research /tmp/kit-verify/srv/hermes/research && echo RESTORE_VERIFIED
   nmcli networking on
   ```

   This is the second full restore proof (Gate 0 was the first). Date it in the ops log.
5. **Calendar reminder, twice yearly:** kit review (contents current? commit hash updated? credentials rotated? printed copy legible?).

### 2.2 — Infisical per-profile machine identities

6. Create project `hermes`, environments **dev** and **prod**. Never copy prod values into dev.
7. Create **machine identities** — one per profile (`research`, later `personal`, `automation`, `highrisk`, plus `backup`) — each scoped to only its own secrets. Record the client secrets into the systemd unit env or `infisical secrets run` wrapper of the corresponding service. **Never one shared machine credential per box.**
8. Migrate the model-provider keys into per-profile folders: `research/llm-api-key`, etc. Update `restic-backup.env`-style local files only where the service cannot reach Infisical (backup env stays as the reviewed exception, root-0600).
9. **Verify scoping from the VPS** — positive and negative, per identity:

   ```bash
   # as the research service identity: can read its key, cannot read personal/automation scopes
   infisical secrets get research/llm-api-key --env prod        # works
   infisical secrets get personal/llm-api-key --env prod        # must FAIL

   # From a profile context (the real boundary):
   sudo -u hermes-research env INFISICAL_TOKEN="st_research_…" \
     infisical secrets get RESEARCH_MODEL_KEY --env prod --silent ; echo "rc=$?"     # rc=0
   sudo -u hermes-research env INFISICAL_TOKEN="st_research_…" \
     infisical secrets get PERSONAL_MODEL_KEY --env prod --silent ; echo "rc=$?"     # expect rc!=0
   ```

   The negative test is the one that proves segmentation — a green positive test with a shared token proves nothing.

### 2.3 — Spend caps

10. For every API key: set the provider-side hard monthly cap where supported (OpenAI/Anthropic/Google all support spend or rate limits — use **both**: monthly cap + rate ceiling). Where provider-side caps don't exist, record the key in Infisical with a `spend-cap-manual: <amount>` note and rely on the Phase 7 alert at usage thresholds.
11. Per-profile budget table in the ops log; alert levels **50% / 80%** (notification), auto-disable at 100% (disable key or drop to zero-quota key). Route alerts to a channel/device you actually see (phone push / Telegram) — never an inbox nobody reads. Test one alert by lowering a cap temporarily.
12. Tag every key with its profile in the provider console naming: `hermes-research-llm-prod`. **Separate keys per profile — never a master key.** Development/testing keys are separate again, lower cap.
13. Document each provider's privacy posture (training on/off, retention, ZDR availability, region) in a `docs/llm-privacy.md` table; enable the strictest settings now (ZDR / no-training) and re-check on terms changes.

## Adversarial verification (run these attacks)

### A2-1 · Recovery kit independence drill

On a laptop/VM with **no VPN, no Tailscale, no Infisical login, no Cloudflare session**:

1. Open the encrypted kit using only the passphrase you hold.
2. From it, extract: restic repo password + recovery credential → run `restic snapshots` against R2.
3. Extract IdP recovery codes and verify one is accepted.
4. Extract the R2 restore credential and attempt a read (`aws s3 ls s3://<bucket> --profile recovery`).

- **PASS:** every step succeeds offline; nothing needed a live dashboard session.
- **FAIL:** any item missing, any passphrase wrong, or the printed copy in location #2 disagrees with the digital copy.

### A2-2 · Infisical scoping negative tests

For each profile machine credential:

```bash
# Run the agent-bound client with ONLY hermes-research's machine credentials, then attempt:
infisical secrets --env prod --projectId <personal-project-or-scope>   # or equivalent API call
```

- **PASS:** authorization denied for other profiles' scopes; the research machine credential can read only its own environment/scope.
- **FAIL:** one machine credential can read multiple profiles — that's the "one shared credential per box" anti-pattern the phase forbids.

### A2-3 · Spend cap live-fire (or tabletop)

Lower one API key's provider-side cap to a trivially small number (or simulate the 50%/80% threshold crossings with a test spend), and confirm: the 50% and 80% alerts actually reach you (email/push), and the 100% path disables the key.

- **PASS:** alerts arrive on a channel you read within minutes; disable verified on a scratch key.
- **FAIL:** cap set only "in your head"/spreadsheet — provider-side cap missing; or alerts route to a mailbox the VPS itself reads (unreliable channel).

### A2-4 · Escrow leak check

Run gitleaks + manual grep across the IaC repo for any escrow content (repo password, recovery codes, R2 keys):

```bash
gitleaks detect --source . --redact -v
git log --all -p | grep -iE 'RESTIC_PASSWORD|recovery|BEGIN.*PRIVATE'
```

- **PASS:** nothing; the kit exists only offline.
- **FAIL:** anything.

## Pitfalls

1. **Escrow stored only in the password manager.** The kit must be decryptable when the IdP behind the password manager is what you lost. Printed copy, second location, checked twice a year.
2. **Escrow verified only by "it opens on my machine with everything running."** Verification is *offline, degraded-mode* decryption. If it needs Tailscale, DNS, or the VPS, it fails the gate.
3. **One Infisical service token for the whole VPS** because per-profile tokens are tedious. This recreates the single point of theft and defeats profile segmentation for the price of one token.
4. **Caps set but alerts pointing at an inbox nobody reads.** Route 50%/80% alerts to a channel/device you actually see, and test one alert by lowering a cap temporarily (A2-3).
5. **Provider privacy defaults left on** (training/retention). Document each provider's policy per ARCHITECTURE §11 *now*; "review later" always means "review after a leak."
6. **Kit rots:** the most common real failure is a kit that was correct 8 months ago. The commit-hash field and the biannual review exist for this; the Healthchecks `kit-review` check makes staleness *alert*, not merely intend.
7. **Encrypted kit + passphrase both "somewhere safe" but not derivable** — test the passphrase derivation *cold* during the drill. If you need a hint to remember it, the hint is part of the kit.
8. **Printed copy missing a newly rotated credential** — rule: rotate a credential ⇒ update both physical copies *that day* (kit-review checklist item).
9. **Infisical outage mid-operation:** services fail to start if they inject secrets at boot. Acceptable (fail-closed), but the runbook note is: recovery path = Infisical web + passkey, or the kit's Infisical recovery credentials.

## Gate 2 — honest pass checklist

Per `docs/PLAN.md` Gate 2 — all must pass:

- [ ] Recovery kit verified offline (A2-1: airplane-mode decrypt, printed copy cross-checked, restore from R2 with kit-only material — VPS unused, ops log dated).
- [ ] Every agent-bound credential in Infisical behind a **per-profile machine credential** (A2-2 negative test passes for every mismatched identity).
- [ ] All API keys capped: provider-side hard monthly cap (+ rate ceiling where supported); 50%/80% alerts wired to a channel you read; 100% auto-disable (A2-3 verified on a scratch key).
- [ ] Each key tagged with its profile (`hermes-research-llm-prod`); no master key.
- [ ] `docs/llm-privacy.md` written; strictest provider settings (ZDR/no-training) enabled.
- [ ] Calendar reminder set: kit review twice a year.

Fake passes to reject (from the panel review):

- *"I saved a zip with the passwords."* Unverified escrow is indistinguishable from no escrow; the gate is an *airplane-mode* decrypt using location #2's printed copy plus the encrypted copy — not "it opens on my machine with everything running."
- *"Infisical works."* Tested with a single shared token it always does; the gate demands the **negative** test (profile A's token denied profile B's scope) to actually prove segmentation.
- *"Caps are set."* A cap with alerts pointing at an unread inbox, or a cap that exists only in a spreadsheet/your head, is not a control — A2-3's live-fire (or tabletop) must show alerts arriving and auto-disable firing.

Evidence to record in `docs/SETUP-TRACKER.md` and the ops log:

- Kit drill date + `RESTORE_VERIFIED` output; checksum match between both kit copies.
- For each Infisical machine identity: the positive (rc=0) and negative (rc≠0) test transcript.
- For each API key: cap value, 50%/80% alert recipients, 100% auto-disable toggle (screenshot or recorded in the ops log).

## Learner's corner

**What you'll learn in this phase**

- The circular-dependency problem in recovery design and the escrow pattern that breaks it.
- Threat modeling for credentials: separating writer/admin/recovery identities so one theft ≠ total loss.
- Secret-scope segmentation: per-profile machine identities instead of one god credential.
- Spend caps as a *security* control (runaway agent = threat L), not just a budgeting nicety.

**Concept primer.** Recovery has a bootstrapping problem: restoring the VPS requires Infisical, Infisical access may require the IdP, the IdP may require email, and email may live on the VPS's own domain — a dependency loop where the thing you're recovering is part of its own recovery path. The escrow breaks the loop by holding every root dependency *offline*, verified against the rule "can I do this with the VPS dark?" Credential separation applies the same logic to theft: if the writer credential (append-only) is stolen, the attacker can *add* garbage but not delete history; the admin/prune credential is the crown jewel and lives off-VPS; the recovery credential exists to *read*, which is what disaster recovery needs. Cost caps are in this phase because threat L (runaway loop) is more probable than most "hackers": a scheduled task that loops on model calls can burn real money before any human notices — a hard provider-side cap is the only control that works when the thing looping is also the thing you'd use to notice.

**Check-your-understanding**

1. Why must the escrow kit be verifiable *without* the VPS *and* without Infisical — name the failure each condition rules out?
   *Answer: without the VPS rules out "recovery depends on the thing that died" (threat H/J); without Infisical rules out the loop where the secret manager holding recovery secrets is itself locked out (its own outage or your lost access). The kit must survive any single system being unavailable.*
2. Why is a per-profile machine credential strictly better than one shared machine credential, even if the shared one has fewer total permissions?
   *Answer: blast radius and attribution. With one credential, a compromise of any profile compromises all secrets and you can't tell which profile leaked (audit shows only "the box"). With per-profile creds, a research-profile compromise cannot touch personal/automation scopes, and the audit log names the compromised scope directly.*
3. Your research profile has *no* private data (trust rule). Why does it still get its own capped API key?
   *Answer: threat L doesn't care about data sensitivity — a looping research task burns the same money. Per-profile caps also localize the blast radius and give you per-profile cost telemetry, which is your cheapest anomaly detector for runaway agents.*

**DIY habit.** Before sealing the kit, do a "cold restore" tabletop: pretend it is 03:00 and the VPS is wiped. On paper, write the exact ordered steps from kit-material to working platform, marking each step with the kit item it consumes. Any step with no kit item behind it is a gap — fix the kit, not the plan.

## Steady state added by this phase

| Cadence | Task | Wiring |
|---|---|---|
| Twice yearly | Kit review + second-location audit | Calendar + Healthchecks check `recovery-kit-review` (period 180 d / grace 14 d, manual ping) |
| On every credential rotation | Update kit both locations | Change checklist item |
| Monthly (5 min) | Skim provider spend dashboards vs. caps | Calendar; automated alerts at 50/80% per Phase 7 |

Zero on-box impact (Infisical used as cloud SaaS per plan; a self-hosted Infisical would add a DB + service ~300–500 MB — if you ever self-host it, that is an explicit 4 GB budget decision to re-run).
