#!/bin/bash

read -p "Enter domain name (e.g. example.com): " DOMAIN
read -p "Enter username to create: " USER
read -p "Enter database name to create: " DBNAME
read -p "Enter MySQL user to create: " DBUSER
read -s -p "Enter MySQL user password: " DBPASS
echo ""

BASE_DIR="/var/www/$DOMAIN"
WEB_DIR="$BASE_DIR/web"
PUBLIC_DIR="$WEB_DIR/public"
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
NGINX_LINK="/etc/nginx/sites-enabled/$DOMAIN"
SSHD_CONFIG="/etc/ssh/sshd_config"

# Create Linux user (skip if it already exists)
if id "$USER" &>/dev/null; then
    echo "ℹ️ User $USER already exists, skipping creation."
else
    sudo useradd -m -d "$BASE_DIR" -s /bin/bash "$USER"
    sudo passwd "$USER"
fi

# Create directory structure
sudo mkdir -p "$PUBLIC_DIR"

# Set ownership and permissions for web directories
sudo chown -R "$USER":"$USER" "$BASE_DIR"
sudo chmod -R 755 "$BASE_DIR"

# Create Nginx configuration for the new domain
sudo tee "$NGINX_CONF" > /dev/null <<EOF
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
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
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

# Enable Nginx site and reload service
sudo ln -sf "$NGINX_CONF" "$NGINX_LINK"
sudo nginx -t && sudo systemctl reload nginx

# Configure SFTP chroot jail in SSH config (skip if already exists)
if ! grep -q "Match User $USER" "$SSHD_CONFIG"; then
sudo tee -a "$SSHD_CONFIG" > /dev/null <<EOF

Match User $USER
    ChrootDirectory $BASE_DIR
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
EOF
sudo systemctl restart ssh || sudo service ssh restart
fi

# Create MySQL database and user with root privileges
sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DBNAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
sudo mysql -u root -e "CREATE USER IF NOT EXISTS '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DBNAME\`.* TO '$DBUSER'@'localhost';"
sudo mysql -u root -e "FLUSH PRIVILEGES;"

# Final output
echo "✅ Setup complete for $DOMAIN"
echo "User: $USER"
echo "Web root: $PUBLIC_DIR"
echo "MySQL DB: $DBNAME, User: $DBUSER"
