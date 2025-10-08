#!/bin/bash
set -e

DOMAIN=${1:-example.com}
PORT=${2:-3004}
DB_PASS=$(openssl rand -base64 12)
METABASE_DIR="/opt/metabase"

echo "🚀 Setting up Metabase for domain: $DOMAIN (port: $PORT)"

# --- Step 1: Install dependencies ---
echo "📦 Installing dependencies..."
apt update -y
apt install -y curl gnupg2 ca-certificates lsb-release apt-transport-https software-properties-common python3-certbot-nginx

# --- Step 2: Fix Docker conflicts ---
echo "🐳 Checking Docker installation..."
apt remove -y containerd.io containerd docker.io docker-ce docker-ce-cli docker-ce-rootless-extras || true
apt autoremove -y
apt update -y
curl -fsSL https://get.docker.com | bash
systemctl enable --now docker

# --- Step 3: Prepare folders ---
mkdir -p "$METABASE_DIR"
cd "$METABASE_DIR"

# --- Step 4: Create docker-compose.yml ---
cat > docker-compose.yml <<EOF
services:
  postgres:
    image: postgres:15
    container_name: metabase_postgres
    restart: unless-stopped
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
    ports:
      - "${PORT}:3000"
    environment:
      MB_DB_TYPE: postgres
      MB_DB_DBNAME: metabase
      MB_DB_PORT: 5432
      MB_DB_USER: metabase
      MB_DB_PASS: "${DB_PASS}"
      MB_DB_HOST: postgres
    restart: unless-stopped

volumes:
  pgdata:
EOF

# --- Step 5: Start Metabase ---
echo "🚀 Starting Metabase (this may take ~1 min)..."
docker compose down || true
docker compose up -d

# --- Step 6: Configure Nginx ---
echo "🌐 Configuring Nginx for ${DOMAIN}..."
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
        proxy_pass http://localhost:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

ln -sf /etc/nginx/sites-available/${DOMAIN} /etc/nginx/sites-enabled/${DOMAIN}
nginx -t
systemctl reload nginx

# --- Step 7: Setup SSL ---
echo "🔐 Requesting SSL certificate for ${DOMAIN}..."
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos -m admin@${DOMAIN} || true

# --- Step 8: Cleanup MB_SITE_URL if exists ---
echo "🧹 Resetting MB_SITE_URL to prevent redirect loops..."
docker exec -it metabase bash -c 'unset MB_SITE_URL; echo "MB_SITE_URL cleared"'

# --- Step 9: Restart Metabase ---
docker restart metabase

echo "✅ Metabase setup completed!"
echo "🌍 URL: https://${DOMAIN}/setup/"
echo "🗝️ PostgreSQL password: ${DB_PASS}"
echo "🚪 Metabase port: ${PORT}"
