#!/usr/bin/env bash
set -euo pipefail

# =============================================
# Universal PHP Site Bootstrap (SFTP chroot + Nginx + PHP-FPM + optional MySQL)
# Works for: WordPress, Slim 4, generic PHP apps
# Key fixes vs original:
# - Ensure deploy user can WRITE code under web root while keeping chroot root owned by root.
# - Safer PHP-FPM socket detection and explicit override.
# - Nginx vhost does NOT rely on Debian-only snippets to avoid nginx -t failures.
# - More robust MySQL handling (socket or password) and clearer prompts.
# - Disable default nginx site to avoid accidental vhost conflicts.
# =============================================

# ---------- helpers ----------
die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
info() { echo "==> $*"; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root."; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

restart_service_safe() {
  local svc="$1"
  systemctl restart "$svc" 2>/dev/null || systemctl restart "${svc}d" 2>/dev/null || service "$svc" restart 2>/dev/null || true
}

selinux_restorecon_if_present() {
  if has_cmd getenforce && [[ "$(getenforce)" != "Disabled" ]]; then
    if has_cmd restorecon; then restorecon -Rv /var/www || true; fi
  fi
}

# Try common PHP-FPM sockets, else scan /run/php
_detect_php_fpm_sock() {
  local candidates=(
    "/run/php/php8.4-fpm.sock"
    "/run/php/php8.3-fpm.sock"
    "/run/php/php8.2-fpm.sock"
    "/run/php/php-fpm.sock"
  )
  for s in "${candidates[@]}"; do [[ -S "$s" ]] && { echo "$s"; return; }; done
  local any
  any=$(find /run/php -maxdepth 1 -type s 2>/dev/null | head -n1 || true)
  [[ -n "${any:-}" ]] && { echo "$any"; return; }
  die "Could not detect PHP-FPM socket. Use --php-fpm-sock to set explicitly."
}

_enable_acl_mode() {
  if has_cmd setfacl; then return 0; fi
  if has_cmd apt-get; then
    apt-get update -y && apt-get install -y acl || true
  fi
  has_cmd setfacl
}

# ---------- defaults ----------
WWW_USER_DEFAULT="www-data"     # For Debian/Ubuntu. Use 'nginx' on RHEL/Alma if you adapt this script.
APP_TYPES=(wordpress slim php)

# ---------- args (optional flags) ----------
PHP_FPM_SOCK_OVERRIDE=""
WWW_USER="$WWW_USER_DEFAULT"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --php-fpm-sock)
      PHP_FPM_SOCK_OVERRIDE="${2:-}"; shift 2 ;;
    --www-user)
      WWW_USER="${2:-}"; shift 2 ;;
    --help|-h)
      cat <<USAGE
Universal PHP Site Bootstrap
Optional flags:
  --php-fpm-sock <path>   Explicit PHP-FPM unix socket path
  --www-user <user>       Web server/PHP-FPM user (default: ${WWW_USER_DEFAULT})
USAGE
      exit 0 ;;
    *) die "Unknown arg: $1" ;;
  esac
done

# ---------- preconditions ----------
require_root
has_cmd nginx || die "nginx not found. Install nginx first."
has_cmd mysql || warn "mysql client not found. MySQL features will fail if used."

# ---------- inputs ----------
read -rp "Domain (e.g. example.com): " DOMAIN
read -rp "Linux username to create/use: " USER
read -rp "App type [wordpress/slim/php]: " APP_TYPE
APP_TYPE=${APP_TYPE,,}
case "$APP_TYPE" in
  wordpress|slim|php) ;;
  *) die "Unsupported app type. Use: wordpress | slim | php" ;;
esac

# Web root relative to /var/www/<domain>. Default web/public (common for Slim/modern setups)
read -rp "Web root relative path [web/public]: " WEB_REL
WEB_REL=${WEB_REL:-web/public}

# Additional runtime-writable dirs (comma-separated, relative to web root). For generic apps.
EXTRA_WRITABLE=""
if [[ "$APP_TYPE" == "php" ]]; then
  read -rp "Extra runtime-writable dirs under web root (comma-separated) [none]: " EXTRA_WRITABLE
  EXTRA_WRITABLE=${EXTRA_WRITABLE:-}
fi

# MySQL optional
read -rp "Create MySQL DB and user? [y/N]: " WANT_DB
WANT_DB=${WANT_DB,,}; WANT_DB=${WANT_DB:-n}
if [[ "$WANT_DB" == "y" ]]; then
  read -rp "MySQL root user [root]: " MYSQL_ROOT_USER; MYSQL_ROOT_USER=${MYSQL_ROOT_USER:-root}
  # If using socket auth (no password), just press Enter here.
  read -srp "MySQL root password (leave empty if using socket auth): " MYSQL_ROOT_PASS; echo ""
  read -rp "Database name: " DBNAME
  read -rp "DB username: " DBUSER
  read -srp "DB user password: " DBPASS; echo ""
  [[ -n "${DBNAME:-}" && -n "${DBUSER:-}" && -n "${DBPASS:-}" ]] || die "DB name/user/pass are required."
fi

# ---------- derived paths ----------
BASE_DIR="/var/www/$DOMAIN"        # must remain root:root for chroot
WEB_DIR="$BASE_DIR/${WEB_REL%/}"
PUBLIC_DIR="$WEB_DIR"
USER_HOME_IN_CHROOT="$BASE_DIR/home/$USER"  # optional writable area for SFTP (not used by nginx)
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
NGINX_LINK="/etc/nginx/sites-enabled/$DOMAIN"
SSHD_CONFIG="/etc/ssh/sshd_config"
PHP_FPM_SOCK="${PHP_FPM_SOCK_OVERRIDE:-$(_detect_php_fpm_sock)}"
WWW_GROUP=$(id -gn "$WWW_USER" 2>/dev/null || echo "$WWW_USER")

info "Using PHP-FPM socket: $PHP_FPM_SOCK"
info "Web/PHP-FPM will run as user: $WWW_USER (group: $WWW_GROUP)"

# ---------- system users ----------
if id "$USER" &>/dev/null; then
  info "User $USER exists; skipping creation."
else
  useradd -M -s /bin/bash "$USER"
  echo "Set password for $USER:"
  passwd "$USER"
fi

# ---------- directory structure ----------
mkdir -p "$PUBLIC_DIR" "$USER_HOME_IN_CHROOT"
# Chroot root must be owned by root and not writable by group/others
chown root:root "$BASE_DIR"
chmod 755 /var /var/www "$BASE_DIR"

# Ensure web root exists and is OWNED by the deploy user so they can upload code.
chown -R "$USER":"$USER" "$WEB_DIR"

# default safe perms for code tree (readable by others, writable by the owner)
find "$WEB_DIR" -type d -exec chmod 755 {} \; || true
find "$WEB_DIR" -type f -exec chmod 644 {} \; || true

# app-specific writable dirs
declare -a WRITABLE_DIRS
case "$APP_TYPE" in
  wordpress)
    WRITABLE_DIRS+=("wp-content/uploads" "wp-content/cache") ;;
  slim)
    WRITABLE_DIRS+=("../var" "../storage" "../cache") ;;
  php)
    if [[ -n "$EXTRA_WRITABLE" ]]; then
      IFS=',' read -r -a arr <<<"$EXTRA_WRITABLE"
      for d in "${arr[@]}"; do d_trimmed="${d// /}"; [[ -n "$d_trimmed" ]] && WRITABLE_DIRS+=("$d_trimmed"); done
    fi ;;
  *) ;;
esac

# create writable dirs
for d in "${WRITABLE_DIRS[@]:-}"; do
  [[ -z "$d" ]] && continue
  if [[ "$d" == ../* ]]; then
    mkdir -p "$WEB_DIR/${d}"
  else
    mkdir -p "$PUBLIC_DIR/${d}"
  fi
done

# ownership and permissions for site user on writable dirs
for d in "${WRITABLE_DIRS[@]:-}"; do
  [[ -z "$d" ]] && continue
  target_dir=""
  if [[ "$d" == ../* ]]; then
    target_dir="$WEB_DIR/${d}"
  else
    target_dir="$PUBLIC_DIR/${d}"
  fi
  chown -R "$USER":"$USER" "$target_dir"
  chmod -R 755 "$target_dir"
  chmod g+s "$target_dir" || true
done

# ---------- PHP-FPM access model (ACL preferred, group fallback) ----------
ACL_MODE=0
if _enable_acl_mode; then
  ACL_MODE=1
  info "Using ACL mode. Granting $WWW_USER read/execute on code and rwx on writable dirs."
  setfacl -m u:"$WWW_USER":rx "$WEB_DIR" || true
  setfacl -R -m u:"$WWW_USER":rx "$PUBLIC_DIR" || true
  for d in "${WRITABLE_DIRS[@]:-}"; do
    [[ -z "$d" ]] && continue
    if [[ "$d" == ../* ]]; then
      setfacl -R -m u:"$WWW_USER":rwx "$WEB_DIR/${d}" || true
      setfacl -dR -m u:"$WWW_USER":rwx "$WEB_DIR/${d}" || true
    else
      setfacl -R -m u:"$WWW_USER":rwx "$PUBLIC_DIR/${d}" || true
      setfacl -dR -m u:"$WWW_USER":rwx "$PUBLIC_DIR/${d}" || true
    fi
  done
else
  warn "ACL not available; using group fallback. Adding $USER to group $WWW_GROUP."
  usermod -aG "$WWW_GROUP" "$USER" || true
  for d in "${WRITABLE_DIRS[@]:-}"; do
    [[ -z "$d" ]] && continue
    if [[ "$d" == ../* ]]; then
      chgrp -R "$WWW_GROUP" "$WEB_DIR/${d}"
      chmod -R 775 "$WEB_DIR/${d}"
    else
      chgrp -R "$WWW_GROUP" "$PUBLIC_DIR/${d}"
      chmod -R 775 "$PUBLIC_DIR/${d}"
    fi
  done
fi

# Make wp-config.php readable by PHP-FPM if present WITHOUT changing ownership away from the deploy user.
if [[ -f "$PUBLIC_DIR/wp-config.php" ]]; then
  if [[ $ACL_MODE -eq 1 ]]; then
    setfacl -m u:"$WWW_USER":r "$PUBLIC_DIR/wp-config.php" || true
  else
    chgrp "$WWW_GROUP" "$PUBLIC_DIR/wp-config.php" || true
    chmod 640 "$PUBLIC_DIR/wp-config.php" || true
  fi
fi

# ---------- Nginx vhost ----------
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled || true
cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    client_max_body_size 100M;

    root $PUBLIC_DIR;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \\.php$ {
        # We avoid distro-specific include snippets to stay portable.
        fastcgi_pass unix:$PHP_FPM_SOCK;
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
    }

    location ~ /\\.ht { deny all; }

    location ~* \\.(jpg|jpeg|png|gif|ico|css|js|woff2?|ttf|svg|eot)$ {
        expires 365d;
        access_log off;
    }
}
EOF
ln -sf "$NGINX_CONF" "$NGINX_LINK"
# Disable the default site if present to prevent conflicts
rm -f /etc/nginx/sites-enabled/default || true

nginx -t
systemctl reload nginx || true

# ---------- SSHD SFTP chroot ----------
SSHD_CONFIG="/etc/ssh/sshd_config"
if ! grep -qE '^Subsystem[[:space:]]+sftp[[:space:]]+internal-sftp' "$SSHD_CONFIG"; then
  if grep -qE '^Subsystem[[:space:]]+sftp' "$SSHD_CONFIG"; then
    sed -i 's|^Subsystem[[:space:]]\+sftp.*|Subsystem sftp internal-sftp|' "$SSHD_CONFIG"
  else
    echo "Subsystem sftp internal-sftp" >> "$SSHD_CONFIG"
  fi
fi
if ! grep -q "Match User $USER" "$SSHD_CONFIG"; then
  cat >> "$SSHD_CONFIG" <<EOF

Match User $USER
    ChrootDirectory $BASE_DIR
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
EOF
fi
restart_service_safe ssh
restart_service_safe sshd

# ---------- MySQL (optional) ----------
if [[ "$WANT_DB" == "y" ]]; then
  has_cmd mysql || die "mysql client not found."
  # Prefer socket if password empty, else use password auth.
  MYSQL_CMD=(mysql -u "$MYSQL_ROOT_USER")
  if [[ -n "${MYSQL_ROOT_PASS:-}" ]]; then
    MYSQL_CMD+=( -p"$MYSQL_ROOT_PASS" )
  else
    # Common Debian/Ubuntu socket path
    [[ -S /var/run/mysqld/mysqld.sock ]] && MYSQL_CMD+=( -S /var/run/mysqld/mysqld.sock )
  fi
  if ! "${MYSQL_CMD[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
    die "Cannot authenticate to MySQL as $MYSQL_ROOT_USER (check password or socket auth)."
  fi
  DB_ESC="\`$DBNAME\`"; USER_ESC="'$DBUSER'@'localhost'"
  SQL=$(cat <<SQL_EOF
CREATE DATABASE IF NOT EXISTS $DB_ESC CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS $USER_ESC IDENTIFIED BY '${DBPASS//\'/\'\'}';
GRANT ALL PRIVILEGES ON $DB_ESC.* TO $USER_ESC;
FLUSH PRIVILEGES;
SQL_EOF
  )
  echo "$SQL" | "${MYSQL_CMD[@]}"
fi

# ---------- SELinux contexts (if present) ----------
selinux_restorecon_if_present

# ---------- Summary ----------
cat <<INFO

Setup complete for $DOMAIN

User:               $USER
Chroot:             $BASE_DIR (must remain root:root)
Web root:           $PUBLIC_DIR (owned by $USER for deployments)
Writable dirs:      ${WRITABLE_DIRS[*]:-(none)}
Nginx conf:         $NGINX_CONF (enabled via $NGINX_LINK)
PHP-FPM socket:     $PHP_FPM_SOCK (override with --php-fpm-sock)
Web/PHP user:       $WWW_USER (group: $WWW_GROUP)
ACL mode:           $([[ $ACL_MODE -eq 1 ]] && echo enabled || echo disabled)

If group fallback mode was used:
  - Start a new SSH session for $USER to refresh group membership in $WWW_GROUP.
  - Ensure your deploy tool uploads into the web root or listed writable dirs.

Useful checks:
  nginx -t && systemctl reload nginx
  ls -l /run/php/*.sock
  journalctl -u nginx -n 100
  journalctl -u php*-fpm -n 100

INFO
