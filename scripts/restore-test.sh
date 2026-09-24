#!/usr/bin/env bash
# =============================================================================
# restore-test.sh — Phase 0.5 Gate 0: PROVE the backup works.
#
# "No backup without restore testing" (golden rule 11). Run this on the VPS
# after the first backup, and during every quarterly rebuild test. A restore
# test only passes when files can be verified against the source.
#
# Uses the SAME repository password as the writer — but note the REAL disaster
# test is restoring FROM THE LAPTOP with the offline recovery credential
# (docs/PLAN.md Phase 2). This script is the quick in-place proof.
#
# Usage:
#   sudo ./restore-test.sh                     # restore 'latest' + verify
#   sudo ./restore-test.sh <snapshot-id>       # restore specific snapshot
#   sudo ./restore-test.sh --deep              # also read-verify 5% of data
# =============================================================================
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/restic-backup.env}"
TARGET="/root/restore-test"
SRC="/srv/hermes"

log() { printf '[restore-test] %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
[[ -r "${ENV_FILE}" ]] || { echo "missing ${ENV_FILE}" >&2; exit 1; }
# shellcheck source=/dev/null
source "${ENV_FILE}"
: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY in ${ENV_FILE}}"
: "${RESTIC_PASSWORD_FILE:?set RESTIC_PASSWORD_FILE in ${ENV_FILE}}"

SNAPSHOT="${1:-latest}"
DEEP=0
[[ "${1:-}" == "--deep" ]] && { DEEP=1; SNAPSHOT="latest"; }

# --- 1. Repository structural check (cheap) --------------------------------
log "running restic check (metadata)..."
restic check || { log "FAIL: repository check failed — INCIDENT"; exit 1; }
if [[ ${DEEP} -eq 1 ]]; then
  log "deep mode: reading 5% of repository data..."
  restic check --read-data-subset 5% || { log "FAIL: data check failed"; exit 1; }
fi

# --- 2. Restore to scratch ---------------------------------------------------
rm -rf "${TARGET}"
mkdir -p "${TARGET}"
chmod 700 "${TARGET}"
log "restoring snapshot '${SNAPSHOT}' to ${TARGET}..."
restic restore "${SNAPSHOT}" --target "${TARGET}" || {
  log "FAIL: restore errored"; exit 1; }

# --- 3. Verify against source ------------------------------------------------
# restic restore --target re-roots absolute paths, so a snapshot of /srv/...
# appears under ${TARGET}/srv/hermes (panel: confirmed layout).
# Panel finding: a snapshot MISSING /srv/hermes must be a hard FAIL — the
# lenient "some files restored" branch previously allowed a false PASS.
if [[ ! -d "${TARGET}/srv/hermes" ]]; then
  log "FAIL: snapshot does not contain /srv/hermes — the primary data was"
  log "      never verified. Inspect ${TARGET}, then: rm -rf ${TARGET}"
  exit 1
fi
log "comparing restored tree against live ${SRC}..."
# Live files may legitimately differ if changed since the snapshot; exclude
# the same trees the backup excludes (panel: otherwise excluded files count
# as diffs and the threshold false-fails once caches exist).
diffcount=$(diff -rq \
      -x 'browser' -x 'cookies' -x '*.cache' -x '*.tmp' -x '*.lock' \
      "${TARGET}/srv/hermes" "${SRC}" 2>/dev/null | wc -l || true)
files_total=$(find "${SRC}" -type f 2>/dev/null | wc -l)
log "files under ${SRC}: ${files_total}; reported diffs vs snapshot: ${diffcount}"
# Threshold: >10% difference (or empty restore) = fail.
limit=$(( files_total / 10 + 1 ))
if [[ ${files_total} -eq 0 || ${diffcount} -gt ${limit} ]]; then
  log "FAIL: restore differs too much (files=${files_total}, diffs=${diffcount})"
  log "inspect ${TARGET} manually, then: rm -rf ${TARGET}"
  exit 1
fi
# /var/lib/hermes and firewall config: restored but only spot-checked here
# (panel: extend coverage without over-engineering Phase 0).
if [[ -d "${TARGET}/var/lib/hermes" ]]; then
  libfiles=$(find "${TARGET}/var/lib/hermes" -type f | wc -l)
  log "restored /var/lib/hermes: ${libfiles} files"
fi
[[ -f "${TARGET}/etc/nftables.conf" ]] \
  || log "WARNING: snapshot missing /etc/nftables.conf"

# --- 4. Cleanup (or keep for manual inspection on failure) -------------------
rm -rf "${TARGET}"
log "PASS: restore test OK (${SNAPSHOT})."
log "REMEMBER: the true DR test restores FROM THE LAPTOP using the offline"
log "recovery credential (PLAN.md Phase 2 / quarterly rebuild, Phase 8)."
