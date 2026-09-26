#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

PROGRAM=${0##*/}
MODE=
HARDEN_SSH=0
WITH_FAIL2BAN=1
FAIL2BAN_OPTION_SET=0
BACKUP_DIR=
FIREWALL_RULES=()
PORTS_FILE=/var/lib/vps-hardening/allowed_ports
SSH_MARKER=/var/lib/vps-hardening/ssh_auth_hardened
IDLE_TIMEOUT_FILE=/etc/profile.d/zz-vps-idle-timeout.sh
IDLE_TIMEOUT_SECONDS=900
UFW_BACKUP=
UFW_WAS_ACTIVE=0
ROLLBACK_UFW=0
ROLLBACK_SSH=0
SSH_DROPIN=/etc/ssh/sshd_config.d/00-vps-hardening.conf
SSH_BACKUP_FILE=
SSH_DROPIN_EXISTED=0
SSH_CONTEXT=

usage() {
  cat <<EOF
Usage: sudo ./$PROGRAM [--check | --verify | --apply] [options]

Modes:
  --check             Read-only inventory (the default)
  --verify            Run post-change checks without modifying the server
  --apply             Interactively configure UFW, Fail2ban, and shell timeout

Options:
  --harden-ssh         (with --apply) Offer to disable root, password, and keyboard-interactive SSH login
  --no-fail2ban        (with --apply or --verify) Skip/omit the default Fail2ban SSH jail
  -h, --help           Show this help

Apply mode sets TMOUT=900 for new interactive Bash logins. Reconnect after applying;
the already-open shell is not retroactively timed out. Running commands are unaffected.
When connected over SSH, preserve SSH_CONNECTION for port and Match-rule checks:
  sudo env SSH_CONNECTION="${SSH_CONNECTION:-}" bash ./$PROGRAM --check
  sudo env SSH_CONNECTION="${SSH_CONNECTION:-}" bash ./$PROGRAM --verify

Keep the current SSH session open throughout. Test a second SSH login before
closing it. --apply requires working provider console/rescue access. This script
does not change the SSH port, run a full package upgrade, reboot, or modify provider-level
firewall rules. It is a baseline host check, not a compliance audit or incident
response tool, and it does not assess application security or outside-in reachability.
The 15-minute timeout applies only to interactive Bash shells at an idle prompt;
it does not terminate running commands, SFTP, SSH tunnels, or other shells.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

on_interrupt() {
  trap - INT TERM HUP
  if ((ROLLBACK_SSH)); then
    warn 'Interrupted while testing SSH changes; restoring the previous SSH drop-in.'
    restore_ssh || true
  fi
  if ((ROLLBACK_UFW)); then
    warn 'Interrupted while testing UFW; restoring the previous UFW configuration.'
    restore_ufw || true
  fi
  exit 130
}

trap on_interrupt INT TERM HUP

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

info() {
  printf '\n== %s ==\n' "$*"
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

is_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

fail2ban_sshd_jail_active() {
  local status
  status=$(fail2ban-client status 2>/dev/null) || return 1
  awk '
    /Jail list:/ {
      sub(/^.*Jail list:[[:space:]]*/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      count = split($0, jails, /,[[:space:]]*/)
      for (i = 1; i <= count; i++) {
        if (jails[i] == "sshd") found = 1
      }
    }
    END { exit !found }
  ' <<<"$status"
}

wait_for_fail2ban_sshd_jail() {
  local attempt
  for ((attempt = 0; attempt < 10; attempt++)); do
    if is_active fail2ban.service && fail2ban_sshd_jail_active; then
      return 0
    fi
    sleep 1
  done
  return 1
}

is_ubuntu() {
  [[ -r /etc/os-release ]] || die 'Cannot read /etc/os-release.'
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == ubuntu ]] || die "This script supports Ubuntu only (detected: ${PRETTY_NAME:-unknown})."
  has_command apt-get || die 'apt-get is required.'
  has_command systemctl || die 'systemd is required.'
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run with sudo: sudo ./$PROGRAM --$MODE"
}

acquire_apply_lock() {
  has_command flock || die 'flock is required to prevent concurrent apply runs.'
  exec 9>/run/lock/secure-ubuntu-vps.lock
  flock -n 9 || die 'Another --apply run is already in progress.'
}

get_ssh_port() {
  local ssh_connection_port=''
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    ssh_connection_port=$(awk '{print $4}' <<<"$SSH_CONNECTION")
  fi
  if validate_port "$ssh_connection_port"; then
    printf '%s' "$ssh_connection_port"
    return
  fi
  if has_command sshd; then
    sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }'
  fi
}

ssh_context_spec() {
  local user=$1 remote_addr remote_port local_addr local_port client_host usedns reverse_hosts ssh_defaults
  [[ -n ${SSH_CONNECTION:-} ]] || return 1
  read -r remote_addr remote_port local_addr local_port <<<"$SSH_CONNECTION"
  [[ $remote_addr =~ ^[0-9a-fA-F:.]+$ && $local_addr =~ ^[0-9a-fA-F:.]+$ ]] || return 1
  validate_port "$remote_port" && validate_port "$local_port" || return 1
  local_port=$((10#$local_port))

  client_host=$remote_addr
  ssh_defaults=$(sshd -T 2>/dev/null) || return 1
  usedns=$(awk '$1 == "usedns" { print $2; exit }' <<<"$ssh_defaults")
  if [[ $usedns == yes ]]; then
    reverse_hosts=$(getent hosts "$remote_addr" 2>/dev/null) || return 1
    client_host=$(awk 'NR == 1 { print $2 }' <<<"$reverse_hosts")
    [[ $client_host =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
  fi
  printf 'user=%s,host=%s,addr=%s,laddr=%s,lport=%s' \
    "$user" "$client_host" "$remote_addr" "$local_addr" "$local_port"
}

idle_timeout_conflicts() {
  local pattern='^[[:space:]]*(export[[:space:]]+|readonly([[:space:]]+-[[:alnum:]]+)?[[:space:]]+|declare[[:space:]]+-[[:alnum:]]+[[:space:]]+)*TMOUT[[:space:]]*='
  local matches profile
  matches=$(grep -Erl "$pattern" /etc/profile /etc/bash.bashrc /etc/profile.d /etc/environment 2>/dev/null | grep -Fvx "$IDLE_TIMEOUT_FILE" || true)
  for profile in /root/.profile /root/.bashrc /root/.bash_profile /root/.bash_login \
      /home/*/.profile /home/*/.bashrc /home/*/.bash_profile /home/*/.bash_login; do
    if [[ -f $profile && $profile != "$IDLE_TIMEOUT_FILE" ]] && grep -Eq "$pattern" "$profile"; then
      matches+="$profile"$'\n'
    fi
  done
  printf '%s' "$matches"
}

idle_timeout_is_configured() {
  [[ -r $IDLE_TIMEOUT_FILE ]] && \
    grep -Eq "^[[:space:]]*TMOUT=$IDLE_TIMEOUT_SECONDS$" "$IDLE_TIMEOUT_FILE" && \
    grep -Eq '^[[:space:]]*declare[[:space:]]+-rx[[:space:]]+TMOUT$' "$IDLE_TIMEOUT_FILE"
}

show_firewall() {
  local firewall_status
  if has_command ufw; then
    firewall_status=$(ufw status verbose 2>/dev/null || true)
    printf '%s\n' "$firewall_status"
    if grep -q '^Default: allow (incoming)' <<<"$firewall_status"; then
      warn 'UFW default incoming policy is allow; existing policy was not changed.'
    fi
  else
    printf 'UFW is not installed.\n'
  fi
  if is_active firewalld.service; then
    warn 'firewalld is active.'
  fi
  if is_active nftables.service; then
    warn 'The nftables service is active.'
  fi
  if has_command docker; then
    warn 'Docker is installed. Published container ports may bypass UFW; this script will not configure UFW on a Docker host.'
  fi
  if [[ -r /etc/default/ufw ]]; then
    awk -F= '$1 == "IPV6" { print "UFW IPv6 setting: " $2 }' /etc/default/ufw
  fi
}

show_updates() {
  local simulated_upgrades
  if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
    printf 'unattended-upgrades: installed\n'
    if has_command apt-config; then
      apt-config dump 2>/dev/null | grep -E '^APT::Periodic::(Update-Package-Lists|Unattended-Upgrade)|^Unattended-Upgrade::Automatic-Reboot' || true
    fi
    if systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null; then
      printf 'apt-daily-upgrade.timer: enabled\n'
    else
      printf 'apt-daily-upgrade.timer: not enabled (or unavailable)\n'
    fi
  else
    printf 'unattended-upgrades: not installed\n'
  fi
  printf 'Pending package upgrades (using the current package cache): '
  if has_command apt-get; then
    if simulated_upgrades=$(apt-get -s upgrade 2>/dev/null); then
      awk '/^Inst / { count++ } END { printf "%d\n", count }' <<<"$simulated_upgrades"
    else
      printf 'not available (package database may be busy)\n'
    fi
  else
    printf 'not checked (apt-get unavailable)\n'
  fi
  if [[ -e /var/run/reboot-required ]]; then
    printf 'A reboot is required by installed updates; this script will not reboot.\n'
    [[ -r /var/run/reboot-required.pkgs ]] && sed 's/^/  /' /var/run/reboot-required.pkgs
  else
    printf 'No reboot-required marker is present.\n'
  fi
}

show_inventory() {
  local ssh_port timeout_configs
  info 'System'
  printf 'Audit UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-Ubuntu}")"
  printf 'Kernel: %s\n' "$(uname -r)"

  info 'SSH'
  if has_command sshd; then
    sshd -t && printf 'sshd configuration syntax: valid\n' || warn 'sshd configuration syntax is invalid.'
    sshd -T 2>/dev/null | awk '/^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication) / { print }' || true
    if is_active ssh.service || is_active ssh.socket; then
      printf 'SSH service/socket: active\n'
    else
      warn 'Neither ssh.service nor ssh.socket is active.'
    fi
  else
    warn 'sshd is not installed or is not in PATH.'
  fi
  ssh_port=$(get_ssh_port || true)
  [[ -n $ssh_port ]] && printf 'Detected SSH port: %s/tcp\n' "$ssh_port" || warn 'Could not detect the SSH port; it must be confirmed manually.'

  info 'Brute-force protection'
  if has_command fail2ban-client; then
    fail2ban-client status || warn 'Fail2ban service is not responding.'
    if is_active fail2ban.service && fail2ban_sshd_jail_active; then
      printf 'Fail2ban SSH jail is loaded.\n'
    else
      warn 'Fail2ban SSH jail is not loaded.'
    fi
  else
    printf 'Fail2ban is not installed; --apply installs it by default.\n'
  fi

  info 'Interactive Bash idle timeout'
  if idle_timeout_is_configured; then
    printf 'PASS: interactive Bash prompts time out after 15 minutes\n'
  else
    timeout_configs=$(idle_timeout_conflicts)
    if [[ -n $timeout_configs ]]; then
      printf 'Existing TMOUT configuration found in:\n%s\n' "$timeout_configs"
    else
      printf 'Not configured; --apply sets a 15-minute interactive Bash timeout.\n'
    fi
  fi

  info 'Firewall'
  show_firewall

  info 'Listening sockets'
  ss -lntup 2>/dev/null || warn 'Could not inspect listening sockets (install iproute2 or run as root).'

  info 'Security updates'
  show_updates

  info 'AppArmor'
  if is_active apparmor.service; then
    printf 'AppArmor service: active\n'
  else
    printf 'AppArmor service: not active or unavailable\n'
  fi

}

verify_server() {
  local failures=0 apt_configuration='' ufw_status='' ufw_verbose='' ipv6_enabled=0 rule status
  info 'Verification'

  if external_firewall_detected; then
    printf 'WARN: Docker or another firewall manager is present; UFW alone cannot be treated as the complete firewall.\n'
    failures=$((failures + 1))
  fi

  if has_command sshd; then
    if sshd -t; then
      printf 'PASS: sshd configuration syntax\n'
    else
      printf 'FAIL: sshd configuration syntax\n'
      failures=$((failures + 1))
    fi
    if is_active ssh.service || is_active ssh.socket; then
      printf 'PASS: SSH service/socket active\n'
    else
      printf 'FAIL: SSH service/socket active\n'
      failures=$((failures + 1))
    fi
  else
    printf 'FAIL: sshd command unavailable\n'
    failures=$((failures + 1))
  fi

  if has_command ufw; then
    ufw_status=$(ufw status 2>/dev/null || true)
    if grep -q '^Status: active' <<<"$ufw_status"; then
      printf 'PASS: UFW is active\n'
      ufw_verbose=$(ufw status verbose 2>/dev/null || true)
      printf '%s\n' "$ufw_verbose"
      if grep -q '^Default: allow (incoming)' <<<"$ufw_verbose"; then
        printf 'FAIL: UFW default inbound policy allows traffic\n'
        failures=$((failures + 1))
      elif grep -Eq '^Default: (deny|reject) \(incoming\)' <<<"$ufw_verbose"; then
        printf 'PASS: UFW default inbound policy is restrictive\n'
      else
        printf 'WARN: could not determine the UFW default inbound policy\n'
      fi
      if grep -Eq '^IPV6="?yes"?$' /etc/default/ufw 2>/dev/null; then
        ipv6_enabled=1
      else
        printf 'FAIL: UFW IPv6 filtering is not enabled\n'
        failures=$((failures + 1))
      fi
    else
      printf 'WARN: UFW is not active\n'
      failures=$((failures + 1))
    fi
  else
    printf 'WARN: UFW is not installed\n'
    failures=$((failures + 1))
  fi

  if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
    printf 'PASS: unattended-upgrades is installed\n'
    apt_configuration=$(apt-config dump 2>/dev/null || true)
    if grep -Fqx 'APT::Periodic::Unattended-Upgrade "1";' <<<"$apt_configuration"; then
      printf 'PASS: automatic unattended upgrades are enabled\n'
    else
      printf 'WARN: automatic unattended upgrades are not confirmed enabled\n'
    fi
    if grep -Fqx 'Unattended-Upgrade::Automatic-Reboot "true";' <<<"$apt_configuration"; then
      printf 'WARNING: unattended upgrades are configured to reboot automatically\n'
    fi
  else
    printf 'WARN: unattended-upgrades is not installed\n'
  fi

  if idle_timeout_is_configured; then
    printf 'PASS: profile configures a 15-minute interactive Bash idle timeout\n'
  else
    printf 'FAIL: interactive Bash idle timeout is not configured for 15 minutes\n'
    failures=$((failures + 1))
  fi

  if ((WITH_FAIL2BAN)); then
    if has_command fail2ban-client && wait_for_fail2ban_sshd_jail; then
      printf 'PASS: Fail2ban SSH jail is active\n'
    else
      printf 'FAIL: required Fail2ban SSH jail is not active\n'
      failures=$((failures + 1))
    fi
  elif has_command fail2ban-client; then
    if wait_for_fail2ban_sshd_jail; then
      printf 'INFO: Fail2ban SSH jail is active\n'
    else
      printf 'INFO: Fail2ban is installed but not required by this verification run\n'
    fi
  else
    printf 'INFO: Fail2ban is not required by this verification run\n'
  fi

  if [[ -r $PORTS_FILE ]] && grep -q '^Status: active' <<<"$ufw_status"; then
    status=$ufw_status
    while IFS= read -r rule; do
      [[ -n $rule ]] || continue
      if ((ipv6_enabled)) && awk -v rule="$rule" \
          '$1 == rule && $2 == "ALLOW" && $3 == "IN" { v4=1 } $1 == rule && $2 == "(v6)" && $3 == "ALLOW" && $4 == "IN" { v6=1 } END { exit !(v4 && v6) }' <<<"$status"; then
        printf 'PASS: UFW allows %s\n' "$rule"
      elif ((!ipv6_enabled)) && awk -v rule="$rule" \
          '$1 == rule && $2 == "ALLOW" && $3 == "IN" { found=1 } END { exit !found }' <<<"$status"; then
        printf 'PASS: UFW allows %s over IPv4\n' "$rule"
      else
        printf 'FAIL: UFW does not show an allow rule for %s\n' "$rule"
        failures=$((failures + 1))
      fi
    done <"$PORTS_FILE"
  elif [[ -r $PORTS_FILE ]]; then
    printf 'FAIL: saved UFW port rules cannot be checked because UFW is inactive\n'
    failures=$((failures + 1))
  else
    printf 'INFO: no saved port manifest; required inbound rules were not recorded by this script\n'
  fi

  if [[ -e $SSH_MARKER ]]; then
    local hardened_admin hardened_config
    hardened_admin=$(<"$SSH_MARKER")
    if [[ $hardened_admin =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*[$]?$ ]] && getent passwd "$hardened_admin" >/dev/null; then
      SSH_CONTEXT=$(ssh_context_spec "$hardened_admin" || true)
      if [[ -n $SSH_CONTEXT ]]; then
        hardened_config=$(sshd -T -C "$SSH_CONTEXT" 2>/dev/null || true)
      else
        hardened_config=
      fi
    else
      hardened_config=
    fi
    if [[ -z $SSH_CONTEXT ]]; then
      printf 'WARN: preserve SSH_CONNECTION when running --verify to check SSH Match rules for this connection.\n'
      failures=$((failures + 1))
    elif grep -qx 'permitrootlogin no' <<<"$hardened_config" && \
        grep -qx 'passwordauthentication no' <<<"$hardened_config" && \
        grep -qx 'kbdinteractiveauthentication no' <<<"$hardened_config"; then
      printf 'PASS: recorded SSH authentication hardening is effective\n'
    else
      printf 'FAIL: recorded SSH authentication hardening is not effective\n'
      failures=$((failures + 1))
    fi
  fi

  printf '\nLive network access cannot be verified from inside the VPS. Open a second terminal and test a new SSH connection before closing this one.\n'
  return "$failures"
}

external_firewall_detected() {
  if is_active firewalld.service || is_active nftables.service; then
    return 0
  fi
  if has_command docker; then
    return 0
  fi
  if dpkg-query -W -f='${Status}' iptables-persistent 2>/dev/null | grep -q 'install ok installed'; then
    return 0
  fi
  return 1
}

validate_port() {
  local port=$1
  [[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535))
}

prompt_ports() {
  local detected_port input rule port proto session_port
  local -a service_rules=()
  detected_port=$(get_ssh_port || true)

  if [[ -n $detected_port ]]; then
    read -r -p "Confirm current SSH TCP port [${detected_port}]: " input
    SSH_PORT=${input:-$detected_port}
  else
    read -r -p 'Enter current SSH TCP port: ' SSH_PORT
  fi
  validate_port "$SSH_PORT" || die 'SSH port must be a number from 1 to 65535.'
  SSH_PORT=$((10#$SSH_PORT))
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    session_port=$(awk '{print $4}' <<<"$SSH_CONNECTION")
    validate_port "$session_port" || die 'SSH_CONNECTION has an invalid server port.'
    session_port=$((10#$session_port))
    [[ $SSH_PORT == "$session_port" ]] || die "Entered SSH port does not match this session's server port ($session_port)."
  fi

  read -r -p 'Additional inbound ports (comma-separated, e.g. 80/tcp,443/tcp,51820/udp; blank for none): ' input
  input=${input//[[:space:]]/}
  if [[ -n $input ]]; then
    IFS=',' read -r -a service_rules <<<"$input"
    for rule in "${service_rules[@]}"; do
      if [[ ! $rule =~ ^([0-9]{1,5})/(tcp|udp)$ ]]; then
        die "Invalid port rule '$rule'; use PORT/tcp or PORT/udp."
      fi
      port=${BASH_REMATCH[1]}
      proto=${BASH_REMATCH[2]}
      validate_port "$port" || die "Invalid port in '$rule'."
      port=$((10#$port))
      FIREWALL_RULES+=("$port/$proto")
    done
  fi
  FIREWALL_RULES+=("$SSH_PORT/tcp")
}

make_backup() {
  BACKUP_DIR="/root/vps-hardening-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  install -d -m 0700 "$BACKUP_DIR"
  if [[ -d /etc/ufw ]]; then
    cp -a /etc/ufw "$BACKUP_DIR/ufw"
  fi
  if [[ -d /etc/ssh/sshd_config.d ]]; then
    cp -a /etc/ssh/sshd_config.d "$BACKUP_DIR/sshd_config.d"
  fi
  if [[ -d /etc/fail2ban ]]; then
    cp -a /etc/fail2ban "$BACKUP_DIR/fail2ban"
  fi
  if [[ -d /var/lib/vps-hardening ]]; then
    cp -a /var/lib/vps-hardening "$BACKUP_DIR/vps-hardening-state"
  fi
  if [[ -e $IDLE_TIMEOUT_FILE ]]; then
    cp -a "$IDLE_TIMEOUT_FILE" "$BACKUP_DIR/idle-timeout.before"
  fi
  printf 'Configuration backup: %s\n' "$BACKUP_DIR"
}

restore_ufw() {
  if [[ -d $UFW_BACKUP && -d /etc/ufw ]]; then
    cp -a "$UFW_BACKUP/." /etc/ufw/ || warn 'Could not fully restore the saved UFW files.'
  fi
  if ((UFW_WAS_ACTIVE)); then
    ufw reload || warn 'Could not reload the restored UFW rules.'
  else
    ufw disable || true
  fi
  ROLLBACK_UFW=0
}

restore_ssh() {
  if ((SSH_DROPIN_EXISTED)); then
    cp -a "$SSH_BACKUP_FILE" "$SSH_DROPIN" || warn 'Could not restore the original SSH drop-in.'
  else
    rm -f "$SSH_DROPIN"
  fi
  systemctl reload ssh.service || warn 'Could not reload SSH after restoring its configuration.'
  ROLLBACK_SSH=0
}

install_package() {
  local package=$1
  if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
    printf 'Installing %s (without a full system upgrade)...\n' "$package"
    (umask 022; apt-get update)
    (umask 022; DEBIAN_FRONTEND=noninteractive apt-get install -y "$package")
  fi
}

apply_firewall() {
  local was_active=0 rule response
  if has_command ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    was_active=1
  fi
  UFW_WAS_ACTIVE=$was_active

  printf '\nPlanned UFW allow rules:\n'
  printf '  %s\n' "${FIREWALL_RULES[@]}"
  if ((was_active)); then
    printf 'UFW is already active; existing defaults and rules will be preserved.\n'
  else
    printf 'UFW is inactive; the plan is default-deny inbound, allow outbound, then enable UFW.\n'
  fi
  read -r -p 'Type APPLY-FIREWALL to continue: ' response
  [[ $response == APPLY-FIREWALL ]] || die 'Firewall changes cancelled.'

  install_package ufw
  UFW_BACKUP="$BACKUP_DIR/ufw-before-apply"
  [[ -d /etc/ufw ]] && cp -a /etc/ufw "$UFW_BACKUP"
  if grep -Eq '^IPV6="?no"?$' /etc/default/ufw 2>/dev/null; then
    die 'UFW IPv6 filtering is disabled. No firewall rules were changed; review IPv6 policy before proceeding.'
  fi

  ROLLBACK_UFW=1
  for rule in "${FIREWALL_RULES[@]}"; do
    if ! ufw allow "$rule" comment 'vps-hardening'; then
      restore_ufw
      die "Could not add UFW allow rule for $rule. Backup: $UFW_BACKUP"
    fi
  done

  if ((!was_active)); then
    if ! ufw default deny incoming || ! ufw default allow outgoing; then
      restore_ufw
      die "Could not set UFW defaults; previous UFW configuration was restored. Backup: $UFW_BACKUP"
    fi
    ufw --force enable || {
      restore_ufw
      die "UFW could not be enabled; previous UFW configuration was restored. Backup: $UFW_BACKUP"
    }
  fi
  printf '\nKeep this SSH session open and test a second SSH login now.\n'
  read -r -p 'Did the separate SSH login succeed? [y/N]: ' response || response=
  if [[ ! $response =~ ^[Yy]$ ]]; then
    restore_ufw
    die "Separate SSH login was not confirmed; previous UFW configuration was restored. Backup: $UFW_BACKUP"
  fi
  ROLLBACK_UFW=0
  ufw status verbose

  install -d -m 0750 "${PORTS_FILE%/*}"
  local manifest_tmp
  manifest_tmp=$(mktemp "${PORTS_FILE}.XXXXXX")
  {
    [[ -r $PORTS_FILE ]] && cat "$PORTS_FILE"
    printf '%s\n' "${FIREWALL_RULES[@]}"
  } | awk 'NF && !seen[$0]++' | sort -V >"$manifest_tmp"
  chmod 0640 "$manifest_tmp"
  mv -f "$manifest_tmp" "$PORTS_FILE"
}

apply_ssh_hardening() {
  local admin=${SUDO_USER:-}
  local admin_home effective_config
  local existed=0 response tmp

  has_command sshd || die 'sshd is required for SSH hardening.'
  [[ -n $admin && $admin != root ]] || die 'SSH hardening requires running under sudo from a non-root admin account.'
  [[ $admin =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*[$]?$ ]] || die 'The sudo account name cannot be safely used in an SSH connection check.'
  getent passwd "$admin" >/dev/null || die "Cannot resolve sudo user '$admin'."
  id -nG "$admin" | tr ' ' '\n' | grep -qx sudo || die "User '$admin' is not in the sudo group."
  admin_home=$(getent passwd "$admin" | cut -d: -f6)
  if [[ -s $admin_home/.ssh/authorized_keys ]]; then
    local key_owner key_mode ssh_dir_owner ssh_dir_mode
    key_owner=$(stat -c '%U' "$admin_home/.ssh/authorized_keys")
    key_mode=$(stat -c '%a' "$admin_home/.ssh/authorized_keys")
    if [[ $key_owner != "$admin" && $key_owner != root ]]; then
      warn "authorized_keys is owned by $key_owner, not $admin or root."
    fi
    if find "$admin_home/.ssh/authorized_keys" -maxdepth 0 -perm /022 -print -quit | grep -q .; then
      warn 'authorized_keys is group- or world-writable.'
    fi
    printf 'Key metadata (contents not shown): authorized_keys owner=%s mode=%s\n' "$key_owner" "$key_mode"
    if [[ -d $admin_home/.ssh ]]; then
      ssh_dir_owner=$(stat -c '%U' "$admin_home/.ssh")
      ssh_dir_mode=$(stat -c '%a' "$admin_home/.ssh")
      printf '.ssh metadata: owner=%s mode=%s\n' "$ssh_dir_owner" "$ssh_dir_mode"
      if [[ $ssh_dir_owner != "$admin" && $ssh_dir_owner != root ]] || \
          find "$admin_home/.ssh" -maxdepth 0 -perm /022 -print -quit | grep -q .; then
        warn '.ssh directory ownership or permissions may prevent key authentication.'
      fi
    fi
  else
    warn "No authorized_keys file found for $admin; confirm the actual key login works before continuing."
  fi
  SSH_CONTEXT=$(ssh_context_spec "$admin") || die 'Could not determine the current SSH connection context. Run with SSH_CONNECTION preserved through sudo.'
  [[ ${SSH_CONTEXT##*lport=} == "$SSH_PORT" ]] || die 'SSH connection context does not match the port selected for UFW.'
  effective_config=$(sshd -T -C "$SSH_CONTEXT" 2>/dev/null) || die 'Could not inspect effective SSH settings for this connection.'
  grep -qx 'pubkeyauthentication yes' <<<"$effective_config" || die 'Public-key authentication is not enabled for this connection; SSH hardening was not applied.'

  printf '\nThis disables root, password, and keyboard-interactive SSH login.\n'
  printf 'This authentication change is global; every SSH user who needs access must have a working key.\n'
  printf 'It may break PAM-based one-time-code or other keyboard-interactive authentication.\n'
  printf 'It can lock you out if key authentication and sudo are not already tested in a second session.\n'
  read -r -p 'Type DISABLE-SSH-PASSWORDS only after a successful separate key login with sudo: ' response || response=
  [[ $response == DISABLE-SSH-PASSWORDS ]] || {
    printf 'SSH authentication settings were left unchanged.\n'
    return
  }

  mkdir -p /etc/ssh/sshd_config.d
  if [[ -e $SSH_DROPIN ]]; then
    cp -a "$SSH_DROPIN" "$BACKUP_DIR/00-vps-hardening.conf.before"
    SSH_BACKUP_FILE="$BACKUP_DIR/00-vps-hardening.conf.before"
    existed=1
  fi
  SSH_DROPIN_EXISTED=$existed
  ROLLBACK_SSH=1
  tmp=$(mktemp /etc/ssh/sshd_config.d/.vps-hardening.XXXXXX)
  cat >"$tmp" <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$SSH_DROPIN"

  effective_config=$(sshd -T -C "$SSH_CONTEXT" 2>/dev/null || true)
  if ! sshd -t || ! grep -qx 'permitrootlogin no' <<<"$effective_config" || \
      ! grep -qx 'passwordauthentication no' <<<"$effective_config" || \
      ! grep -qx 'kbdinteractiveauthentication no' <<<"$effective_config"; then
    restore_ssh
    die 'SSH hardening failed validation; previous drop-in was restored.'
  fi

  if ! systemctl reload ssh.service; then
    restore_ssh
    die 'SSH reload failed; previous drop-in was restored.'
  fi
  printf 'SSH settings applied and configuration validated. Keep this session open.\n'
  read -r -p 'Did a separate SSH key login and sudo command succeed after this change? [y/N]: ' response || response=
  if [[ ! $response =~ ^[Yy]$ ]]; then
    restore_ssh
    die 'Separate SSH key login was not confirmed; previous SSH configuration was restored.'
  fi
  install -d -m 0750 "${SSH_MARKER%/*}"
  printf '%s\n' "$admin" >"$SSH_MARKER"
  ROLLBACK_SSH=0
}

restore_fail2ban_config() {
  local jail=$1 existed=$2 backup_file=$3
  if ((existed)); then
    cp -a "$backup_file" "$jail" || warn 'Could not restore the previous Fail2ban jail file.'
  else
    rm -f "$jail"
  fi
  systemctl restart fail2ban.service || true
}

apply_fail2ban() {
  local jail=/etc/fail2ban/jail.d/00-vps-hardening.conf
  local existed=0 tmp backup_file="$BACKUP_DIR/00-vps-hardening-fail2ban.conf.before"
  install_package fail2ban
  if [[ -e $jail ]]; then
    cp -a "$jail" "$backup_file"
    existed=1
  fi
  install -d -m 0755 /etc/fail2ban/jail.d
  tmp=$(mktemp /etc/fail2ban/jail.d/.vps-hardening.XXXXXX)
  cat >"$tmp" <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$jail"
  if ! systemctl enable fail2ban.service || ! systemctl restart fail2ban.service; then
    printf 'Fail2ban enable/restart failed; diagnostic status follows.\n' >&2
    systemctl --no-pager --full status fail2ban.service || true
    fail2ban-client status || true
    restore_fail2ban_config "$jail" "$existed" "$backup_file"
    die 'Fail2ban could not be enabled or restarted; previous jail config was restored.'
  fi
  if ! wait_for_fail2ban_sshd_jail; then
    printf 'Fail2ban started, but its global status did not list the sshd jail. Diagnostic status follows.\n' >&2
    systemctl --no-pager --full status fail2ban.service || true
    fail2ban-client status || true
    restore_fail2ban_config "$jail" "$existed" "$backup_file"
    die 'Fail2ban SSH jail did not become active; previous jail config was restored.'
  fi
  printf 'Fail2ban SSH jail is enabled (5 failures in 10 minutes, 1-hour ban).\n'
}

apply_idle_timeout() {
  local tmp
  install -d -m 0755 "${IDLE_TIMEOUT_FILE%/*}"
  tmp=$(mktemp "${IDLE_TIMEOUT_FILE%/*}/.vps-idle-timeout.XXXXXX")
  cat >"$tmp" <<'EOF'
if [ -n "${BASH_VERSION:-}" ]; then
  case $- in
    *i*)
      TMOUT=900
      readonly TMOUT
      export TMOUT
      ;;
  esac
fi
EOF
  chmod 0644 "$tmp"
  mv -f "$tmp" "$IDLE_TIMEOUT_FILE"
  printf 'Installed a 15-minute idle timeout for new interactive Bash logins; this existing shell is unchanged.\n'
}

run_apply() {
  local response timeout_configs

  show_inventory
  timeout_configs=$(idle_timeout_conflicts)
  [[ -z $timeout_configs ]] || die "Existing TMOUT settings found; review before applying: $timeout_configs"
  external_firewall_detected && die 'Docker or another firewall manager was detected. No changes were made; review that firewall separately.'
  printf '\nBefore changing remote access, confirm you can reach your provider console or rescue environment if SSH stops working.\n'
  read -r -p 'Type CONSOLE-READY only if that recovery path is available: ' response || response=
  [[ $response == CONSOLE-READY ]] || die 'Recovery access was not confirmed; no changes were made.'
  if ((HARDEN_SSH || WITH_FAIL2BAN)) && ! has_command sshd; then
    die 'sshd is required for the requested SSH hardening or Fail2ban jail.'
  fi
  prompt_ports

  printf '\nPlanned changes:\n'
  printf '  - Allow SSH on %s/tcp and the listed service ports.\n' "$SSH_PORT"
  printf '  - SSH is not source-IP restricted; the allowed port remains reachable from any source.\n'
  printf '  - Install UFW/dependencies if missing; no full system upgrade.\n'
  printf '  - Preserve active UFW policy; otherwise enable UFW with inbound deny/outbound allow defaults.\n'
  printf '  - Do not change SSH authentication unless --harden-ssh is provided and separately confirmed.\n'
  if ((HARDEN_SSH)); then
    printf '  - Optional SSH drop-in: PermitRootLogin no, PasswordAuthentication no, KbdInteractiveAuthentication no.\n'
  fi
  printf '  - Do not run a full package upgrade or reboot.\n'
  printf '  - Set a 15-minute timeout for idle interactive Bash prompts.\n'
  if ((WITH_FAIL2BAN)); then
    printf '  - Install Fail2ban with an SSH jail (5 failures/10 minutes, 1-hour ban).\n'
  else
    printf '  - Skip Fail2ban installation.\n'
  fi
  read -r -p 'Type APPLY to proceed: ' response
  [[ $response == APPLY ]] || die 'No changes made.'

  make_backup
  apply_firewall
  if ((HARDEN_SSH)); then
    apply_ssh_hardening
  fi
  if ((WITH_FAIL2BAN)); then
    apply_fail2ban
  fi
  apply_idle_timeout

  printf '\nChanges complete. Backup directory: %s\n' "$BACKUP_DIR"
  verify_server || warn 'One or more verification checks need attention.'
}

while (($#)); do
  case $1 in
    --check)
      [[ -z $MODE || $MODE == check ]] || die 'Choose only one mode.'
      MODE=check
      ;;
    --verify)
      [[ -z $MODE || $MODE == verify ]] || die 'Choose only one mode.'
      MODE=verify
      ;;
    --apply)
      [[ -z $MODE || $MODE == apply ]] || die 'Choose only one mode.'
      MODE=apply
      ;;
    --harden-ssh)
      HARDEN_SSH=1
      ;;
    --no-fail2ban)
      WITH_FAIL2BAN=0
      FAIL2BAN_OPTION_SET=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help)."
      ;;
  esac
  shift
done

MODE=${MODE:-check}

is_ubuntu
require_root
if ((HARDEN_SSH)) && [[ $MODE != apply ]]; then
  die '--harden-ssh requires --apply.'
fi
if ((FAIL2BAN_OPTION_SET)) && [[ $MODE == check ]]; then
  die '--no-fail2ban requires --apply or --verify.'
fi
if [[ $MODE == apply ]]; then
  [[ -t 0 ]] || die '--apply requires an interactive terminal.'
  acquire_apply_lock
fi

case $MODE in
  check)
    show_inventory
    ;;
  verify)
    verify_server
    ;;
  apply)
    run_apply
    ;;
esac