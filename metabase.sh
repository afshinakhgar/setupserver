#!/bin/bash

# Interactive input
read -p "Enter your domain (default: example.com): " DOMAIN
DOMAIN=${DOMAIN:-example.com}

read -p "Enter your email address (for Let's Encrypt): " EMAIL
read -p "Enter port number for Metabase (default: 3000): " PORT
PORT=${PORT:-3000}

read -s -p "Enter password for PostgreSQL (used by Metabase): " DB_PASS
echo ""

echo "🔧 Preparing system and installing dependencies..."

# Fix possible containerd conflicts
sudo apt remove -y docker docker-engine docker.io containerd runc containerd.io >/dev/null 2>&1
sudo apt autoremove -y >/dev/null 2>&1
sudo apt update -y
sudo apt install -y ca-certificates curl gnupg lsb-release nginx certbot python3-certbot-nginx

# Install official Docker repo if missing
if ! command -v docker &> /dev/null; then
    echo "🐳 Installing official Docker Engine..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update -y
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# Enable and start Docker
sudo systemctl enable docker
sudo systemctl start docker

# Create Metabase directory
echo "📁 Setting up Metabase in /opt/metabase"
mkdir -p /opt/metabase
cd /opt/metabase || exit

# Write docker-compose.yml
cat <<EOF > docker-compose.yml
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

# Start Metabase
echo "🚀 Starting Metabase (this may take ~1 min)..."
docker compose up -d

# Create Nginx config
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
cat <<EOF | sudo tee $NGINX_CONF > /dev/null
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

# Enable site
sudo ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$DOMAIN"

# Test & reload Nginx
sudo nginx -t && sudo systemctl reload nginx

# Request or renew SSL
echo "🔐 Requesting SSL certificate for $DOMAIN..."
sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || true

echo "✅ Metabase is ready!"
echo "🌍 URL: https://$DOMAIN/setup/"
echo "🗝️ PostgreSQL password: $DB_PASS"
echo "🚪 Metabase port: $PORT"
