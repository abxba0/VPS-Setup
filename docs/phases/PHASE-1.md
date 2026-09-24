# Phase 1 — Break-glass and identity hardening

> Companion to `docs/PLAN.md` §Phase 1. Authoritative source: `docs/ARCHITECTURE.md` (§6 access/identity, §7 recovery, §4 threat model). Track your progress in `docs/SETUP-TRACKER.md`. Do not start the next phase until Gate 1 passes.

## Your goal

You can get into the machine and into **every account** with no Tailscale, no primary device, and no Infisical — and this has been *physically demonstrated*, dated in the operations log, and scheduled to repeat quarterly.

## Non-negotiables this phase enforces

- **#9 — Break-glass exists and is tested quarterly** (ARCHITECTURE §6: OVH panel/KVM/rescue, two hardware keys, one offline, tested quarterly).
- **#8 — Monitoring independent of the VPS** — preconditioned here by keeping identity/monitoring accounts (OVH, Cloudflare, Tailscale, Infisical, Healthchecks.io) independent of the VPS.
- Golden rule 28: break-glass exists and is tested.

**Hard ordering constraint:** the quarterly rebuild test (Phase 8.2) may not run before the break-glass path has been executed at least once. A rebuild test that fails mid-way *is* the emergency, and the emergency procedure must already be muscle memory. Also: no new admin-plane surface (widening Tailscale grants, adding a second tailnet admin) until the documented exception for `tag:hermes-vps` key expiry (ARCHITECTURE §6) is written into the ops log — it's a deliberate risk record, not a default.

## Why this phase matters

Every protection you've built routes through accounts: OVH (console/KVM/rescue), Tailscale (admin plane), Cloudflare (Access), Infisical (secrets). If a single provider lockout (threat **J**) or device loss (**I**) also locks you out of *recovery* for that provider, the circular dependency in ARCHITECTURE §7 becomes real: you can't restore what you can't authenticate to. Phase 1 closes that by making two independent paths into every system: passkeys/FIDO2 on a primary device *and* a hardware key stored offline, plus a break-glass path (OVH console + KVM) that never touches Tailscale. It also hardens against **F**/**G**: short session lifetimes, check mode for sensitive SSH, and least-privilege tailnet grants mean a stolen laptop session has small reach.

## Before you start

- Gate 0 has passed: SSH is Tailscale-only, the firewall is default-deny both directions with the timed-flush rollback proven, and the laptop-side restore (Gate 0 DR test) succeeded. The rescue/KVM drill from Phase 0.2 (`scripts/README.md` step 1) was already done once while healthy — this phase formalizes and repeats it.
- Both FIDO2 hardware keys are physically in hand. Key #1 (primary): on your person / daily device. Key #2 (break-glass): goes into physical offline storage this phase.
- The Phase 0.2 rescue-mode rehearsal date is in the ops log (it counts as rehearsal #1; today's drill is the first *formal, timed* one).
- A second SSH session open on the VPS as a lifeline during any identity work.

## Credential map

| Credential | Level | Lives where | Must NEVER live |
|---|---|---|---|
| FIDO2 hardware key #1 (primary) | L3 | On your person / daily device | Left plugged in on the VPS or desk |
| FIDO2 hardware key #2 (break-glass) | L3 | Physically offline, separate location | Same bag/building as key #1 or any cloud sync |
| TOTP backup seeds (per provider) | L3 | Password manager + offline kit | VPS, Git, phone screenshots |
| Recovery codes (per account) | L3 | Generated into the Phase 2 kit envelope as you go | Browser downloads, VPS, Git |
| OVH rescue-mode credentials / KVM path | L4 | Documented procedure in offline kit | VPS files |
| Tailscale grants/ACLs | L3 | Tailnet admin (OpenTofu from laptop) | Agent-reachable config on VPS |

## Steps

Commands run on the VPS unless noted. `<...>` placeholders are values for your password manager, never Git.

### 1. Register both hardware keys everywhere

Register **both** FIDO2 keys on OVH (primary + backup), and on every account in this list: OVH, Cloudflare, Tailscale, Infisical, Healthchecks.io. A key registered to zero providers is a paperweight.

Where a product only offers TOTP as second factor, accept TOTP **in addition** but ensure at least passkey or FIDO2 is available as primary. TOTP as the *primary* is a downgrade — if a provider doesn't support FIDO2, document it as residual risk rather than silently accepting TOTP-only.

Record recovery codes for each account **directly into the Phase 2 kit envelope** as you generate them — do not leave them in browser downloads.

### 2. OVH account hardening

- Recovery email: a different mailbox from primary, ideally at a different provider. Add its own recovery path to the kit (avoid circular dependency — see Failure modes).
- Verified phone on the account.
- Confirm both FIDO2 keys challenge correctly: log out, log in with key #2 alone.

### 3. Enforce passkey/FIDO2 on every identity plane

OVH, Cloudflare, Tailscale, Infisical, Healthchecks.io. Verify each dashboard shows **2** registered security keys (or key + TOTP), not one.

### 4. Document the break-glass path as a numbered procedure

Printed, in the offline kit — not only in the password manager:

1. From any machine with internet: `https://www.ovh.com/manager/` → log in with hardware key + separate strong credential (not your usual session).
2. VPS → **Boot in rescue mode** → wait for the rescue email credentials.
3. SSH to rescue (rescue accepts public SSH — this is why public SSH *to rescue* is an accepted temporary exception): `mount /dev/sda1 /mnt` → inspect/repair.
4. Or open **KVM** for interactive console → fix firewall/SSH configs on the real disk.
5. Boot back to disk → verify service → close the incident entry.

### 5. Tailscale least-privilege

- ACLs so only your tagged operator devices can reach `tag:hermes-vps` on port 22 (and later, specific app ports). Nothing else reaches it. Use Tailscale ACL `tests` blocks so ACL intent is machine-checked — "temporary" broad grants become permanent.
- Enable **check mode** for SSH sessions to the VPS (step-up re-auth per sensitive SSH command).

### 6. End-to-end break-glass test (assume Tailscale is dead)

Disable the Tailscale client on your laptop (or revoke the device in the admin console), then execute step 4's procedure *for real*: console login via KVM, run one rescue command on the real filesystem (e.g. `sudo systemctl status sshd` or `systemctl status nftables`), boot back, restore Tailscale access, re-enable your laptop. Time it and log it.

If the rescue path is part of the drill: OVH → boot rescue → `mount /dev/sda1 /mnt && ls /mnt` → read `/etc/hostname` → `umount /mnt` → boot back to disk.

### 7. Second-hardware-key drill

Repeat login on OVH/Cloudflare/Tailscale with key #2 alone (primary key in its drawer). Update the kit's "tested on" dates.

## Adversarial verification (run these attacks)

### A1-1 · Full break-glass drill (assume Tailscale is gone)

On the VPS, simulate loss: `sudo tailscale down` (or logout). Now, from your laptop:

1. Log into the OVH panel using the **hardware key + separate credential** (not your usual session).
2. Open the KVM/console, log in as the admin user.
3. Run a real command in the console (e.g., `systemctl status nftables`) and, if the rescue path is part of the drill, boot rescue mode and mount the disk.
4. Restore Tailscale (`sudo tailscale up`) and confirm admin access returns.

- **PASS:** you reached a root shell with zero Tailscale, zero SSH, using only the documented procedure and offline-held credentials; total time recorded in the ops log.
- **FAIL:** any step requires an undocumented step, a credential you don't actually have offline, or your primary device.

### A1-2 · Account lockout simulation

For OVH, Cloudflare, Tailscale, Infisical, Healthchecks.io: attempt login **without the primary passkey device** — use the backup FIDO2 key, then TOTP/recovery codes. On one account, actually exercise the recovery flow (don't trigger full lockout if it's destructive — verify the recovery *material* opens the door instead).

- **PASS:** every account reachable via a second factor; recovery codes valid; the *offline* hardware key works.
- **FAIL:** any account whose only path is your primary device; recovery codes never tested (untested = probably typo'd).

### A1-3 · Tailscale grants, negative test

From a device *not* in the grant list (e.g., a phone not enrolled, or a test node):

```bash
ssh <tagged-node>          # must be denied
# and attempt to reach the dashboard URL over Tailscale — must be denied
```

- **PASS:** denied by ACL; nothing in the audit log surprises you.
- **FAIL:** reachable — your ACL is broader than you think (default Tailscale ACLs allow all; if you never wrote the restriction, this FAILs).

### A1-4 · Check-mode rehearsal

Run `tailscale ssh` with check mode enabled for a sensitive command and confirm it demands re-authentication.

- **PASS:** re-auth prompt appears; denial logged.

## Pitfalls

1. **Hardware key #2 stored "nearby"** (same drawer/building). Break-glass exists to survive fire/theft/loss; it must be in a second physical location or it isn't break-glass.
2. **TOTP as the *primary*** instead of passkey/FIDO2. TOTP is phishable; the plan mandates passkey/FIDO2 primary. If a provider doesn't support FIDO2, document it as residual risk — don't silently downgrade.
3. **Testing break-glass by logging into the OVH panel only.** The panel is not the console. You must reach the KVM and execute a command on the machine — that's the capability you'll need when the box is wedged.
4. **Skipping the rehearsal because "it obviously works."** Untested recovery paths rot (OIDC config changes, key firmware updates, panel redesigns). Date it, repeat quarterly, or it's theater.
5. **Granting the tailnet admin device broad ACLs "temporarily."** Temporary grants become permanent. Use Tailscale ACL `tests` blocks so ACL intent is machine-checked.
6. **Single point of failure = you carry both keys together.** Mitigation is physical separation, not technology.
7. **Recovery codes stored but never verified** — a code that was never test-redeemed may be wrong/expired. Redeem one code on one low-value account during setup to prove the format, then treat the rest as sealed.
8. **OVH rescue mail goes to a compromised mailbox** — this is why recovery email should be a separate, hardened mailbox; include *its* recovery path in the kit (avoid circular dependency).
9. **Locked out of everything simultaneously:** the printed kit (Phase 2) is the answer — this is exactly why Phase 2 comes immediately after and why the kit must be openable without VPS/Infisical/Cloudflare.

## Gate 1 — honest pass checklist

Per `docs/PLAN.md` Gate 1 — all must pass:

- [ ] Break-glass path documented (numbered procedure, printed in the kit) and physically secured: OVH console/KVM/rescue, protected by hardware key + separate strong credential.
- [ ] Both hardware keys confirmed working (primary + offline backup) — verified by an actual login with key #2 on each provider, not just registration.
- [ ] Passkeys/FIDO2 enforced on: OVH, Cloudflare, Tailscale, Infisical, Healthchecks.io.
- [ ] Tailscale grants least-privilege, device posture where practical, check mode for sensitive SSH.
- [ ] Full break-glass path tested end-to-end with Tailscale unavailable → OVH console → login → rescue command executed **on the VPS itself**.

Fake passes to reject (from the panel review):

- *"I could reach the OVH panel, so break-glass works."* The honest gate is a **timed, end-to-end, Tailscale-assumed-dead** rehearsal that ends with a command executed *on the VPS itself* via KVM/rescue, logged with date and duration in the ops log.
- *"Hardware key #2 is registered."* Registration alone proves nothing — it must actually complete a login on each provider.
- *"Recovery codes are saved."* A code never test-redeemed is probably typo'd — redeem one on a low-value account (A1-2).

Evidence to record in `docs/SETUP-TRACKER.md` and the ops log:

- Ops log entry: `Phase 1 gate: break-glass tested YYYY-MM-DD, duration X min` (start-to-finish with Tailscale disabled).
- "Tested on" dates updated in the kit for each key/account.
- `tailscale status` from laptop shows ACL-restricted reach; an untagged/unauthorized device cannot ping the VPS node.
- Each account dashboard shows **2** registered security keys (or key + TOTP), not one.

## Learner's corner

**What you'll learn in this phase**

- Break-glass design: why the emergency path must be *outside* the normal path entirely (OVH console ≠ SSH ≠ Tailscale).
- FIDO2/WebAuthn semantics: origin binding, why hardware keys resist phishing, the difference between discoverable credentials (passkeys) and key-handle auth.
- Tailscale ACL/grant model: tags, grants, check mode — authorization at the identity layer, not the network layer.
- The "tested vs. documented" gap: a recovery path you've never executed is a hypothesis, not a control.

**Concept primer.** WebAuthn/FIDO2 credentials are cryptographically bound to the *origin* (domain) they were created for, so a phishing site on a lookalike domain cannot use them — the browser signs a challenge including the real origin, and the key refuses to sign for the wrong one. That's why "passkey or FIDO2 primary" isn't just stronger MFA, it's anti-phishing infrastructure. Tailscale flips the default network model: instead of "everyone can reach the box, firewall keeps them out," it's "nobody is even routed to the box unless identity says so." Check mode adds a step-up: even an authorized admin must re-authenticate at the identity provider for each sensitive SSH command — which means a stolen device without a valid session can't silently ride your tunnel. Break-glass is the counterfactual to all of this: it deliberately ignores every layer you built, so it must depend on things an attacker *and* an outage cannot both take from you — a physical key, a separate credential, and OVH's out-of-band console.

**Check-your-understanding**

1. Why is the OVH KVM console, rather than "a second SSH port," the right break-glass path?
   *Answer: a second SSH port shares the same failure domain — the VPS's own network/firewall config. A typo'd firewall or a compromised host can block both. The KVM path lives at the hypervisor level, outside the guest entirely, controlled by account identity you hold offline.*
2. You disabled Tailscale key expiry for the tagged node. What adversary does that invite, and name two mitigations that make it acceptable?
   *Answer: a longer-lived node identity means a stolen node key works indefinitely (threat G/H). Mitigations: tag-based restricted ACL grants (the key can only do what tag:hermes-vps may do), MFA-protected admin account, plus monitoring and rotation procedures — the documented exception in ARCHITECTURE §6.*
3. Why must the break-glass drill be *dated* in the ops log and repeated quarterly, not just done once?
   *Answer: because it decays — hardware keys get lost, credentials rotate, procedures rot. Quarterly dating converts the control from a one-time achievement into an ongoing, auditable property.*

**DIY habit.** Write the break-glass runbook as a numbered procedure, then execute it *from the runbook only* (no memory, no improvising). Every time you improvise a step, that's an undocumented dependency — add it to the runbook or remove the dependency.

## Steady state added by this phase

| Cadence | Task | Wiring |
|---|---|---|
| Quarterly | Full break-glass drill (step 6) incl. key #2 | Calendar recurring + a Healthchecks check `break-glass-drill` pinged manually after each drill (period 90 d / grace 7 d → alerts if skipped) |
| Quarterly | Confirm both keys registered everywhere | Same drill checklist |
| On personnel/auth change | Re-run Tailscale ACL review | Change checklist |

Zero on-box cost — this phase is account/console work plus Tailscale ACL config. No new processes on the VPS.
