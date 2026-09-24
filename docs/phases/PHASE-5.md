# Phase 5 — Cloudflare & origin validation

> Companion to `docs/PLAN.md` §Phase 5. Authoritative source: `docs/ARCHITECTURE.md`. Track your progress in `docs/SETUP-TRACKER.md`. Do not start Phase 6 until Gate 5 passes.

## Your goal

The dashboard is reachable only via Cloudflare Tunnel (zero inbound ports for it), behind Cloudflare Access with passkey auth and **short session lifetime**, and — the part everyone skips — the **origin independently validates the `Cf-Access-Jwt-Assertion`**, so a request that bypasses Cloudflare is rejected by the app itself. The dashboard's public hostname is the *only* public surface, which keeps the blast radius of any Access misconfiguration to one app.

## Non-negotiables this phase enforces

From `PLAN.md` / ARCHITECTURE golden rules:

- **Golden rule 18 — no assumption that Cloudflare alone = app identity.** The tunnel is a *transport*, not an *identity*: `cloudflared` will faithfully forward any request Cloudflare sends — including requests produced by a misconfigured Access app, a bypassed policy, or another tunnel pointed at your origin. Origin JWT validation is what makes "came through Access" a cryptographic fact instead of an inference from network topology.
- **#4 — No agent self-approval; out-of-band human approval always.** The admin/approval routes get a **separate, stricter Access application and policy** — part of the gate, not a follow-up.

## Why this phase matters

Threats **A** (internet attacker) and **F** (compromised session) both end their journey at your dashboard. Anyone who learns the origin IP — certificate-transparency logs, scanning, your own past DNS history — can send a request straight to the app with `curl --resolve`, wearing your hostname like a costume. Without origin JWT validation, the tunnel isn't a gate; it's just an unlit side door. The origin check also lives at a layer the agent cannot reach: it's app/proxy code and config, not anything Hermes influences.

## Before you start

**Prerequisites:**

- [ ] Gate 4 passed; Phase 3.5 broker gate passed (the stricter approval-route policy builds on it).
- [ ] `dash.<domain>` DNS zone on Cloudflare; Access enabled on the Zero Trust account; passkey/FIDO2 identity configured (Phases 0–1).
- [ ] cloudflared's egress (443 to the Cloudflare edge) is already allowlisted by Phase 0.3 — verify before relying on the tunnel.

**Hard ordering constraints:**

- **No public surface other than the dashboard hostname** — no direct origin ports, no second tunnel, no "temporarily exposed for debugging."
- **The dashboard must reject all requests lacking a valid `Cf-Access-Jwt-Assertion` before this phase is "done"** — including from localhost and from the tailnet.
- Short Access session lifetime and the stricter admin/approval policy are part of the gate, not a follow-up.

## Credential map

| Credential | Level | Lives where | Must NEVER live |
|---|---|---|---|
| Cloudflare Tunnel token (`cloudflared`) | L3 | systemd unit env for cloudflared only | Git, agent context |
| Access application AUD tag + team domain | L2 | Origin validator config (non-secret but trust-critical) | Hard-coded signing key copies (fetch JWKS live) |
| Access IdP config / app policies | L3 | Cloudflare dashboard (OpenTofu from laptop) | VPS |
| CF Access signing keys | L4-adjacent | Cloudflare-managed; origin fetches JWKS from `https://<team-domain>.cloudflareaccess.com/cdn-cgi/access/certs` | Never pin a static key file on origin |

## Steps

Commands run from the VPS unless prefixed "on laptop". `<...>` placeholders are values you keep in your password manager, never in Git.

### 5.1 — Install cloudflared + create the tunnel

1. Install cloudflared (Cloudflare apt repo), create tunnel `hermes-dash`, ingress maps the dashboard hostname → `http://localhost:<dash-port>`. The Cloudflare-side tunnel/DNS/Access layer is defined via OpenTofu from the laptop (L4 layer, ARCHITECTURE §12); the token lands on the VPS only in the service unit env. Run as a system service:
   ```bash
   sudo cloudflared service install <tunnel-token>
   systemctl status cloudflared --no-pager        # active, connected (check the log line "Registered tunnel connection")
   ```
2. Egress check: cloudflared's egress (443 to the CF edge) must already be allowlisted by Phase 0.3 — verify one connection in the logs; if blocked, extend the allowlist through the **timed-flush** procedure (`apply` → test → `confirm`), never a bare reload.

### 5.2 — Cloudflare Access apps

3. Application on `dash.<domain>` with policy = your identity (passkey/FIDO2), session lifetime **short** (e.g., 8 h or less; 1 h for admin routes). Create a **separate, stricter application/policy for admin/approval routes** (broker approval UI if web-facing) — separate app, separate AUD, separate policy. If dashboard and admin routes share one app, they share one AUD, and a session valid for browsing is valid for approvals.

### 5.3 — Origin JWT validation: the exact checks the origin MUST enforce

The dashboard (or a small validating sidecar/reverse proxy in front of it) must, on **every** request, run all six checks — a request that skips Access never carries these claims:

1. **Signature:** RS256 (or the configured alg — reject `alg=none` and any alg not in your allowlist). Resolve the token's `kid` against the JWKS at `<team-domain>/cdn-cgi/access/certs`. Use the `public_certs`/`keys` **array**, not `public_cert` (single) — after Access's ~6-week key rotation, a stale cached single cert will reject *valid* tokens, and a lazily-trusting validator is worse.
2. **Issuer:** `iss` must string-equal your team domain `https://<team-domain>.cloudflareaccess.com` (exact; pick one scheme/trailing-slash normalization and enforce it).
3. **Audience:** `aud` must equal **your application's AUD tag** (Zero Trust → Access → Applications → Additional settings). This is the check that stops a token minted for Access app A from being replayed at your dashboard or admin app — it's why the dashboard app and the admin/approval app must be **separate Access applications** with separate AUDs and separate policies.
4. **Expiry:** `exp > now`, with ≤60 s leeway; reject `iat` in the future. Compare against a trusted clock (chrony synced).
5. **Claims:** `email` (or your identity claim) must match your allowlist; if you use short-lived app sessions/`identity_nonce`, validate per your IdP flow. Reject unknown claim shapes rather than ignoring them.
6. **Presence:** a request with *no* header is a request that didn't come through Access — reject (401), never fall through to "the tunnel brought it, so it's fine."

**Fetch a real test JWT and eyeball it before wiring validation** — sign in to the dashboard through Access in a browser → DevTools → Network → any request to the origin → copy the `Cf-Access-Jwt-Assertion` request header value into `$JWT`:

```bash
echo "$JWT" | jq -Rr 'split(".")[1] | gsub("-";"+") | gsub("_";"/") | @base64d | fromjson'
# expect: {"aud":"<AUD tag>","email":"you@…","exp":…,"iat":…,"iss":"https://<team-domain>.cloudflareaccess.com", ...}
```

Hand-verify one real JWT end-to-end before trusting a library: decode the payload, read `iss`/`aud`/`exp` yourself, fetch the JWKS, and confirm the token's `kid` is present in the key set.

**Origin topology + the curl battery that *is* the gate:**

```bash
# 0) Origin topology: dashboard listens on loopback only; no public ports
sudo ss -tlnp | grep <dashboard-port>          # expect loopback:<port>, not <public-ip>
nmap -Pn -p- --open <VPS_PUBLIC_IP>            # expect: nothing

# 1) No JWT -> rejected (this is "tunnel ≠ trusted"):
curl -sS -o /dev/null -w '%{http_code}\n' http://<[LOOPBACK]>:<dashboard-port>/dashboard          # expect 401/403
# 2) Garbage JWT -> rejected:
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Cf-Access-Jwt-Assertion: eyJhbGciOiJub25lIn0.fuzz.sig' \
  http://<[LOOPBACK]>:<dashboard-port>/dashboard                                                 # expect 401/403
# 3) Valid JWT, WRONG AUD (use a token from a DIFFERENT Access app, e.g. the admin app):
curl -sS -o /dev/null -w '%{http_code}\n' -H "Cf-Access-Jwt-Assertion: $JWT_OTHER_APP" \
  http://<[LOOPBACK]>:<dashboard-port>/dashboard                                                 # expect 403 (aud mismatch)
# 4) Expired JWT -> rejected (take a real token, wait out the short session, or time-travel iat/exp in a forged token — it must fail on SIG first):
curl -sS -o /dev/null -w '%{http_code}\n' -H "Cf-Access-Jwt-Assertion: $JWT_EXPIRED" http://<[LOOPBACK]>:<dashboard-port>/dashboard  # 403
# 5) Valid, current, correct-aud token -> allowed (end-to-end through Access):
#    Browse https://dash.<domain> in a browser -> 200 + identity shown.
# 6) Approval/admin route requires the STRICTER policy: attempt the admin route with a dashboard-app token -> 403.
# 7) Access session actually expires quickly: sign in, note time, wait past session length, refresh -> re-auth prompted.
# 8) Every rejection above produced a validator log line (log rejections with reason: no_token|bad_sig|bad_iss|bad_aud|expired).
```

Then enforce: any request **without** a valid assertion → 403. Kill the tunnel temporarily (`sudo systemctl stop cloudflared`) and try to reach the origin from the laptop via the VPS IP directly → must be refused by the app (and by nftables anyway — the dashboard port is not in the inbound allowlist at all, which is the outer belt).

### 5.4 — Cloudflare rate limiting + logging

4. Rate limiting + logging on the dashboard hostname; logs to Cloudflare (off-box) — check the Security Events dashboard shows your tests from 5.3.

### 5.5 — Public surface audit

5. `dash.<domain>` is the only public hostname; everything else (admin, metrics, broker) stays Tailscale-only. Verify:
   ```bash
   # DNS records inventory in Cloudflare = exactly what you expect (check in the dashboard/OpenTofu plan)
   nmap -Pn -p- <VPS_PUBLIC_IP>        # from outside: nothing (Gate 0b re-check)
   ```

### Verification & expected output

- `curl https://dash.<domain>/` unauthenticated → redirect to Access login.
- Request with a stale/expired/other-app JWT → 403 from the **origin**, logged with the failing check named.
- Stop `cloudflared` → dashboard unreachable publicly; start → green again; Healthchecks uptime check (Phase 7) flapped accordingly.
- Origin logs show the validated email claim per request.

### 4 GB budget reality

cloudflared ≈ 30–60 MB (`MemoryMax=256M` on its unit, `TasksMax=50`). If JWT validation runs as a separate sidecar (nginx/nauthilus-style), budget another ~50–100 MB — prefer building validation into the dashboard process or a tiny validating proxy rather than a full second web server. No other impact.

### Failure modes & recovery

- **Tunnel down but box healthy:** Healthchecks uptime check goes red; `journalctl -u cloudflared` for the cause (usually CF edge or credential expiry). Recovery: `systemctl restart cloudflared`; if cert/token expired, re-login via the dashboard token. Admin plane (Tailscale) is unaffected — that's the point of two planes.
- **JWT audience mismatch after creating a second Access app:** requests 403 across the board — you validated against app A's AUD while users authenticate via app B. Fix the AUD mapping; this failure is loud and immediate, not subtle.
- **Key rotation:** CF rotates signing keys (~6 weeks) — the validator must refetch `/cdn-cgi/access/certs` (cache TTL in hours), else a healthy system starts 403-ing after rotation. Test by clearing the cached keys.
- **Temptation to "temporarily" bind the dashboard to the public interface for debugging:** don't; debug via Tailscale + localhost.

## Adversarial verification (run these attacks)

Run every attack from an external vantage point (laptop on a non-Tailscale network, or a cheap second VPS/VM).

**A5-1 · Direct-to-origin bypass (the core test).** Find the origin IP (your VPS public IP; the Tailscale path is admin-only). From an external host:

```bash
# 1) No JWT at all — direct hit, bypassing Cloudflare entirely:
curl -sSv --resolve dashboard.example.com:443:<VPS_PUBLIC_IP> https://dashboard.example.com/ 2>&1 | tail -20

# 2) Mocked/garbage JWT:
curl -sS --resolve dashboard.example.com:443:<VPS_PUBLIC_IP> https://dashboard.example.com/ \
  -H 'Cf-Access-Jwt-Assertion: <garbage-jwt>'

# 3) A REAL Cloudflare Access JWT — but from a different Access app (wrong audience):
#    (grab one from another CF-protected app you own, or craft one signed by a different key)
curl -sS --resolve dashboard.example.com:443:<VPS_PUBLIC_IP> https://dashboard.example.com/ \
  -H "Cf-Access-Jwt-Assertion: $JWT_FROM_OTHER_APP"

# 4) Expired JWT (wait out a captured token's exp, or use one from a session you expired):
curl -sS --resolve dashboard.example.com:443:<VPS_PUBLIC_IP> https://dashboard.example.com/ \
  -H "Cf-Access-Jwt-Assertion: $EXPIRED_JWT"

# 5) Replay: reuse a token captured earlier from your own legitimate session log:
curl -sS --resolve dashboard.example.com:443:<VPS_PUBLIC_IP> https://dashboard.example.com/ \
  -H "Cf-Access-Jwt-Assertion: $CAPTURED_JWT"
```

For each variant, identify **which check caught it** (your origin app must log the failed-check reason):

| Variant | Must be caught by | PASS evidence |
|---|---|---|
| no header | presence check | 401/403 "missing Cf-Access-Jwt-Assertion" |
| garbage JWT | **signature** verification | 401 "invalid signature" (fails first, before claims) |
| real JWT, other app | **audience (`aud`) claim** | 401 "aud mismatch" |
| expired JWT | **`exp` claim** | 401 "token expired" |
| replayed JWT | **see A5-2** | depends on your session model |

- **PASS:** every variant rejected; the response is a 4xx with no application content; each failure logged with the failing check named.
- **FAIL:** any 200/app content; or everything rejected by a single generic error with no log (you can't tell which check fired — fix logging so the gate is *diagnosable*).

**A5-2 · Replay nuance (be honest about what JWT validation can and can't do).** A *valid, unexpired, correctly-aud* JWT replayed within its lifetime will pass pure stateless validation — that's the nature of JWTs. Your compensations must be one or more of: (a) short session lifetime (minutes, not hours) shrinking the window; (b) server-side session/jti cache marking tokens consumed at first use; (c) Cloudflare Access session revocation tied to identity. Test (a): check your Access app's session duration in the CF dashboard. Test (c): revoke your own session in CF and confirm the dashboard immediately demands re-auth even though the JWT itself still validates mathematically.

- **PASS:** session lifetime is short by config; revocation actually kills access.
- **FAIL:** session duration left at default (e.g., 24 h) — your replay window is a day.

**A5-3 · Approval-route stricter policy.** Request the admin/approval route (a) normally, (b) from a session that passes the *dashboard* policy but not the stricter one (e.g., different device/posture).

- **PASS:** dashboard works; approval route refuses the weaker session.
- **FAIL:** one policy guards both.

**A5-4 · Origin hygiene.** `nmap -Pn -p-` again from outside: still zero open ports (tunnel is outbound-only). Attempt requests at the bare origin with SNI/Host tricks (`curl -k https://<VPS_PUBLIC_IP>/ -H 'Host: dashboard.example.com'`):

- **PASS:** refused/401 — nothing serves app content on the bare IP.
- **FAIL:** app responds to Host-header/SNI-directed requests on the bare origin without a valid JWT (means validation isn't actually attached to the app, just to some path).

## Pitfalls

1. **Validating the `CF_Authorization` cookie instead of the `Cf-Access-Jwt-Assertion` header.** The cookie isn't guaranteed present on non-browser/API requests; the header is what Cloudflare attaches to every proxied request. Fix: validate the header (per CF docs recommendation).
2. **Pin-a-cert-and-forget:** hard-coding one public key means the ~6-week rotation silently breaks your dashboard (fail-closed, at least) or, worse, a validator that falls back to "skip signature if certs unreachable" (fail-open, catastrophic). Fix: fetch JWKS from the live endpoint, match `kid` against the full key set, cache with a TTL in hours, and never skip verification when the JWKS fetch fails.
3. **One Access app for everything.** Shared app = shared AUD = a session valid for browsing is valid for approvals. Fix: separate apps, separate policies, separate AUD tags; test cross-app token reuse (test 3 in 5.3 / A5-1) explicitly.
4. **Checking `exp` with huge leeway, or not checking `aud` at all.** "Expired" tokens valid for hours and cross-app replay are the two silent failures; the curl battery is designed to catch exactly these.
5. **Testing only through the tunnel.** The gate's core test is a *direct* request to the origin (loopback/tailnet/public IP) with no/malformed JWT — that's the "bypass Cloudflare" path. If your validator lives behind the tunnel or in CF config instead of on the origin, this test exposes it.
6. **Diagnosability skipped:** one generic 403 with no reason code means you can't distinguish bad-sig from bad-aud — and neither can you debug it later. Fix: log the failing check (`no_token|bad_sig|bad_iss|bad_aud|expired`) on every rejection.

## Gate 5 — honest pass checklist

From `PLAN.md` Gate 5, plus the fake-pass warnings:

- [ ] A direct request to the origin bypassing Cloudflare is rejected — JWT missing *and* invalid.
- [ ] Access session expires quickly (verified by waiting it out, not by reading the config).
- [ ] Approval routes require the stricter policy (separate Access app / AUD).
- [ ] The dashboard's public hostname is the only public surface; `nmap -Pn -p-` from outside shows zero open ports.

**Fake passes to hunt for — each one silently fails the gate:**

- [ ] "curl to localhost returned 200, so the dashboard works" — that proves the app runs, not that Access does.
- [ ] The negative battery (missing, garbage, wrong-aud, expired) all returned 401/403 **with a logged reason** — "it rejected" without a reason code is not evidence you can debug or audit.
- [ ] The positive end-to-end case ran through Access in a real browser (valid, current, correct-aud token → 200 + identity shown).
- [ ] Replay compensations verified: short session duration set *in the Access app config*, and session revocation observed to kill access immediately.
- [ ] Validator outputs (reason codes) recorded in the ops log — not reconstructed from memory.

**Evidence to record in `SETUP-TRACKER.md` / ops log:**

- [ ] The curl battery transcript from 5.3 (tests 1–8) and A5-1…A5-4 results, dated, each rejection with its reason code.
- [ ] The A5-1 bypass-variant → catching-check mapping, filled in with your observed evidence.
- [ ] Access app config export/plan: session lifetime values for dashboard and admin apps, AUD tags, policy diffs.
- [ ] JWKS fetch + `kid` match demonstration; the key-rotation cache-clear test result.
- [ ] cloudflared service status + "Registered tunnel connection" log line; the tunnel stop/start flap test.
- [ ] Cloudflare Security Events screenshot showing your probes; DNS records inventory (the public-surface audit).
- [ ] `nmap -Pn -p- <VPS_PUBLIC_IP>` post-phase output (zero open ports).

## Learner's corner

**What you'll learn in this phase**

- The distinction between *transport trust* (tunnel) and *request identity* (JWT) — and why conflating them is the classic tunnel misconfiguration.
- JWT anatomy: header/payload/signature; verifying `iss`, `aud`, `exp`; fetching and caching the IdP's JWKS public keys.
- `curl --resolve` as a general technique for testing "what if I skip the CDN."
- Cloudflare Access policies: application-scoped, per-path stricter rules, session lifetime as a security parameter.
- Defense where the agent can't reach: the origin check lives in app code/config, not in anything Hermes influences.

**Concept primer.** A Cloudflare Tunnel gives you *privacy of transport*: no inbound ports, no exposed origin IP in DNS. It does **not** give you *authentication of requests* — anyone who learns the origin IP (certificate-transparency logs, scanning, your own past DNS history) can send a request straight to the app with `--resolve`, wearing your hostname like a costume. The `Cf-Access-Jwt-Assertion` header is Cloudflare Access signing, per-request, "this human identity passed my policy for *this specific application*" — the `aud` claim binds the token to one Access app's ID, which is exactly why a token from another app fails: the token says "I am for app X," and your app must refuse anything not addressed to it. Verification order matters for both security and diagnosability: signature first (proves Cloudflare, not a forger, authored it), then issuer, then audience, then expiry — each failure logged with its reason, so an attacker probing you teaches you nothing while your log tells you everything. The honest residual is replay within expiry; you close that with short sessions and revocation, not with cleverer JWT parsing.

**Check-your-understanding**

1. "The tunnel is encrypted and inbound ports are closed, so nobody can reach the dashboard." Find the flaw.

   *Answer: confidentiality ≠ authentication, and the tunnel only hides the origin from casual discovery. The origin IP is discoverable (cert logs, scanning, historical DNS), and any direct-to-origin request rides the normal web stack. Without JWT validation, tunnel ≠ gate; it's just an unlit side door.*

2. You capture a valid JWT for the dashboard app and send it to the *approval* route. What should reject it, and which claim is doing the work?

   *Answer: the stricter Access app/policy on the approval route — its own `aud` (different app ID) and its policy requirements. The audience claim is the binding; if both routes share one Access app, that's the misconfiguration to fix.*

3. Your origin logs show all bypass attempts failing with one generic 403 and no reason. Why is that a gate failure even though nothing got through?

   *Answer: the gate must be diagnosable to be maintainable — without per-check failure reasons you can't tell whether signature validation is actually enabled, whether `aud` is checked, or whether one day a bug silently drops a check. Logging the failing check is how the control stays verifiable over time.*

4. Why is `curl --resolve` (rather than just `curl https://<origin-ip>/`) the right test shape?

   *Answer: it makes the request look exactly like a legitimate one at the HTTP layer — correct Host/SNI — while bypassing Cloudflare's network. That isolates the variable under test: identity enforcement at the origin, not TLS/hostname weirdness.*

**Do-it-yourself habit.** Before wiring validation, hand-verify one real JWT end-to-end: capture it, split on `.`, base64url-decode the payload (`printf '%s' "$PAYLOAD" | tr '_-' '/+' | base64 -d 2>/dev/null | jq`), read `iss`, `aud`, `exp` yourself, and fetch the JWKS to confirm the signing key ID (`kid`). You should be able to explain every claim in the payload before you trust a library to check them.

## Steady state added by this phase

| Cadence | Task | Wiring |
|---|---|---|
| Continuous | Uptime check on dash hostname | Healthchecks `hermes-dash-uptime` (period 5 min) |
| Weekly | Skim Cloudflare Security Events + Access logs | weekly slot |
| On Access policy changes | re-run the bypass test (5.3 negative battery / A5-1) | change checklist |
| ~Every 6 weeks (CF key rotation) | confirm JWKS refresh still works (clear cached keys once as a drill) | validator TTL + ops log note |
