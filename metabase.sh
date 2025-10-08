#!/bin/bash

# Ask for domain, email, port, and DB password interactively
read -p "Enter your domain (e.g. metabase.sabaai.ir): " DOMAIN
read -p "Enter your email address (for Let's Encrypt): " EMAIL
read -p "Enter port number for Metabase (default: 3000): " PORT
PORT=${PORT:-3000}  # Default to 3000 if empty

# Ask for PostgreSQL password (hidden input)
read -s -p "Enter password for PostgreSQL (used by Metabase): " DB_PASS
echo ""

# Update and install necessary packages
echo "🔧 Installing Docker, docker-compose, Nginx, and Certbot..."
sudo apt update
sudo apt install -y docker.io docker-compose nginx certbot python3-certbot-nginx

# Start and enable Docker
echo "✅ Enabling and starting Docker service..."
sudo systemctl enable docker
sudo systemctl start docker

# Create project directory
echo "📁 Creating Metabase project directory..."
mkdir -p /opt/metabase
cd /opt/metabase

# Create docker-compose.yml
echo "🧾 Creating docker-compose.yml (using port $PORT)..."
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
    restart: unless-stopped

volumes:
  pgdata:
EOF

# Start Metabase with docker-compose
echo "🚀 Starting Metabase using docker-compose on port $PORT..."
docker-compose up -d

# Create Nginx config for the domain
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
        proxy_pass http://localhost:$PORT/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

# Enable the Nginx site
sudo ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$DOMAIN"

# Test Nginx and reload
sudo nginx -t && sudo systemctl reload nginx

# Request SSL certificate
echo "🔐 Requesting SSL certificate from Let's Encrypt..."
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

# Done
echo "🎉 Metabase is now running at: https://$DOMAIN (proxied to localhost:$PORT)"
echo "🗝️ PostgreSQL password you entered: ${DB_PASS}"
