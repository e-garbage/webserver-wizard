#!/bin/bash
set -euo pipefail

COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_BLUE='\033[0;34m'
COLOR_YELLOW='\033[1;33m'
COLOR_RESET='\033[0m'

SSH_PORT="22"
SSH_HARDENING_FILE="/etc/ssh/sshd_config.d/00-webserver-wizard.conf"

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

ask_yes_no() {
  # ask_yes_no "question" default(y|n) -> returns 0 for yes
  local question=$1 default=$2 answer hint="[y/N]"
  [[ "$default" == "y" ]] && hint="[Y/n]"
  read -p "$question $hint " answer
  answer=${answer:-$default}
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
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

detect_existing_sites() {
  local webserver=$1

  if [[ "$webserver" == "nginx" ]]; then
    if [[ -d /etc/nginx/sites-enabled ]]; then
      find /etc/nginx/sites-enabled -type l 2>/dev/null | while IFS= read -r file; do
        basename "$file"
      done
    fi
  elif [[ "$webserver" == "apache2" ]]; then
    if [[ -d /etc/apache2/sites-enabled ]]; then
      find /etc/apache2/sites-enabled -type l -name "*.conf" 2>/dev/null | while IFS= read -r file; do
        basename "$file" .conf
      done
    fi
  fi | sort -u
}

select_webserver() {
  local existing=$(detect_webserver)

  if [[ -n "$existing" ]]; then
    log info "Detected existing webserver: $existing"
    echo "1) Continue with $existing" >&2
    echo "2) Switch to $([ "$existing" = "nginx" ] && echo "apache2" || echo "nginx")" >&2
    read -p "Select option (1-2): " choice

    case $choice in
      1) echo "$existing" ;;
      2) [ "$existing" = "nginx" ] && echo "apache2" || echo "nginx" ;;
      *) log error "Invalid choice"; select_webserver ;;
    esac
  else
    log info "No webserver detected"
    echo "1) nginx (recommended - faster, lighter)" >&2
    echo "2) apache2 (traditional, more modules)" >&2
    read -p "Select webserver (1-2): " choice

    case $choice in
      1) echo "nginx" ;;
      2) echo "apache2" ;;
      *) log error "Invalid choice"; select_webserver ;;
    esac
  fi
}

get_websites() {
  local webserver=$1
  local websites=()

  read -p "How many websites to setup? " num_sites >&2
  if ! [[ "$num_sites" =~ ^[0-9]+$ ]] || [[ $num_sites -lt 1 ]]; then
    log error "Please enter a valid number (≥1)"
    get_websites "$webserver"
    return
  fi

  local existing_sites
  existing_sites=$(detect_existing_sites "$webserver")

  if [[ -n "$existing_sites" ]]; then
    log warn "Existing sites: $existing_sites"
  fi

  for ((i=1; i<=num_sites; i++)); do
    read -p "Domain name for site $i (e.g., example.com): " domain >&2

    if ! [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z0-9]{2,}$ ]]; then
      log error "Invalid domain format. Use format: example.com"
      ((i--))
      continue
    fi

    websites+=("$domain")
  done

  printf '%s\n' "${websites[@]}"
}

get_firewall_config() {
  echo "" >&2
  log info "UFW Firewall Configuration"
  echo "By default, ports $SSH_PORT (SSH, rate-limited), 80 (HTTP) and 443 (HTTPS) will be open." >&2
  echo "1) Use default ($SSH_PORT, 80, 443 only)" >&2
  echo "2) Customize open ports (SSH port $SSH_PORT is always kept open)" >&2
  read -p "Select option (1-2): " choice >&2

  local ports=("80" "443")

  if [[ "$choice" == "2" ]]; then
    read -p "Enter comma-separated ports to open (e.g., 80,443,3000): " custom_ports >&2
    IFS=',' read -ra ports <<< "$custom_ports"

    for i in "${!ports[@]}"; do
      ports[$i]=$(echo "${ports[$i]}" | xargs)
      if ! [[ "${ports[$i]}" =~ ^[0-9]{1,5}$ ]] || (( 10#${ports[$i]} < 1 || 10#${ports[$i]} > 65535 )); then
        log error "Invalid port: ${ports[$i]} (must be 1-65535)"
        get_firewall_config
        return
      fi
      ports[$i]=$((10#${ports[$i]}))
    done
  fi

  # SSH is handled separately (always allowed + rate-limited) to avoid lockouts
  local port
  for port in "${ports[@]}"; do
    [[ "$port" != "$SSH_PORT" ]] && echo "$port"
  done
  return 0
}

# Decide whether SSH password login can safely be disabled for admin users.
# Outputs "no" (disable passwords) or "yes" (keep passwords).
get_ssh_password_choice() {
  echo "" >&2
  log info "SSH Configuration"

  local admin="${SUDO_USER:-}"
  if [[ -z "$admin" || "$admin" == "root" ]]; then
    log warn "You are running this script directly as root."
    log warn "Root SSH login will be disabled (PermitRootLogin no)."
    log warn "Make sure another user with sudo rights can log in, or you will lose SSH access."
    if ! ask_yes_no "Continue?" "n" >&2; then
      log error "Setup cancelled"
      exit 0
    fi
  fi

  local home="" keys_file=""
  if [[ -n "$admin" && "$admin" != "root" ]]; then
    home=$(getent passwd "$admin" | cut -d: -f6)
    keys_file="$home/.ssh/authorized_keys"
  fi

  if [[ -n "$keys_file" && -s "$keys_file" ]] && grep -qE '^[^#]*(ssh-|ecdsa-|sk-)' "$keys_file"; then
    log success "SSH key found for '$admin'"
    echo "Disabling password login stops brute-force attacks on SSH." >&2
    echo "SFTP users (group 'sftpusers', see add-sftp.sh) can still use passwords." >&2
    if ask_yes_no "Disable SSH password login for admin users? (recommended)" "y" >&2; then
      echo "no"
    else
      echo "yes"
    fi
  else
    log warn "No SSH key found for '${admin:-root}'. Keeping SSH password login ENABLED to avoid a lockout."
    log warn "Add a key (ssh-copy-id ${admin:-user}@this-server) and re-run the wizard to disable password login."
    echo "yes"
  fi
}

get_https_email() {
  echo "" >&2
  log info "HTTPS (Let's Encrypt)"
  echo "Free TLS certificates can be requested with certbot." >&2
  echo "The DNS records of your domains must ALREADY point to this server." >&2
  if ! ask_yes_no "Request HTTPS certificates now?" "y" >&2; then
    echo ""
    return 0
  fi

  local email
  while true; do
    read -p "Email for certificate expiry notices: " email >&2
    if [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
      echo "$email"
      return 0
    fi
    log error "Invalid email address"
  done
}

prompt_on_conflict() {
  local domain=$1
  local webserver=$2

  local config_path=""
  if [[ "$webserver" == "nginx" ]]; then
    config_path="/etc/nginx/sites-available/$domain"
  else
    config_path="/etc/apache2/sites-available/${domain}.conf"
  fi

  if [[ -f "$config_path" ]]; then
    log warn "Configuration already exists for $domain"
    echo "1) Skip this site" >&2
    echo "2) Overwrite existing config" >&2
    echo "3) Abort entire setup" >&2
    read -p "Select option (1-3): " choice

    case $choice in
      1) echo "skip" ;;
      2) echo "overwrite" ;;
      3) log error "Setup aborted"; exit 1 ;;
      *) log error "Invalid choice"; prompt_on_conflict "$domain" "$webserver" ;;
    esac
  else
    echo "create"
  fi
}

confirm_all_changes() {
  local webserver=$1
  local ports=$2
  local ssh_password=$3
  local https_email=$4
  shift 4
  local websites=("$@")

  echo ""
  log info "Summary of Changes"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Webserver: $webserver"
  echo "Websites:"
  for domain in "${websites[@]}"; do
    echo "  • $domain → /var/www/$domain/html"
  done
  echo "Firewall: UFW enabled, SSH $SSH_PORT (rate-limited) + ports: ${ports:-none}"
  if [[ "$ssh_password" == "no" ]]; then
    echo "SSH: key-only login for admins, root login disabled"
  else
    echo "SSH: password login still enabled (no key found), root login disabled"
  fi
  echo "HTTPS: $([[ -n "$https_email" ]] && echo "Let's Encrypt certificates ($https_email)" || echo "skipped")"
  echo "Actions:"
  echo "  1) Update system (apt upgrade) + enable automatic security updates"
  echo "  2) Install/verify and harden webserver"
  echo "  3) Create website folders and configs"
  echo "  4) Enable UFW firewall"
  echo "  5) Harden SSH + install fail2ban"
  [[ -n "$https_email" ]] && echo "  6) Request HTTPS certificates"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  read -p "Proceed with setup? (yes/no): " confirm

  if [[ ! "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    log error "Setup cancelled"
    exit 0
  fi
}

update_system() {
  log info "Updating system packages..."
  apt update
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
  log success "System updated"
}

setup_auto_updates() {
  log info "Enabling automatic security updates..."
  DEBIAN_FRONTEND=noninteractive apt install -y unattended-upgrades
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  log success "Automatic security updates enabled"
}

install_webserver() {
  local webserver=$1

  if is_installed "$webserver"; then
    log success "$webserver is already installed"
    return 0
  fi

  log info "Installing $webserver..."
  if [[ "$webserver" == "nginx" ]]; then
    DEBIAN_FRONTEND=noninteractive apt install -y nginx
    systemctl enable nginx
    systemctl start nginx
  else
    DEBIAN_FRONTEND=noninteractive apt install -y apache2
    systemctl enable apache2
    systemctl start apache2
  fi

  log success "$webserver installed and started"
}

# Server-wide hardening: hide version, security headers, block dotfiles,
# and a catch-all default site so unknown hostnames / the bare IP get nothing.
harden_webserver() {
  local webserver=$1

  log info "Hardening $webserver..."

  if [[ "$webserver" == "nginx" ]]; then
    cat > /etc/nginx/conf.d/00-webserver-wizard.conf <<'EOF'
# Managed by webserver-wizard
server_tokens off;

# Catch-all: drop requests for unknown hostnames or the bare IP
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    ssl_reject_handshake on;
    server_name _;
    return 444;
}
EOF

    cat > /etc/nginx/snippets/webserver-wizard-security.conf <<'EOF'
# Managed by webserver-wizard
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

# Never serve hidden files (.git, .env, .htpasswd...) except ACME challenges
location ~ /\.(?!well-known/) {
    deny all;
}
EOF

    # The stock default site would conflict with our default_server
    rm -f /etc/nginx/sites-enabled/default

    nginx -t >/dev/null 2>&1 || {
      log error "nginx hardening config failed validation:"
      nginx -t
      return 1
    }
  else
    a2enmod headers >/dev/null

    cat > /etc/apache2/conf-available/webserver-wizard-hardening.conf <<'EOF'
# Managed by webserver-wizard
ServerTokens Prod
ServerSignature Off
TraceEnable Off

<IfModule mod_headers.c>
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Permissions-Policy "camera=(), microphone=(), geolocation=()"
</IfModule>

# Never serve hidden files (.git, .env, .htpasswd...) except ACME challenges
RedirectMatch 404 "/\.(?!well-known/)"

# Catch-all: first vhost is the default, deny unknown hostnames / the bare IP
<VirtualHost *:80>
    ServerName default.invalid
    <Location />
        Require all denied
    </Location>
</VirtualHost>
EOF
    a2enconf webserver-wizard-hardening >/dev/null
    a2dissite 000-default >/dev/null 2>&1 || true

    apache2ctl configtest >/dev/null 2>&1 || {
      log error "Apache hardening config failed validation:"
      apache2ctl configtest
      return 1
    }
  fi

  log success "$webserver hardened (version hidden, security headers, dotfiles blocked, default site disabled)"
}

generate_nginx_config() {
  local domain=$1
  cat > /etc/nginx/sites-available/"$domain" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name $domain www.$domain;
    root /var/www/$domain/html;

    index index.html index.htm;

    include snippets/webserver-wizard-security.conf;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # HTTPS is added by certbot (certbot --nginx -d $domain -d www.$domain)

    # Access and error logs
    access_log /var/log/nginx/$domain.access.log;
    error_log /var/log/nginx/$domain.error.log;
}
EOF
}

generate_apache_config() {
  local domain=$1
  cat > /etc/apache2/sites-available/"${domain}.conf" <<EOF
<VirtualHost *:80>
    ServerName $domain
    ServerAlias www.$domain

    DocumentRoot /var/www/$domain/html

    <Directory /var/www/$domain/html>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/$domain.error.log
    CustomLog \${APACHE_LOG_DIR}/$domain.access.log combined
</VirtualHost>
EOF
}

setup_webserver_config() {
  local webserver=$1
  local domain=$2
  local action=$3

  if [[ "$action" == "skip" ]]; then
    log info "Skipping $domain"
    return 0
  fi

  if [[ "$webserver" == "nginx" ]]; then
    generate_nginx_config "$domain"

    if [[ ! -L "/etc/nginx/sites-enabled/$domain" ]]; then
      ln -sf /etc/nginx/sites-available/"$domain" /etc/nginx/sites-enabled/"$domain"
    fi

    nginx -t >/dev/null 2>&1 && log success "Nginx config for $domain created" || {
      log error "Nginx config validation failed for $domain"
      return 1
    }
  else
    generate_apache_config "$domain"

    if ! a2ensite "$domain" >/dev/null 2>&1; then
      log error "Failed to enable site $domain"
      return 1
    fi

    apache2ctl configtest >/dev/null 2>&1 && log success "Apache config for $domain created" || {
      log error "Apache config validation failed for $domain"
      return 1
    }
  fi
}

# Ownership model:
#   /var/www and /var/www/<domain>  root:root 755  (required for SFTP chroot, see add-sftp.sh)
#   /var/www/<domain>/html          <admin>:www-data 755, files 644
# The webserver only needs to READ the site. If it owned the files, a compromised
# webserver/app could rewrite your website.
create_folders() {
  local domain=$1
  local action=$2
  local webroot="/var/www/$domain/html"
  local owner="${SUDO_USER:-root}"

  if [[ "$action" == "skip" ]]; then
    return 0
  fi

  install -d -m 755 -o root -g root /var/www "/var/www/$domain"
  chown root:root /var/www "/var/www/$domain"
  chmod 755 /var/www "/var/www/$domain"

  if [[ ! -d "$webroot" ]]; then
    install -d -m 755 -o "$owner" -g www-data "$webroot"
  fi

  if [[ ! -f "$webroot/index.html" ]]; then
    cat > "$webroot/index.html" <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to $domain</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 50px; }
        h1 { color: #333; }
        .info { color: #666; background: #f0f0f0; padding: 10px; border-radius: 5px; }
    </style>
</head>
<body>
    <h1>Welcome to $domain</h1>
    <div class="info">
        <p>Your website is ready to serve content.</p>
        <p>Replace this file at: <code>$webroot/index.html</code></p>
    </div>
</body>
</html>
EOF
    chown "$owner":www-data "$webroot/index.html"
    chmod 644 "$webroot/index.html"
  fi

  log success "Folder structure created for $domain"
}

reload_webserver() {
  local webserver=$1

  if [[ "$webserver" == "nginx" ]]; then
    systemctl reload nginx
  else
    systemctl reload apache2
  fi
}

setup_ufw() {
  local -a ports=("$@")

  if ! command -v ufw &> /dev/null; then
    log info "Installing UFW..."
    DEBIAN_FRONTEND=noninteractive apt install -y ufw
  fi

  log info "Configuring UFW firewall..."

  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null

  # Allow SSH BEFORE enabling the firewall, so the current session is never cut.
  # "limit" blocks IPs making 6+ connection attempts in 30 seconds.
  ufw limit "$SSH_PORT/tcp" comment 'SSH (rate-limited)' >/dev/null
  log success "UFW: Allowed port $SSH_PORT/tcp (rate-limited)"

  for port in "${ports[@]}"; do
    ufw allow "$port/tcp" >/dev/null
    log success "UFW: Allowed port $port/tcp"
  done

  ufw --force enable >/dev/null
  log success "UFW firewall enabled"
}

setup_ssh() {
  local password_auth=$1

  log info "Hardening SSH..."
  if ! is_installed "openssh-server"; then
    log info "Installing OpenSSH Server..."
    DEBIAN_FRONTEND=noninteractive apt install -y openssh-server
    systemctl enable ssh
  fi

  local stamp backup
  stamp=$(date +%Y%m%d-%H%M%S)
  backup="/etc/ssh/sshd_config.bak.$stamp"
  cp -a /etc/ssh/sshd_config "$backup"
  log info "Backed up sshd_config to $backup"

  local hardening_backup=""
  if [[ -f "$SSH_HARDENING_FILE" ]]; then
    hardening_backup="$SSH_HARDENING_FILE.bak.$stamp"
    cp -a "$SSH_HARDENING_FILE" "$hardening_backup"
  fi

  mkdir -p /etc/ssh/sshd_config.d

  # sshd uses the FIRST value it reads for each option. Files in sshd_config.d
  # are read before the main config, and "00-" sorts before files like
  # 50-cloud-init.conf (which often sets PasswordAuthentication yes).
  cat > "$SSH_HARDENING_FILE" <<EOF
# Managed by webserver-wizard
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication $password_auth
PubkeyAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  chmod 644 "$SSH_HARDENING_FILE"

  # Only define the sftp subsystem if add-sftp.sh hasn't already (duplicates are an error).
  local subsystem_line="Subsystem sftp internal-sftp"
  if grep -qs '^Subsystem[[:space:]]\+sftp' /etc/ssh/sshd_config.d/*.conf; then
    subsystem_line="# Subsystem sftp is defined in /etc/ssh/sshd_config.d/"
  fi

  cat > /etc/ssh/sshd_config <<EOF
# Managed by webserver-wizard - hardening options are in $SSH_HARDENING_FILE
Include /etc/ssh/sshd_config.d/*.conf

UsePAM yes
PrintMotd no
AcceptEnv LANG LC_*
$subsystem_line
EOF

  if [[ "$password_auth" == "no" ]]; then
    cat >> /etc/ssh/sshd_config <<EOF

# SFTP-only users created by add-sftp.sh may still log in with a password
# (they are chrooted and have no shell).
Match Group sftpusers
    PasswordAuthentication yes
EOF
  fi

  # sshd -t needs the privilege separation dir, which only exists while sshd runs
  mkdir -p /run/sshd

  if ! sshd -t; then
    log error "New SSH config is invalid, restoring backup"
    cp -a "$backup" /etc/ssh/sshd_config
    if [[ -n "$hardening_backup" ]]; then
      cp -a "$hardening_backup" "$SSH_HARDENING_FILE"
    else
      rm -f "$SSH_HARDENING_FILE"
    fi
    return 1
  fi

  # Reload (existing sessions stay open). On Ubuntu 24.04 sshd may be
  # socket-activated and not running yet; it will read the new config on start.
  systemctl try-reload-or-restart ssh

  log success "SSH hardened (root login off, password login: $password_auth)"
  if [[ "$password_auth" == "no" ]]; then
    log warn "Test a NEW SSH session with your key before closing this one!"
  fi
}

setup_fail2ban() {
  log info "Installing fail2ban..."
  if ! DEBIAN_FRONTEND=noninteractive apt install -y fail2ban; then
    log warn "fail2ban installation failed, skipping"
    return 0
  fi

  cat > /etc/fail2ban/jail.d/webserver-wizard.local <<EOF
# Managed by webserver-wizard
[sshd]
enabled  = true
port     = $SSH_PORT
maxretry = 5
findtime = 10m
bantime  = 1h
EOF

  if systemctl enable fail2ban >/dev/null 2>&1 && systemctl restart fail2ban; then
    log success "fail2ban enabled (SSH: 5 failures in 10 min → 1h ban)"
  else
    log warn "fail2ban could not be started, check: journalctl -u fail2ban"
  fi
}

setup_https() {
  local webserver=$1
  local email=$2
  shift 2
  local websites=("$@")

  local plugin="nginx"
  [[ "$webserver" == "apache2" ]] && plugin="apache"

  log info "Installing certbot..."
  DEBIAN_FRONTEND=noninteractive apt install -y certbot "python3-certbot-$plugin"

  local domain
  for domain in "${websites[@]}"; do
    log info "Requesting certificate for $domain..."
    if certbot "--$plugin" --non-interactive --agree-tos -m "$email" --redirect \
        -d "$domain" -d "www.$domain"; then
      log success "HTTPS enabled for $domain and www.$domain"
    elif certbot "--$plugin" --non-interactive --agree-tos -m "$email" --redirect \
        -d "$domain"; then
      log success "HTTPS enabled for $domain"
      log warn "www.$domain was not included (check its DNS record, then: certbot --$plugin -d $domain -d www.$domain)"
    else
      log warn "Could not get a certificate for $domain. Check DNS, then run: certbot --$plugin -d $domain"
    fi
  done

  # certbot installs a systemd timer for automatic renewal
  log success "Certificates renew automatically (systemctl list-timers | grep certbot)"
}

show_status() {
  local webserver=$1
  local https=$2
  shift 2
  local websites=("$@")
  local scheme="http"
  [[ -n "$https" ]] && scheme="https"

  echo ""
  log success "Setup Complete!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Webserver: $webserver"
  echo "Status:"

  if [[ "$webserver" == "nginx" ]]; then
    systemctl is-active nginx > /dev/null 2>&1 && echo "  nginx: $(systemctl is-active nginx)" || echo "  nginx: inactive"
  else
    systemctl is-active apache2 > /dev/null 2>&1 && echo "  apache2: $(systemctl is-active apache2)" || echo "  apache2: inactive"
  fi

  echo ""
  echo "Websites configured:"
  for domain in "${websites[@]}"; do
    echo "  • $domain"
    echo "    Root: /var/www/$domain/html"
    echo "    Access: $scheme://$domain"
  done

  echo ""
  echo "Firewall:"
  ufw status | grep "Status:"

  echo ""
  echo "Useful commands:"
  if [[ "$webserver" == "nginx" ]]; then
    echo "  • View config: less /etc/nginx/sites-available/<domain>"
    echo "  • Reload: systemctl reload nginx"
  else
    echo "  • View config: less /etc/apache2/sites-available/<domain>.conf"
    echo "  • Reload: systemctl reload apache2"
  fi
  echo "  • View firewall: sudo ufw status"
  echo "  • Effective SSH config: sudo sshd -T | less"
  echo "  • Banned IPs: sudo fail2ban-client status sshd"
  echo "  • Fix site permissions: sudo chown -R \$USER:www-data /var/www/<domain>/html"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

ascii_art() {
  echo -e "${COLOR_BLUE}"
  echo "██╗    ██╗███████╗██████╗ ███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗ "
  echo "██║    ██║██╔════╝██╔══██╗██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗"
  echo "██║ █╗ ██║█████╗  ██████╔╝███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝"
  echo "██║███╗██║██╔══╝  ██╔══██╗╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══╝  ██╔══██╗"
  echo "╚███╔███╔╝███████╗██████╔╝███████║███████╗██║  ██║ ╚████╔╝ ███████╗██║  ██║"
  echo " ╚══╝╚══╝ ╚══════╝╚═════╝ ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝"
  echo "░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░█░█░▀█▀░▀▀█░█▀█░█▀▄░█▀▄"
  echo "░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░█▄█░░█░░▄▀░░█▀█░█▀▄░█░█"
  echo "░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▀░▀░▀▀▀░▀▀▀░▀░▀░▀░▀░▀▀░"
  echo "░░by e-garbage░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░"

  echo -e "${COLOR_RESET}"
}

main() {
  require_root
  ascii_art

  log info "Webserver Setup Wizard"
  echo ""

  local webserver
  webserver=$(select_webserver)

  local websites_output
  websites_output=$(get_websites "$webserver")
  local websites=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && websites+=("$line")
  done <<< "$websites_output"

  local firewall_output
  firewall_output=$(get_firewall_config)
  local firewall_ports=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && firewall_ports+=("$line")
  done <<< "$firewall_output"

  local ssh_password
  ssh_password=$(get_ssh_password_choice)

  local https_email
  https_email=$(get_https_email)

  confirm_all_changes "$webserver" "${firewall_ports[*]:-}" "$ssh_password" "$https_email" "${websites[@]}"

  update_system
  setup_auto_updates
  install_webserver "$webserver"
  harden_webserver "$webserver"

  for domain in "${websites[@]}"; do
    local action
    action=$(prompt_on_conflict "$domain" "$webserver")
    create_folders "$domain" "$action"
    setup_webserver_config "$webserver" "$domain" "$action"
  done

  reload_webserver "$webserver"
  setup_ufw "${firewall_ports[@]}"
  setup_ssh "$ssh_password"
  setup_fail2ban

  if [[ -n "$https_email" ]]; then
    setup_https "$webserver" "$https_email" "${websites[@]}"
  fi

  show_status "$webserver" "$https_email" "${websites[@]}"
}

main "$@"
