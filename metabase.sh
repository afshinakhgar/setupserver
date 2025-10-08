#!/bin/bash

# --- Input variables ---
read -p "Enter your domain (e.g. bi.giftooly.com): " DOMAIN
read -p "Enter your email address (for Let's Encrypt): " EMAIL
read -p "Enter port number for Metabase (default: 3003): " PORT
PORT=${PORT:-3003}

read -s -p "Enter password for PostgreSQL (used by Metabase): " DB_PASS
echo ""

# --- Install dependencies ---
echo "🔧 Installing Docker, docker-compose, Nginx, and Certbot..."
sudo apt update -y
sudo apt install -y docker.io docker-compose nginx certbot python3-certbot-nginx

sudo systemctl enable docker
sudo systemctl start docker

# --- Create project folder ---
mkdir -p /opt/metabase
cd /opt/metabase

# --- Create docker-compose.yml ---
cat <<EOF > docker-compose.yml
version: '3.8'

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
      MB_SITE_URL: https://${DOMAIN}
      MB_JETTY_SSL: "false"
      MB_EMBEDDED: "true"
      MB_REDIRECT_ALL_REQUESTS_TO_HTTPS: "false"
    restart: unless-stopped

volumes:
  pgdata:
EOF

# --- Run Docker ---
echo "🚀 Starting Metabase using Docker Compose..."
docker compose down -v
docker compose up -d

# --- Create Nginx config ---
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
cat <<EOF | sudo tee $NGINX_CONF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://localhost:$PORT/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

# --- Enable and reload Nginx ---
sudo ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$DOMAIN"
sudo nginx -t && sudo systemctl reload nginx

# --- Get SSL cert ---
echo "🔐 Requesting SSL certificate..."
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

# --- Done ---
echo "✅ Metabase is ready!"
echo "🌍 URL: https://${DOMAIN}/setup/"
echo "🗝️ PostgreSQL password: ${DB_PASS}"
echo "🚪 Metabase port: ${PORT}"
