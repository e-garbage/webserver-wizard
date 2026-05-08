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

detect_ftp_users() {
  awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' /etc/passwd 2>/dev/null | grep -E "^ftp" || true
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

get_ftp_username() {
  read -p "FTP username (alphanumeric, 3-16 chars): " username >&2

  if ! [[ "$username" =~ ^[a-zA-Z0-9]{3,16}$ ]]; then
    log error "Invalid username format (must be 3-16 alphanumeric characters)"
    get_ftp_username
    return
  fi

  if id "$username" &>/dev/null; then
    log error "User '$username' already exists"
    get_ftp_username
    return
  fi

  echo "$username"
}

get_ftp_password() {
  read -sp "FTP password: " password >&2
  echo "" >&2

  if [[ -z "$password" ]]; then
    log error "Password cannot be empty"
    get_ftp_password
    return
  fi

  echo "$password"
}

get_passive_port_range() {
  read -p "Passive port range start (default: 50000): " port_start >&2
  port_start=${port_start:-50000}

  if ! [[ "$port_start" =~ ^[0-9]+$ ]] || [[ $port_start -lt 1024 ]] || [[ $port_start -gt 65435 ]]; then
    log error "Invalid port number (must be 1024-65435)"
    get_passive_port_range
    return
  fi

  echo "$port_start"
}

confirm_all_changes() {
  local domain=$1
  local username=$2
  local port_start=$3
  local port_end=$((port_start + 100))

  echo "" >&2
  log info "Summary"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "Domain: $domain" >&2
  echo "FTP Username: $username" >&2
  echo "Home Directory: /var/www/$domain" >&2
  echo "Access: Chroot jail (restricted to domain folder)" >&2
  echo "FTP Control Port: 21/tcp" >&2
  echo "Passive Port Range: $port_start-$port_end/tcp" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "" >&2
  read -p "Proceed with FTP user creation? (yes/no): " confirm >&2

  if [[ ! "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    log error "Setup cancelled"
    exit 0
  fi
}

install_vsftpd() {
  if is_installed "vsftpd"; then
    log success "vsftpd is already installed"
    return 0
  fi

  log info "Installing vsftpd..."
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y vsftpd
  systemctl enable vsftpd
  systemctl start vsftpd

  log success "vsftpd installed and started"
}

create_ftp_user() {
  local username=$1
  local domain=$2
  local password=$3
  local homedir="/var/www/$domain"

  log info "Creating FTP user '$username'..."

  useradd -m -d "$homedir" -s /sbin/nologin "$username"
  echo "$username:$password" | chpasswd

  chown root:root "$homedir"
  chmod 755 "$homedir"

  log success "FTP user '$username' created with home directory $homedir"
}

configure_vsftpd() {
  local username=$1
  local port_start=$2
  local port_end=$((port_start + 100))

  log info "Configuring vsftpd..."

  local backup_file="/etc/vsftpd.conf.backup.$(date +%s)"
  cp /etc/vsftpd.conf "$backup_file"
  log success "Backed up vsftpd.conf to $backup_file"

  cat >> /etc/vsftpd.conf <<EOF

# Configuration for FTP user: $username
# Added: $(date)
local_enable=YES
write_enable=YES
chroot_local_user=YES
allow_writeable_chroot=YES
pasv_enable=YES
pasv_min_port=$port_start
pasv_max_port=$port_end
user_sub_token=\$USER
local_root=/var/www/\$USER
EOF

  vsftpd -v /etc/vsftpd.conf > /dev/null 2>&1 && log success "vsftpd configuration validated" || {
    log error "vsftpd configuration validation failed"
    cp "$backup_file" /etc/vsftpd.conf
    return 1
  }

  systemctl reload vsftpd
  log success "vsftpd reloaded"
}

setup_ftp_firewall() {
  local port_start=$1
  local port_end=$((port_start + 100))

  log info "Configuring firewall..."

  if ! command -v ufw &> /dev/null; then
    log info "Installing UFW..."
    apt install -y ufw
  fi

  ufw allow 21/tcp 2>/dev/null || true
  ufw allow "$port_start:$port_end/tcp" 2>/dev/null || true

  log success "UFW: Allowed port 21/tcp and $port_start:$port_end/tcp"
}

show_status() {
  local username=$1
  local domain=$2
  local port_start=$3
  local server_ip=$(hostname -I | awk '{print $1}')

  echo "" >&2
  log success "FTP User Created Successfully!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "FTP Connection Details:" >&2
  echo "  Host: $server_ip" >&2
  echo "  Username: $username" >&2
  echo "  Home Directory: /var/www/$domain" >&2
  echo "  Passive Port Range: $port_start-$((port_start + 100))" >&2
  echo "" >&2
  echo "Useful commands:" >&2
  echo "  • List FTP users: sudo awk -F: '\$3 >= 1000 {print \$1}' /etc/passwd | grep ftp" >&2
  echo "  • Delete FTP user: sudo userdel -r '$username'" >&2
  echo "  • View vsftpd logs: sudo tail -f /var/log/vsftpd.log" >&2
  echo "  • Reload vsftpd: sudo systemctl reload vsftpd" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
}

select_existing_ftp_user() {
  local ftp_users
  mapfile -t ftp_users < <(detect_ftp_users)

  if [[ ${#ftp_users[@]} -eq 0 ]]; then
    log error "No FTP users found"
    return 1
  fi

  echo "" >&2
  log info "Existing FTP users:"
  for ((i=0; i<${#ftp_users[@]}; i++)); do
    echo "$((i+1))) ${ftp_users[$i]}" >&2
  done

  read -p "Select user (1-${#ftp_users[@]}): " choice >&2

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#ftp_users[@]} ]]; then
    log error "Invalid selection"
    select_existing_ftp_user
    return
  fi

  echo "${ftp_users[$((choice-1))]}"
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

  log info "Updating vsftpd configuration..."

  local backup_file="/etc/vsftpd.conf.backup.$(date +%s)"
  cp /etc/vsftpd.conf "$backup_file"
  log success "Backed up vsftpd.conf to $backup_file"

  sed -i "/^# Configuration for FTP user: $username/,/^local_root/d" /etc/vsftpd.conf
  sed -i "/user_sub_token=/d" /etc/vsftpd.conf

  cat >> /etc/vsftpd.conf <<EOF

# Configuration for FTP user: $username
# Modified: $(date)
user_sub_token=\$USER
local_root=/var/www/\$USER
EOF

  vsftpd -v /etc/vsftpd.conf > /dev/null 2>&1 && log success "vsftpd configuration validated" || {
    log error "vsftpd configuration validation failed"
    cp "$backup_file" /etc/vsftpd.conf
    return 1
  }

  chown root:root "/var/www/$domain"
  chmod 755 "/var/www/$domain"

  systemctl reload vsftpd
  log success "User '$username' now has access to $domain"
}

delete_ftp_user() {
  local username=$1

  log info "Deleting FTP user '$username'..."

  local user_home
  user_home=$(getent passwd "$username" | cut -d: -f6)

  echo "" >&2
  log warn "Confirm deletion:"
  echo "  Username: $username" >&2
  echo "  Home Directory: $user_home" >&2
  echo "" >&2
  read -p "Delete this user? (yes/no): " confirm >&2

  if [[ ! "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    log error "Deletion cancelled"
    return 0
  fi

  userdel -r "$username" 2>/dev/null || log warn "Failed to completely remove user files"

  log info "Cleaning up vsftpd configuration..."
  sed -i "/^# Configuration for FTP user: $username/,/^local_root/d" /etc/vsftpd.conf

  vsftpd -v /etc/vsftpd.conf > /dev/null 2>&1 && log success "vsftpd configuration validated" || {
    log error "vsftpd configuration validation failed"
    return 1
  }

  systemctl reload vsftpd
  log success "FTP user '$username' deleted successfully"
}

select_operation() {
  echo "" >&2
  log info "FTP Account Manager"
  echo "1) Create new FTP user" >&2
  echo "2) Modify user's website access" >&2
  echo "3) Delete FTP user" >&2
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

  log info "Create New FTP User"

  local domain
  domain=$(select_website "$webserver")

  if [[ ! -d "/var/www/$domain" ]]; then
    log error "Domain folder /var/www/$domain not found"
    return 1
  fi

  local username
  username=$(get_ftp_username)

  local password
  password=$(get_ftp_password)

  local port_start
  port_start=$(get_passive_port_range)

  confirm_all_changes "$domain" "$username" "$port_start"

  install_vsftpd
  create_ftp_user "$username" "$domain" "$password"
  configure_vsftpd "$username" "$port_start"
  setup_ftp_firewall "$port_start"

  show_status "$username" "$domain" "$port_start"
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
  log info "FTP Account Manager"
  echo "" >&2

  local webserver
  webserver=$(detect_webserver)

  if [[ -z "$webserver" ]]; then
    log error "No webserver detected (nginx or apache2 required)"
    exit 1
  fi

  log success "Detected webserver: $webserver"

  local existing_ftp_users
  existing_ftp_users=$(detect_ftp_users)
  if [[ -n "$existing_ftp_users" ]]; then
    echo "" >&2
    log info "Existing FTP users: $(echo "$existing_ftp_users" | tr '\n' ', ' | sed 's/,$//')"
  fi

  local operation
  operation=$(select_operation)

  case $operation in
    create)
      create_new_user "$webserver"
      ;;
    modify)
      local username
      username=$(select_existing_ftp_user) || exit 1
      modify_user_access "$webserver" "$username"
      ;;
    delete)
      local username
      username=$(select_existing_ftp_user) || exit 1
      delete_ftp_user "$username"
      ;;
  esac
}

main "$@"
