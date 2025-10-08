#!/bin/bash

# === Step 1: Read configuration ===
read -p "Enter your domain (default: example.com): " DOMAIN
DOMAIN=${DOMAIN:-example.com}

read -p "Enter your email address (for Let's Encrypt): " EMAIL
read -p "Enter port number for Metabase (default: 3000): " PORT
PORT=${PORT:-3000}

read -s -p "Enter password for PostgreSQL (used by Metabase): " DB_PASS
echo ""

# === Step 2: Install dependencies ===
echo "🔧 Installing Docker, docker-compose, Nginx, and Certbot..."
sudo apt update -y
sudo apt install -y docker.io docker-compose nginx certbot python3-certbot-nginx curl

echo "✅ Enabling and starting Docker service..."
sudo systemctl enable docker
sudo systemctl start docker

# === Step 3: Create Metabase project ===
echo "📁 Creating Metabase project directory..."
mkdir -p /opt/metabase
cd /opt/metabase

# === Step 4: Create docker-compose.yml ===
echo "🧾 Creating docker-compose.yml (using port $PORT)..."
cat <<EOF > docker-compose.yml
services:
  postgres:
    image: postgres:15
    container_name: metabase_postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: metabase
      POSTGRES_PASSWORD: "$DB_PASS"
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
      MB_DB_PASS: "$DB_PASS"
      MB_DB_HOST: postgres
    restart: unless-stopped

volumes:
  pgdata:
EOF

# === Step 5: Start Metabase ===
echo "🚀 Starting Metabase using Docker Compose..."
docker compose down >/dev/null 2>&1
docker compose up -d

# === Step 6: Nginx configuration ===
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
echo "🌐 Creating Nginx configuration for domain: $DOMAIN"
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
        proxy_pass http://localhost:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

sudo ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$DOMAIN"
sudo nginx -t && sudo systemctl reload nginx

# === Step 7: SSL Certificate ===
echo "🔐 Requesting SSL certificate from Let's Encrypt..."
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL || true

# === Step 8: Health Check ===
echo "🩺 Checking if Metabase is ready..."
for i in {1..30}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$PORT/api/health)
  if [ "$STATUS" == "200" ]; then
    echo "✅ Metabase is healthy and ready!"
    break
  fi
  echo "⏳ Waiting for Metabase to start ($i/30)..."
  sleep 5
done

# === Step 9: Final Info ===
echo ""
echo "🎉 Metabase setup complete!"
echo "🌍 URL: https://$DOMAIN/setup/"
echo "🗝️ PostgreSQL password: $DB_PASS"
echo "🚪 Metabase port: $PORT"
