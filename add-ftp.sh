#!/bin/bash
set -euo pipefail

COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[1;33m'
COLOR_RESET='\033[0m'

log() {
  local type=$1
  shift
  case "$type" in
    success) echo -e "${COLOR_GREEN}✓${COLOR_RESET} $*" >&2 ;;
    error)   echo -e "${COLOR_RED}✗${COLOR_RESET} $*" >&2 ;;
    info)    echo -e "${COLOR_BLUE}→${COLOR_RESET} $*" >&2 ;;
    warn)    echo -e "${COLOR_YELLOW}!${COLOR_RESET} $*" >&2 ;;
    *)       echo "$*" >&2 ;;
  esac
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    log error "This script must be run as root (use: sudo $0)"
    exit 1
  fi
}

is_installed() {
  dpkg -s "$1" 2>/dev/null | grep -q "Status: install ok installed"
}

detect_webserver() {
  if is_installed "nginx"; then
    echo "nginx"
  elif is_installed "apache2"; then
    echo "apache2"
  else
    echo ""
  fi
}

detect_websites() {
  local webserver=$1

  if [[ "$webserver" == "nginx" ]]; then
    if [[ -d /etc/nginx/sites-enabled ]]; then
      find /etc/nginx/sites-enabled -type l 2>/dev/null | while read -r file; do
        basename "$file"
      done
    fi
  elif [[ "$webserver" == "apache2" ]]; then
    if [[ -d /etc/apache2/sites-enabled ]]; then
      find /etc/apache2/sites-enabled -type l -name "*.conf" 2>/dev/null | while read -r file; do
        basename "$file" .conf
      done
    fi
  fi | sort -u
}

detect_sftp_users() {
  if getent group sftpusers >/dev/null 2>&1; then
    getent group sftpusers | cut -d: -f4 | tr ',' '\n' | sort -u || true
  else
    awk -F: '$3 >= 1000 && $3 != 65534 && $7 ~ "nologin$" {print $1}' /etc/passwd 2>/dev/null || true
  fi
}

select_website() {
  local webserver=$1
  local websites
  mapfile -t websites < <(detect_websites "$webserver") 2>/dev/null || true

  if [[ ${#websites[@]} -eq 0 ]]; then
    log error "No websites detected"
    exit 1
  fi

  echo "" >&2
  log info "Available websites:"
  for ((i=0; i<${#websites[@]}; i++)); do
    echo "$((i+1))) ${websites[$i]}" >&2
  done

  read -p "Select website (1-${#websites[@]}): " choice >&2

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#websites[@]} ]]; then
    log error "Invalid selection"
    select_website "$webserver"
    return
  fi

  echo "${websites[$((choice-1))]}"
}

get_sftp_username() {
  read -p "SFTP username (alphanumeric, 3-16 chars): " username >&2

  if ! [[ "$username" =~ ^[a-zA-Z0-9]{3,16}$ ]]; then
    log error "Invalid username format (must be 3-16 alphanumeric characters)"
    get_sftp_username
    return
  fi

  if id "$username" &>/dev/null; then
    log error "User '$username' already exists"
    get_sftp_username
    return
  fi

  echo "$username"
}

get_sftp_password() {
  read -sp "SFTP password: " password >&2
  echo "" >&2

  if [[ -z "$password" ]]; then
    log error "Password cannot be empty"
    get_sftp_password
    return
  fi

  echo "$password"
}

confirm_all_changes() {
  local domain=$1
  local username=$2

  echo "" >&2
  log info "Summary"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "Domain: $domain" >&2
  echo "SFTP Username: $username" >&2
  echo "Chroot Directory: /var/www/$domain" >&2
  echo "SFTP Home: /$username" >&2
  echo "SSH Port: 22/tcp" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "" >&2
  read -p "Proceed with SFTP user creation? (yes/no): " confirm >&2

  if [[ ! "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    log error "Setup cancelled"
    exit 0
  fi
}

install_openssh_server() {
  if is_installed "openssh-server"; then
    log success "OpenSSH server is already installed"
    return 0
  fi

  log info "Installing OpenSSH server..."
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y openssh-server
  systemctl enable ssh
  systemctl start ssh

  log success "OpenSSH server installed and started"
}

ensure_sftp_group() {
  if ! getent group sftpusers >/dev/null 2>&1; then
    groupadd sftpusers
    log success "Created sftpusers group"
  fi
}

ensure_sshd_include_dir() {
  if [[ -d /etc/ssh/sshd_config.d ]] && grep -q '^Include /etc/ssh/sshd_config.d/\*' /etc/ssh/sshd_config 2>/dev/null; then
    return 0
  fi

  mkdir -p /etc/ssh/sshd_config.d
  if ! grep -q '^Include /etc/ssh/sshd_config.d/\*' /etc/ssh/sshd_config 2>/dev/null; then
    echo -e "\nInclude /etc/ssh/sshd_config.d/*" >> /etc/ssh/sshd_config
  fi
}

configure_sshd_base() {
  ensure_sshd_include_dir

  local config_file="/etc/ssh/sshd_config.d/00-sftp-subsystem.conf"
  if ! grep -q '^Subsystem sftp internal-sftp' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
    cat > "$config_file" <<EOF
# Managed by webserver-wizard - SFTP subsystem definition
Subsystem sftp internal-sftp -f SYSLOG -l INFO
EOF
    log success "Created SFTP subsystem configuration"
  fi
}

validate_sshd_config() {
  sshd -t >/dev/null 2>&1 || {
    log error "sshd configuration validation failed"
    return 1
  }
}

create_sftp_user() {
  local username=$1
  local domain=$2
  local password=$3
  local domain_dir="/var/www/$domain"
  local user_dir="$domain_dir/$username"

  log info "Creating SFTP user '$username'..."

  mkdir -p "$domain_dir"
  chown root:root "$domain_dir"
  chmod 755 "$domain_dir"

  useradd -M -d "/$username" -s /usr/sbin/nologin -G sftpusers -c "SFTP access to $domain" "$username"
  echo "$username:$password" | chpasswd

  mkdir -p "$user_dir"
  chown "$username:sftpusers" "$user_dir"
  chmod 755 "$user_dir"

  local config_file="/etc/ssh/sshd_config.d/sftp-$username.conf"
  cat > "$config_file" <<EOF
# SFTP chroot for user $username
# Managed by webserver-wizard
Match User $username
    ChrootDirectory $domain_dir
    ForceCommand internal-sftp
    AllowTcpForwarding no
    AllowAgentForwarding no
    PermitTTY no
    X11Forwarding no
EOF

  validate_sshd_config || {
    log error "SSH config validation failed for user $username"
    rm -f "$config_file"
    userdel "$username" 2>/dev/null || true
    return 1
  }

  systemctl reload ssh

  log success "SFTP user '$username' created and chrooted to $domain_dir"
}

setup_sftp_firewall() {
  log info "Configuring firewall..."

  if ! command -v ufw &> /dev/null; then
    log info "Installing UFW..."
    apt install -y ufw
  fi

  ufw allow 22/tcp 2>/dev/null || true
  log success "UFW: Allowed port 22/tcp"
}
show_status() {
  local username=$1
  local domain=$2
  local server_ip=$(hostname -I | awk '{print $1}')

  echo "" >&2
  log success "SFTP User Created Successfully!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "SFTP Connection Details:" >&2
  echo "  Host: $server_ip" >&2
  echo "  Username: $username" >&2
  echo "  SFTP Home: /$username" >&2
  echo "  Chroot Directory: /var/www/$domain" >&2
  echo "" >&2
  echo "Useful commands:" >&2
  echo "  • List SFTP users: sudo getent group sftpusers | cut -d: -f4 | tr ',' '\n'" >&2
  echo "  • Delete SFTP user: sudo userdel '$username'" >&2
  echo "  • View SSH logs: sudo tail -f /var/log/auth.log | grep sshd" >&2
  echo "  • Reload SSH: sudo systemctl reload ssh" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
}

select_existing_sftp_user() {
  local sftp_users
  mapfile -t sftp_users < <(detect_sftp_users)

  if [[ ${#sftp_users[@]} -eq 0 ]]; then
    log error "No SFTP users found"
    return 1
  fi

  echo "" >&2
  log info "Existing SFTP users:"
  for ((i=0; i<${#sftp_users[@]}; i++)); do
    echo "$((i+1))) ${sftp_users[$i]}" >&2
  done

  read -p "Select user (1-${#sftp_users[@]}): " choice >&2

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#sftp_users[@]} ]]; then
    log error "Invalid selection"
    select_existing_sftp_user
    return
  fi

  echo "${sftp_users[$((choice-1))]}"
}

modify_user_access() {
  local webserver=$1
  local username=$2

  log info "Modifying access for user '$username'..."

  local domain
  domain=$(select_website "$webserver")

  if [[ ! -d "/var/www/$domain" ]]; then
    log error "Domain folder /var/www/$domain not found"
    return 1
  fi

  local domain_dir="/var/www/$domain"

  log info "Updating SFTP configuration for '$username'..."
  mkdir -p "$domain_dir"
  chown root:root "$domain_dir"
  chmod 755 "$domain_dir"

  mkdir -p "$domain_dir/$username"
  chown "$username:sftpusers" "$domain_dir/$username"
  chmod 755 "$domain_dir/$username"

  local config_file="/etc/ssh/sshd_config.d/sftp-$username.conf"
  cat > "$config_file" <<EOF
# SFTP chroot for user $username
# Managed by webserver-wizard
Match User $username
    ChrootDirectory $domain_dir
    ForceCommand internal-sftp
    AllowTcpForwarding no
    AllowAgentForwarding no
    PermitTTY no
    X11Forwarding no
EOF

  validate_sshd_config
  systemctl reload ssh
  log success "User '$username' now has access to $domain"
}

delete_sftp_user() {
  local username=$1

  log info "Deleting SFTP user '$username'..."

  local config_file="/etc/ssh/sshd_config.d/sftp-$username.conf"
  local chroot_dir=""

  if [[ -f "$config_file" ]]; then
    chroot_dir=$(grep -i 'ChrootDirectory' "$config_file" | awk '{print $2}')
  fi

  local user_home
  user_home=$(getent passwd "$username" | cut -d: -f6)

  echo "" >&2
  log warn "Confirm deletion:"
  echo "  Username: $username" >&2
  echo "  Home Directory: $user_home" >&2
  if [[ -n "$chroot_dir" ]]; then
    echo "  Chroot Directory: $chroot_dir" >&2
  fi
  echo "" >&2
  read -p "Delete this user? (yes/no): " confirm >&2

  if [[ ! "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    log error "Deletion cancelled"
    return 0
  fi

  userdel "$username" 2>/dev/null || log warn "Failed to remove user account"
  rm -f "$config_file"

  if [[ -n "$chroot_dir" ]]; then
    rm -rf "$chroot_dir/$username" || true
  fi

  validate_sshd_config
  systemctl reload ssh
  log success "SFTP user '$username' deleted successfully"
}

select_operation() {
  echo "" >&2
  log info "SFTP Account Manager"
  echo "1) Create new SFTP user" >&2
  echo "2) Modify user's website access" >&2
  echo "3) Delete SFTP user" >&2
  echo "" >&2
  read -p "Select operation (1-3): " choice >&2

  case $choice in
    1) echo "create" ;;
    2) echo "modify" ;;
    3) echo "delete" ;;
    *) log error "Invalid choice"; select_operation ;;
  esac
}

create_new_user() {
  local webserver=$1

  log info "Create New SFTP User"

  local domain
  domain=$(select_website "$webserver")

  if [[ ! -d "/var/www/$domain" ]]; then
    log error "Domain folder /var/www/$domain not found"
    return 1
  fi

  local username
  username=$(get_sftp_username)

  local password
  password=$(get_sftp_password)

  confirm_all_changes "$domain" "$username"

  install_openssh_server
  ensure_sftp_group
  configure_sshd_base
  create_sftp_user "$username" "$domain" "$password"
  setup_sftp_firewall

  show_status "$username" "$domain"
}

ascii_art(){
    echo -e "${COLOR_RED}"
    echo "░█▀█░█▀▄░█▀▄░░░░░█▀▀░█░█░█▀▀░█░█░▀█▀░█░█░█▀▀░█▀█░█▀█░█░░░▀█▀░█▀▀░█▀▀░░░░█▀▀░█░█"
    echo "░█▀█░█░█░█░█░▄▄▄░█▀▀░█░█░█░░░█▀▄░░█░░█▀█░█▀▀░█▀▀░█░█░█░░░░█░░█░░░█▀▀░░░░▀▀█░█▀█"
    echo "░▀░▀░▀▀░░▀▀░░░░░░▀░░░▀▀▀░▀▀▀░▀░▀░░▀░░▀░▀░▀▀▀░▀░░░▀▀▀░▀▀▀░▀▀▀░▀▀▀░▀▀▀░▀░░▀▀▀░▀░▀"
    echo -e "${COLOR_RESET}"
}

main() {
  require_root
  ascii_art
  log info "SFTP Account Manager"
  echo "" >&2

  local webserver
  webserver=$(detect_webserver)

  if [[ -z "$webserver" ]]; then
    log error "No webserver detected (nginx or apache2 required)"
    exit 1
  fi

  log success "Detected webserver: $webserver"

  local existing_sftp_users
  existing_sftp_users=$(detect_sftp_users)
  if [[ -n "$existing_sftp_users" ]]; then
    echo "" >&2
    log info "Existing SFTP users: $(echo "$existing_sftp_users" | tr '\n' ', ' | sed 's/,$//')"
  fi

  local operation
  operation=$(select_operation)

  case $operation in
    create)
      create_new_user "$webserver"
      ;;
    modify)
      local username
      username=$(select_existing_sftp_user) || exit 1
      modify_user_access "$webserver" "$username"
      ;;
    delete)
      local username
      username=$(select_existing_sftp_user) || exit 1
      delete_sftp_user "$username"
      ;;
  esac
}

main "$@"
