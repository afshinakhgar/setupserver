#!/bin/bash
set -euo pipefail

# ---------- Input ----------
read -p "Enter domain name (e.g. example.com): " DOMAIN
read -p "Enter Linux username to create: " USER
read -p "Enter database name to create: " DBNAME
read -p "Enter MySQL user to create: " DBUSER
read -s -p "Enter MySQL user password: " DBPASS; echo ""
read -p "Enter MySQL root username [root]: " MYSQL_ROOT_USER
MYSQL_ROOT_USER=${MYSQL_ROOT_USER:-root}
read -s -p "Enter MySQL root password (will be used once to create DB/user): " MYSQL_ROOT_PASS; echo ""

# ---------- Paths ----------
BASE_DIR="/var/www/$DOMAIN"          # MUST stay owned by root:root for SFTP chroot
WEB_DIR="$BASE_DIR/web"
PUBLIC_DIR="$WEB_DIR/public"         # Writable by site user
USER_HOME_IN_CHROOT="$BASE_DIR/home/$USER"  # Optional writable home inside chroot
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
NGINX_LINK="/etc/nginx/sites-enabled/$DOMAIN"
SSHD_CONFIG="/etc/ssh/sshd_config"
PHP_FPM_SOCK="/run/php/php8.3-fpm.sock"     # Adjust if needed

# ---------- Sanity checks ----------
if [[ -z "$DOMAIN" || -z "$USER" || -z "$DBNAME" || -z "$DBUSER" || -z "$DBPASS" ]]; then
  echo "Error: All inputs are required." >&2
  exit 1
fi

# ---------- Create Linux user (login shell but chrooted for SFTP) ----------
if id "$USER" &>/dev/null; then
  echo "ℹ️ User $USER already exists, skipping creation."
else
  # Create without home under /home; chroot will be /var/www/<domain>
  sudo useradd -M -s /bin/bash "$USER"
  echo "Set password for $USER:"
  sudo passwd "$USER"
fi

# ---------- Create directory structure ----------
# Chroot directory MUST be root:root and not group-writable
sudo mkdir -p "$PUBLIC_DIR" "$USER_HOME_IN_CHROOT"
sudo chown -R root:root "$BASE_DIR"
sudo chmod 755 "$BASE_DIR"

# Give the site user ownership ONLY inside working subdirectories
sudo chown -R "$USER":"$USER" "$WEB_DIR" "$USER_HOME_IN_CHROOT"
sudo find "$WEB_DIR" -type d -exec chmod 755 {} \;
sudo find "$WEB_DIR" -type f -exec chmod 644 {} \;

# ---------- Nginx vhost ----------
sudo tee "$NGINX_CONF" >/dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    client_max_body_size 100M;

    root $PUBLIC_DIR;
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_FPM_SOCK;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2?|ttf|svg|eot)\$ {
        expires 365d;
        access_log off;
    }
}
EOF

sudo ln -sf "$NGINX_CONF" "$NGINX_LINK"
sudo nginx -t
sudo systemctl reload nginx

# ---------- SSHD SFTP chroot ----------
# Ensure Subsystem line uses internal-sftp (usually already present)
if ! grep -qE '^Subsystem\s+sftp\s+internal-sftp' "$SSHD_CONFIG"; then
  echo "Ensuring internal-sftp Subsystem is configured..."
  # Replace existing Subsystem sftp line or append a correct one
  if grep -qE '^Subsystem\s+sftp' "$SSHD_CONFIG"; then
    sudo sed -i 's|^Subsystem[[:space:]]\+sftp.*|Subsystem sftp internal-sftp|' "$SSHD_CONFIG"
  else
    echo "Subsystem sftp internal-sftp" | sudo tee -a "$SSHD_CONFIG" >/dev/null
  fi
fi

# Add Match block for the user if missing
if ! grep -q "Match User $USER" "$SSHD_CONFIG"; then
  sudo tee -a "$SSHD_CONFIG" >/dev/null <<EOF

Match User $USER
    ChrootDirectory $BASE_DIR
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
EOF
  # Restart SSH to apply chroot. If systemd unit name differs, adjust the fallback.
  sudo systemctl restart ssh || sudo systemctl restart sshd || sudo service ssh restart
fi

# ---------- MySQL: create DB and user ----------
# Note: Using -p"$MYSQL_ROOT_PASS" will expose in 'ps aux' for a brief moment on some systems.
# If security is strict, consider using mysql_config_editor beforehand instead.
MYSQL_CMD=(mysql -u "$MYSQL_ROOT_USER" -p"$MYSQL_ROOT_PASS" --protocol=TCP)

# Validate root credentials early
if ! "${MYSQL_CMD[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
  echo "❌ Could not authenticate to MySQL as $MYSQL_ROOT_USER. Please verify the root password/host." >&2
  exit 1
fi

# Escape DB and user names with backticks/quotes in SQL
DB_ESC="\`$DBNAME\`"
USER_ESC="'$DBUSER'@'localhost'"

SQL=$(cat <<SQL_EOF
CREATE DATABASE IF NOT EXISTS $DB_ESC CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS $USER_ESC IDENTIFIED BY '${DBPASS//\'/\'\'}';
GRANT ALL PRIVILEGES ON $DB_ESC.* TO $USER_ESC;
FLUSH PRIVILEGES;
SQL_EOF
)

if ! echo "$SQL" | "${MYSQL_CMD[@]}" ; then
  echo "❌ Failed creating database/user or granting privileges." >&2
  exit 1
fi

# ---------- Final output ----------
cat <<INFO
✅ Setup complete for $DOMAIN

Linux user: $USER
Chroot: $BASE_DIR
Writable dirs: 
  - $WEB_DIR
  - $PUBLIC_DIR
  - $USER_HOME_IN_CHROOT

Web root: $PUBLIC_DIR
Nginx conf: $NGINX_CONF

MySQL:
  - DB: $DBNAME
  - User: $DBUSER @ localhost
INFO
