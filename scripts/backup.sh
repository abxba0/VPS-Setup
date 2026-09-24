#!/usr/bin/env bash
# =============================================================================
# backup.sh — Phase 0.5 (PLAN.md): Restic -> Cloudflare R2
#
# Credential separation (ARCHITECTURE section 7):
#   - THIS script uses ONLY the bucket-scoped R2 "backup writer" credential.
#     (Panel-corrected wording: restic needs read access to repo metadata, so
#     the token is necessarily read/write TO THE ONE BUCKET.) It must NOT be
#     able to delete or administer. Deletion protection comes from the R2
#     bucket lock/retention enforced server-side by Cloudflare, NOT here.
#   - forget/prune NEVER run on the VPS. Retention is applied from a trusted
#     machine with the admin credential (docs/ARCHITECTURE.md §7).
#   - Browser profiles/cookies are ALWAYS excluded (golden rule 31).
#
# Configuration: /etc/restic-backup.env  (root-owned, mode 0600):
#   export RESTIC_REPOSITORY="s3:https://<account>.r2.cloudflarestorage.com/<bucket>"
#   export RESTIC_PASSWORD_FILE="/etc/restic-repo.pass"   # chmod 600
#   export AWS_ACCESS_KEY_ID="<R2-backup-writer-key-id>"
#   export AWS_SECRET_ACCESS_KEY="<R2-backup-writer-secret>"
#   export HEALTHCHECKS_URL="https://hc-ping.com/<uuid>"  # optional
#
# Usage: backup.sh              # normal run (systemd timer)
#        backup.sh --verify     # also run a quick metadata check
# =============================================================================
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/restic-backup.env}"
LOCK="/run/restic-backup/lock"
LOG_TAG="restic-backup"

log() { printf '[%s] %s\n' "$LOG_TAG" "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
[[ -r "${ENV_FILE}" ]] || { echo "missing ${ENV_FILE}" >&2; exit 1; }
# shellcheck source=/dev/null
source "${ENV_FILE}"

: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY in ${ENV_FILE}}"
: "${RESTIC_PASSWORD_FILE:?set RESTIC_PASSWORD_FILE in ${ENV_FILE}}"

# What gets backed up (Phase 0 scope):
#   /srv/hermes/<profile>/   agent workspaces (quarantine included)
#   /var/lib/hermes/         Hermes core state
#   /etc/nftables.conf       firewall baseline
# Exclusions enforce golden rule 31 (browser data/cookies are NOT backups).
BACKUP_PATHS=(/srv/hermes /var/lib/hermes /etc/nftables.conf)
# Drop paths that do not exist yet instead of failing the whole run
# (panel finding: restic aborts on a missing path, e.g. /var/lib/hermes
# before Hermes has ever run).
EXISTS=()
for p in "${BACKUP_PATHS[@]}"; do
  if [[ -e "${p}" ]]; then
    EXISTS+=("${p}")
  else
    log "skip missing path: ${p}"
  fi
done
[[ ${#EXISTS[@]} -gt 0 ]] || { log "FATAL: no backup paths exist"; exit 1; }
BACKUP_PATHS=("${EXISTS[@]}")
EXCLUDES=(
  --exclude "/srv/hermes/*/browser"
  --exclude "/srv/hermes/*/cookies"
  --exclude "*.cache"
  --exclude "*.lock"
  --exclude "*.tmp"
)

RETAIN_TAG="phase0"
HC="${HEALTHCHECKS_URL:-}"
hc_ping() {
  # /start starts the timer; final ping on success; /fail on failure
  [[ -z "${HC}" ]] && return 0
  curl -fsS -m 10 --retry 2 "${HC}${1}" >/dev/null \
    || log "WARNING: healthchecks ping failed (staleness alerting still covers this)"
}
# Panel finding: if the run dies after /start (OOM via MemoryMax, kill,
# unhandled error), still ping /fail so the check does not rely purely on
# staleness alerting.
HCFIRED=0
on_error() {
  rc=$?
  if [[ ${rc} -ne 0 && ${HCFIRED} -eq 0 ]]; then
    HCFIRED=1
    hc_ping "/fail"
  fi
  exit ${rc}
}
trap on_error EXIT

# Prevent overlapping runs (a hung job must not stack backups)
exec 9>"${LOCK}"
flock -n 9 || { log "another backup is running; exiting"; exit 0; }

hc_ping "/start"
rc=0
log "starting restic backup..."
restic backup "${BACKUP_PATHS[@]}" "${EXCLUDES[@]}" \
  --tag "${RETAIN_TAG}" \
  --host "$(hostname)" \
  -v || rc=$?

if [[ ${rc} -ne 0 ]]; then
  log "backup FAILED rc=${rc}"
  HCFIRED=1
  hc_ping "/fail"
  exit "${rc}"
fi

if [[ "${1:-}" == "--verify" ]]; then
  # Fast structural check (full check is scheduled separately)
  restic check --read-data-subset 1% >/dev/null || {
    log "check FAILED"; HCFIRED=1; hc_ping "/fail"; exit 1; }
fi

log "backup OK"
hc_ping ""
