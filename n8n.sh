#!/bin/bash
set -e

echo "=== Multi n8n Setup Script ==="

# Prompt domain and email
read -rp "Enter domain (e.g. n8naparat.dotroot.ir): " DOMAIN
read -rp "Enter email for Let's Encrypt: " EMAIL
read -rp "Enter internal port (e.g. 5680, 5681...): " PORT

# Vars
APP_DIR="/opt/n8n/$DOMAIN"
DATA_DIR="$APP_DIR/data"
ENV_FILE="$APP_DIR/.env"
CONTAINER_NAME="n8n-${DOMAIN//./-}"

echo "[+] Creating directories..."
mkdir -p "$DATA_DIR"

# Generate random credentials
DB_ENC_KEY=$(openssl rand -hex 16)
GENERIC_SECRET=$(openssl rand -hex 16)

echo "[+] Writing $ENV_FILE ..."
cat > "$ENV_FILE" <<EOF
N8N_HOST=$DOMAIN
N8N_PORT=5678
WEBHOOK_URL=https://$DOMAIN/
N8N_ENCRYPTION_KEY=$DB_ENC_KEY
N8N_USER_MANAGEMENT_JWT_SECRET=$GENERIC_SECRET
EOF

echo "[+] Starting Docker container: $CONTAINER_NAME ..."
docker run -d \
  --name $CONTAINER_NAME \
  --restart unless-stopped \
  -p 127.0.0.1:$PORT:5678 \
  -v $DATA_DIR:/home/node/.n8n \
  --env-file $ENV_FILE \
  n8nio/n8n

echo "[+] Writing Nginx config for $DOMAIN ..."
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$DOMAIN"
nginx -t && systemctl reload nginx

echo "[+] Issuing SSL certificate with certbot ..."
certbot certonly --webroot -w /var/www/letsencrypt -d $DOMAIN --email $EMAIL --agree-tos --non-interactive

echo "[+] Writing HTTPS config ..."
cat > "$NGINX_CONF" <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    client_max_body_size 32m;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}

server {
    listen 80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

nginx -t && systemctl reload nginx

echo "================================================="
echo "✅ n8n available at: https://$DOMAIN"
echo "   Container: $CONTAINER_NAME"
echo "   Port: $PORT"
echo "   Env: $ENV_FILE"
echo "================================================="
