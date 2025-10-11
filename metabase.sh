#!/bin/bash
set -e

echo "===================================="
echo "🚀 Metabase Auto Installer (Fixed v3 - Network Ready)"
echo "===================================="

# --- Step 1: Ask user inputs ---
read -p "Enter your domain (e.g. bi.giftooly.com): " DOMAIN
read -p "Enter Metabase port (default 3000): " PORT
PORT=${PORT:-3000}
read -p "Enter your email for SSL (e.g. admin@$DOMAIN): " EMAIL

read -s -p "Enter PostgreSQL password: " DB_PASS
echo ""

METABASE_DIR="/opt/metabase"
NETWORK_NAME="metabase_net"

echo "✅ Domain: $DOMAIN"
echo "✅ Port: $PORT"
echo "✅ Email: $EMAIL"

# --- Step 2: Install dependencies ---
echo "📦 Installing dependencies..."
apt update -y
apt install -y curl gnupg2 ca-certificates lsb-release apt-transport-https software-properties-common python3-certbot-nginx

# --- Step 3: Fix Docker conflicts ---
echo "🐳 Checking Docker installation..."
apt remove -y containerd.io containerd docker.io docker-ce docker-ce-cli docker-ce-rootless-extras || true
apt autoremove -y
curl -fsSL https://get.docker.com | bash
systemctl enable --now docker

# --- Step 4: Prepare directories ---
mkdir -p "$METABASE_DIR"
cd "$METABASE_DIR"

# --- Step 5: Create custom Docker network ---
echo "🌐 Creating Docker network..."
docker network inspect $NETWORK_NAME >/dev/null 2>&1 || docker network create $NETWORK_NAME

# --- Step 6: Create docker-compose.yml ---
echo "🧾 Creating docker-compose.yml..."
cat > docker-compose.yml <<EOF
version: "3.8"
services:
  postgres:
    image: postgres:15
    container_name: metabase_postgres
    restart: unless-stopped
    networks:
      - $NETWORK_NAME
    environment:
      POSTGRES_USER: metabase
      POSTGRES_PASSWORD: "${DB_PASS}"
      POSTGRES_DB: metabase
    volumes:
      - pgdata:/var/lib/postgresql/data

  metabase:
    image: metabase/metabase
    container_name: metabase
    depends_on:
      - postgres
    restart: unless-stopped
    networks:
      - $NETWORK_NAME
    ports:
      - "${PORT}:3000"
    environment:
      MB_DB_TYPE: postgres
      MB_DB_DBNAME: metabase
      MB_DB_PORT: 5432
      MB_DB_USER: metabase
      MB_DB_PASS: "${DB_PASS}"
      MB_DB_HOST: postgres
      MB_JETTY_SSL: "false"
      MB_SITE_URL: https://${DOMAIN}
      MB_EMBEDDED: "true"

volumes:
  pgdata:

networks:
  $NETWORK_NAME:
    external: true
EOF

# --- Step 7: Run Docker ---
echo "🚀 Starting Metabase..."
docker compose down || true
docker compose up -d

# --- Step 8: Nginx Config ---
echo "🌐 Setting up Nginx..."
cat > /etc/nginx/sites-available/${DOMAIN} <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

ln -sf /etc/nginx/sites-available/${DOMAIN} /etc/nginx/sites-enabled/${DOMAIN}
nginx -t && systemctl reload nginx

# --- Step 9: SSL Certificate ---
echo "🔐 Requesting SSL certificate..."
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m ${EMAIL} || true

# --- Step 10: Fix redirect issue ---
echo "🧹 Fixing redirect environment..."
docker exec metabase bash -c 'unset MB_SITE_URL; unset MB_JETTY_SSL; echo "Metabase env cleaned."'
docker restart metabase

echo "===================================="
echo "✅ Metabase setup complete!"
echo "🌍 URL: https://${DOMAIN}/setup/"
echo "🗝️ DB Password: ${DB_PASS}"
echo "🚪 Port: ${PORT}"
echo "===================================="
