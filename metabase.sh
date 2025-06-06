#!/bin/bash

DOMAIN="yourdomain.com"
EMAIL="your-email@example.com"  # Replace with your real email

echo "🔧 Installing Docker, docker-compose, Nginx, and Certbot..."
sudo apt update
sudo apt install -y docker.io docker-compose nginx certbot python3-certbot-nginx

echo "✅ Enabling and starting Docker service..."
sudo systemctl enable docker
sudo systemctl start docker

echo "📁 Creating Metabase project directory..."
mkdir -p /opt/metabase
cd /opt/metabase

echo "🧾 Creating docker-compose.yml..."
cat <<EOF > docker-compose.yml
version: '3.8'

services:
  metabase:
    image: metabase/metabase
    container_name: metabase
    ports:
      - "3000:3000"
    volumes:
      - metabase-data:/metabase-data
    environment:
      MB_DB_FILE: /metabase-data/metabase.db
    restart: unless-stopped

volumes:
  metabase-data:
EOF

echo "🚀 Starting Metabase using docker-compose..."
docker-compose up -d

echo "🌐 Creating Nginx configuration for domain: $DOMAIN"
cat <<EOF | sudo tee /etc/nginx/sites-available/metabase
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:3000/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Enable the site and reload Nginx
sudo ln -s /etc/nginx/sites-available/metabase /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

echo "🔐 Requesting SSL certificate from Let's Encrypt..."
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

echo "🎉 Metabase is now running at: https://$DOMAIN"
