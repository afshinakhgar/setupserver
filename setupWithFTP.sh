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

# 1. Install vsftpd (optional, only for FTP version)
echo "Installing vsftpd if not present..."
sudo apt update && sudo apt install -y vsftpd

# 2. Create directory structure
sudo mkdir -p "$PUBLIC_DIR"
sudo chown root:root "$BASE_DIR"
sudo chmod 755 "$BASE_DIR"
sudo mkdir -p "$PUBLIC_DIR"
sudo chown "$USER":"$USER" "$PUBLIC_DIR"

# 3. Create user with chroot to BASE_DIR and home in /web
sudo useradd -d "/web" -s /bin/bash "$USER"
sudo passwd "$USER"

# 4. Set directory ownership
sudo chown root:root "$BASE_DIR"
sudo chmod 755 "$BASE_DIR"
sudo chown root:root "$WEB_DIR"
sudo chmod 755 "$WEB_DIR"
sudo chown -R "$USER":"$USER" "$PUBLIC_DIR"

# 5. Create nginx config
sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    client_max_body_size 100M;

    root /var/www/$DOMAIN/web/public;
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

# 6. Enable nginx site
sudo ln -s "$NGINX_CONF" "$NGINX_LINK"
sudo nginx -t && sudo systemctl reload nginx

# 7. SSH config for chroot jail
sudo tee -a "$SSHD_CONFIG" > /dev/null <<EOF

Match User $USER
    ChrootDirectory $BASE_DIR
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
EOF

# 8. Restart SSH service
sudo systemctl restart ssh || sudo service ssh restart

# 9. Create MySQL database and user
sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`$DBNAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
sudo mysql -e "CREATE USER IF NOT EXISTS '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS';"
sudo mysql -e "GRANT ALL PRIVILEGES ON \`$DBNAME\`.* TO '$DBUSER'@'localhost';"
sudo mysql -e "FLUSH PRIVILEGES;"

# 10. Setup FTP (if needed)
echo "Configuring FTP user access..."
echo -e "$USER\tlocal_enable=YES\nwrite_enable=YES\nchroot_local_user=YES" | sudo tee -a /etc/vsftpd.userlist > /dev/null
sudo systemctl restart vsftpd

echo "✅ Done. Access for '$USER' via SFTP (and optionally FTP) is ready. Nginx and MySQL for $DOMAIN are also configured."
