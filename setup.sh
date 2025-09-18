#!/usr/bin/env bash
set -euo pipefail

# =============================================
# Universal PHP Site Bootstrap (SFTP chroot + Nginx + PHP-FPM + optional MySQL)
# Works for: WordPress, Slim 4, generic PHP apps
# Key fixes:
# - Web root owned by deploy user, chroot root by root:root
# - Portable Nginx config (no Debian-only snippets)
# - PHP-FPM socket detection and override
# - Optional MySQL DB creation with socket or password auth
# - Disables default Nginx site to prevent conflicts
# =============================================

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

WWW_USER_DEFAULT="www-data"
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

require_root
has_cmd nginx || die "nginx not found. Install nginx first."
has_cmd mysql || warn "mysql client not found."

read -rp "Domain (e.g. example.com): " DOMAIN
read -rp "Linux username to create/use: " USER
read -rp "App type [wordpress/slim/php]: " APP_TYPE
APP_TYPE=${APP_TYPE,,}
case "$APP_TYPE" in
  wordpress|slim|php) ;;
  *) die "Unsupported app type. Use: wordpress | slim | php" ;;
esac

read -rp "Web root relative path [web/public]: " WEB_REL
WEB_REL=${WEB_REL:-web/public}

EXTRA_WRITABLE=""
if [[ "$APP_TYPE" == "php" ]]; then
  read -rp "Extra runtime-writable dirs under web root (comma-separated) [none]: " EXTRA_WRITABLE
  EXTRA_WRITABLE=${EXTRA_WRITABLE:-}
fi

read -rp "Create MySQL DB and user? [y/N]: " WANT_DB
WANT_DB=${WANT_DB,,}; WANT_DB=${WANT_DB:-n}
if [[ "$WANT_DB" == "y" ]]; then
  read -rp "MySQL root user [root]: " MYSQL_ROOT_USER; MYSQL_ROOT_USER=${MYSQL_ROOT_USER:-root}
  read -srp "MySQL root password (leave empty if using socket auth): " MYSQL_ROOT_PASS; echo ""
  read -rp "Database name: " DBNAME
  read -rp "DB username: " DBUSER
  read -srp "DB user password: " DBPASS; echo ""
  [[ -n "${DBNAME:-}" && -n "${DBUSER:-}" && -n "${DBPASS:-}" ]] || die "DB name/user/pass are required."
fi

BASE_DIR="/var/www/$DOMAIN"
WEB_DIR="$BASE_DIR/${WEB_REL%/}"
PUBLIC_DIR="$WEB_DIR"
USER_HOME_IN_CHROOT="$BASE_DIR/home/$USER"
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
NGINX_LINK="/etc/nginx/sites-enabled/$DOMAIN"
SSHD_CONFIG="/etc/ssh/sshd_config"
PHP_FPM_SOCK="${PHP_FPM_SOCK_OVERRIDE:-$(_detect_php_fpm_sock)}"
WWW_GROUP=$(id -gn "$WWW_USER" 2>/dev/null || echo "$WWW_USER")

info "Using PHP-FPM socket: $PHP_FPM_SOCK"
info "Web/PHP-FPM will run as user: $WWW_USER (group: $WWW_GROUP)"

if id "$USER" &>/dev/null; then
  info "User $USER exists; skipping creation."
else
  useradd -M -s /bin/bash "$USER"
  echo "Set password for $USER:"
  passwd "$USER"
fi

mkdir -p "$PUBLIC_DIR" "$USER_HOME_IN_CHROOT"
chown root:root "$BASE_DIR"
chmod 755 /var /var/www "$BASE_DIR"

chown -R "$USER":"$USER" "$WEB_DIR"
find "$WEB_DIR" -type d -exec chmod 755 {} \; || true
find "$WEB_DIR" -type f -exec chmod 644 {} \; || true

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

for d in "${WRITABLE_DIRS[@]:-}"; do
  [[ -z "$d" ]] && continue
  if [[ "$d" == ../* ]]; then
    mkdir -p "$WEB_DIR/${d}"
  else
    mkdir -p "$PUBLIC_DIR/${d}"
  fi
done

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

ACL_MODE=0
if _enable_acl_mode; then
  ACL_MODE=1
  info "Using ACL mode."
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
  warn "ACL not available; using group fallback."
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

if [[ -f "$PUBLIC_DIR/wp-config.php" ]]; then
  if [[ $ACL_MODE -eq 1 ]]; then
    setfacl -m u:"$WWW_USER":r "$PUBLIC_DIR/wp-config.php" || true
  else
    chgrp "$WWW_GROUP" "$PUBLIC_DIR/wp-config.php" || true
    chmod 640 "$PUBLIC_DIR/wp-config.php" || true
  fi
fi

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

    location ~ \.php$ {
        fastcgi_pass unix:$PHP_FPM_SOCK;
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
    }

    location ~ /\.ht { deny all; }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2?|ttf|svg|eot)$ {
        expires 365d;
        access_log off;
    }
}
EOF
ln -sf "$NGINX_CONF" "$NGINX_LINK"
rm -f /etc/nginx/sites-enabled/default || true

nginx -t
systemctl reload nginx || true

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

if [[ "$WANT_DB" == "y" ]]; then
  has_cmd mysql || die "mysql client not found."
  MYSQL_CMD=(mysql -u "$MYSQL_ROOT_USER")
  if [[ -n "${MYSQL_ROOT_PASS:-}" ]]; then
    MYSQL_CMD+=( -p"$MYSQL_ROOT_PASS" )
  else
    [[ -S /var/run/mysqld/mysqld.sock ]] && MYSQL_CMD+=( -S /var/run/mysqld/mysqld.sock )
  fi
  if ! "${MYSQL_CMD[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
    die "Cannot authenticate to MySQL as $MYSQL_ROOT_USER."
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

# ---------- WordPress auto-install (if selected) ----------
if [[ "$APP_TYPE" == "wordpress" ]]; then
  info "Preparing WordPress files under $PUBLIC_DIR"

  # Ensure tools
  if has_cmd apt-get; then apt-get update -y || true; fi
  has_cmd curl || { has_cmd apt-get && apt-get install -y curl || true; }
  has_cmd unzip || { has_cmd apt-get && apt-get install -y unzip || true; }
  has_cmd php || warn "php-cli is not installed; wp-cli may not work."

  # Download WordPress core if index.php not present yet
  if [[ ! -f "$PUBLIC_DIR/index.php" ]]; then
    tmpdir=$(mktemp -d)
    info "Downloading latest WordPress..."
    curl -fsSL https://wordpress.org/latest.tar.gz | tar -xz -C "$tmpdir"
    rsync -a --delete "$tmpdir/wordpress/" "$PUBLIC_DIR/"
    rm -rf "$tmpdir"
    chown -R "$USER":"$USER" "$PUBLIC_DIR"
  else
    info "WordPress files already present; skipping download."
  fi

  # Ensure uploads/cache dirs exist
  mkdir -p "$PUBLIC_DIR/wp-content/uploads" "$PUBLIC_DIR/wp-content/cache"
  chown -R "$USER":"$USER" "$PUBLIC_DIR/wp-content"

  # Database credentials: use created ones if provided; otherwise prompt
  if [[ "$WANT_DB" == "y" ]]; then
    WP_DB_NAME="$DBNAME"; WP_DB_USER="$DBUSER"; WP_DB_PASS="$DBPASS"; WP_DB_HOST="localhost"
  else
    read -rp "Existing DB name for WordPress: " WP_DB_NAME
    read -rp "Existing DB username: " WP_DB_USER
    read -srp "Existing DB user password: " WP_DB_PASS; echo ""
    read -rp "DB host [localhost]: " WP_DB_HOST; WP_DB_HOST=${WP_DB_HOST:-localhost}
  fi

  # Create wp-config.php if missing
  if [[ ! -f "$PUBLIC_DIR/wp-config.php" && -f "$PUBLIC_DIR/wp-config-sample.php" ]]; then
    cp "$PUBLIC_DIR/wp-config-sample.php" "$PUBLIC_DIR/wp-config.php"
    sed -i "s/database_name_here/${WP_DB_NAME//\//\/}/" "$PUBLIC_DIR/wp-config.php"
    sed -i "s/username_here/${WP_DB_USER//\//\/}/" "$PUBLIC_DIR/wp-config.php"
    sed -i "s/password_here/${WP_DB_PASS//\//\/}/" "$PUBLIC_DIR/wp-config.php"
    sed -i "s/localhost/${WP_DB_HOST//\//\/}/" "$PUBLIC_DIR/wp-config.php"
    # Set FS_METHOD to direct to allow updates without FTP
    grep -q "FS_METHOD" "$PUBLIC_DIR/wp-config.php" || echo "define('FS_METHOD','direct');" >> "$PUBLIC_DIR/wp-config.php"
  fi

  # Install wp-cli if missing
  if ! has_cmd wp; then
    info "Installing wp-cli..."
    curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x /usr/local/bin/wp || true
  fi

  # Add salts and run core install if not already installed
  if has_cmd wp; then
    if ! wp core is-installed --path="$PUBLIC_DIR" --allow-root >/dev/null 2>&1; then
      info "Generating security salts and installing WordPress..."
      wp config shuffle-salts --path="$PUBLIC_DIR" --allow-root || true
      read -rp "Site title: " WP_TITLE
      read -rp "Admin username: " WP_ADMIN_USER
      read -srp "Admin password: " WP_ADMIN_PASS; echo ""
      read -rp "Admin email: " WP_ADMIN_EMAIL
      WP_URL="http://$DOMAIN"
      wp core install --path="$PUBLIC_DIR" --url="$WP_URL" --title="$WP_TITLE" \
        --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASS" --admin_email="$WP_ADMIN_EMAIL" \
        --skip-email --allow-root
      # Set pretty permalinks
      wp rewrite structure '/%postname%/' --path="$PUBLIC_DIR" --allow-root
      wp rewrite flush --hard --path="$PUBLIC_DIR" --allow-root
    else
      info "WordPress already installed at $PUBLIC_DIR; skipping wp core install."
    fi
  else
    warn "wp command not found; skipped salt generation and core install."
  fi

  # Ensure PHP-FPM can read configs and write uploads (ACL or group)
  if [[ $ACL_MODE -eq 1 ]]; then
    setfacl -R -m u:"$WWW_USER":rx "$PUBLIC_DIR" || true
    setfacl -R -m u:"$WWW_USER":rwx "$PUBLIC_DIR/wp-content" || true
    setfacl -dR -m u:"$WWW_USER":rwx "$PUBLIC_DIR/wp-content" || true
  else
    chgrp -R "$WWW_GROUP" "$PUBLIC_DIR/wp-content" || true
    chmod -R 775 "$PUBLIC_DIR/wp-content" || true
  fi
fi

# ---------- SELinux contexts (if present) ----------
selinux_restorecon_if_present

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

INFO
