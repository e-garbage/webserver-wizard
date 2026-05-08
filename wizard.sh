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
  dpkg -l | grep -q "^ii  $1 " 2>/dev/null
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
        echo "${file%.*}" | xargs basename
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
  echo "By default, ports 80 (HTTP) and 443 (HTTPS) will be open." >&2
  echo "1) Use default (80, 443 only)" >&2
  echo "2) Customize open ports" >&2
  read -p "Select option (1-2): " choice >&2

  local ports=("80" "443")

  if [[ "$choice" == "2" ]]; then
    read -p "Enter comma-separated ports to open (e.g., 80,443,22,3000): " custom_ports >&2
    IFS=',' read -ra ports <<< "$custom_ports"

    for i in "${!ports[@]}"; do
      ports[$i]=$(echo "${ports[$i]}" | xargs)
      if ! [[ "${ports[$i]}" =~ ^[0-9]{1,5}$ ]]; then
        log error "Invalid port: ${ports[$i]}"
        get_firewall_config
        return
      fi
    done
  fi

  printf '%s\n' "${ports[@]}"
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
    echo "1) Skip this site"
    echo "2) Overwrite existing config"
    echo "3) Abort entire setup"
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
  shift
  local websites=("$@")
  local ports=()

  echo ""
  log info "Summary of Changes"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Webserver: $webserver"
  echo "Websites:"
  for domain in "${websites[@]}"; do
    echo "  • $domain → /var/www/$domain/html"
  done
  echo "Firewall: UFW enabled with ports 80, 443"
  echo "Actions:"
  echo "  1) Update system (apt upgrade)"
  echo "  2) Install/verify webserver"
  echo "  3) Create website folders and configs"
  echo "  4) Enable UFW firewall"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  read -p "Proceed with setup? (yes/no): " confirm

  if [[ "$confirm" != "yes" ]]; then
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

install_webserver() {
  local webserver=$1

  if is_installed "$webserver"; then
    log success "$webserver is already installed"
    return 0
  fi

  log info "Installing $webserver..."
  if [[ "$webserver" == "nginx" ]]; then
    apt install -y nginx
    systemctl enable nginx
    systemctl start nginx
  else
    apt install -y apache2
    a2enmod rewrite
    a2enmod proxy
    systemctl enable apache2
    systemctl start apache2
  fi

  log success "$webserver installed and started"
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

    location / {
        try_files \$uri \$uri/ =404;
    }

    # SSL configuration (uncomment after obtaining certificate)
    # listen 443 ssl http2;
    # listen [::]:443 ssl http2;
    # ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

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
        Options Indexes FollowSymLinks
        AllowOverride All
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

create_folders() {
  local domain=$1
  local webroot="/var/www/$domain/html"

  if [[ ! -d "$webroot" ]]; then
    mkdir -p "$webroot"
    chown www-data:www-data /var/www/$domain
    chown www-data:www-data "$webroot"
    chmod 755 /var/www/$domain
    chmod 755 "$webroot"
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
    chown www-data:www-data "$webroot/index.html"
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
    apt install -y ufw
  fi

  log info "Configuring UFW firewall..."

  ufw --force enable >/dev/null 2>&1
  ufw default deny incoming >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1

  for port in "${ports[@]}"; do
    ufw allow "$port/tcp" >/dev/null 2>&1
    log success "UFW: Allowed port $port/tcp"
  done

  log success "UFW firewall configured"
}

show_status() {
  local webserver=$1
  shift
  local websites=("$@")

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
    echo "    Access: http://$domain"
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

  confirm_all_changes "$webserver" "${websites[@]}"

  update_system
  install_webserver "$webserver"

  for domain in "${websites[@]}"; do
    local action
    action=$(prompt_on_conflict "$domain" "$webserver")
    setup_webserver_config "$webserver" "$domain" "$action"
    create_folders "$domain"
  done

  reload_webserver "$webserver"
  setup_ufw "${firewall_ports[@]}"

  show_status "$webserver" "${websites[@]}"
}

main "$@"
