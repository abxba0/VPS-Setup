#!/usr/bin/env bash
# =============================================================================
# tailscale-setup.sh — Phase 0.2 (PLAN.md)
# Installs Tailscale, joins the tailnet as a TAGGED server node, enables
# Tailscale SSH, and disables key expiry guidance.
#
# PREREQUISITE (you, in the Tailscale admin console):
#   ACL policy must own the tag, e.g.:
#     "tagOwners": { "tag:hermes-vps": ["autogroup:admin"] }
#   Otherwise --advertise-tags is rejected.
#
# KEY EXPIRY EXCEPTION (ARCHITECTURE §6): after joining, go to the admin
# console -> this machine -> disable key expiry. Documented exception:
#   WHY: unattended server must remain reachable.
#   RISK: compromised node identity lives longer.
#   MITIGATIONS: tag ownership, restricted grants, MFA on operators, OVH
#   rescue path, monitoring, credential rotation.
# =============================================================================
set -euo pipefail

TAG="${TAG:-tag:hermes-vps}"

log() { printf '[tailscale] %s\n' "$*"; }
die() { printf '[tailscale] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo)"

if ! command -v tailscale >/dev/null; then
  log "installing Tailscale from the official repo..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

log "joining tailnet with tag=${TAG} (Tailscale SSH enabled)..."
# --ssh: Tailscale SSH handles terminal access (check-mode available for
# sensitive sessions later via the admin console).
# The command prints an auth URL; open it from an authenticated device.
# --accept-dns=false (panel finding): the OS resolver is pinned to approved
# resolvers by cloud-init (OUTPUT firewall only allows those). MagicDNS would
# otherwise rewrite the global resolver config and its upstream forwarding
# would be dropped by the firewall. Use 100.x.y.z addresses for tailnet hosts.
tailscale up --advertise-tags="${TAG}" --ssh --hostname=hermes-vps --accept-dns=false

log "status:"
tailscale status
log ""
log "NEXT STEPS (manual, admin console):"
log "  1. Approve the node tag if prompted (device approval)."
log "  2. Disable key expiry for this node (documented exception)."
log "  3. Verify 'tailscale ping' and Tailscale SSH from your laptop."
log "  4. Tailscale ACLs: restrict SSH to your operator devices only."
