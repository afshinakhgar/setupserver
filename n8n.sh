#!/bin/bash
set -e

echo "Domain (e.g. n8n.example.com): "
read DOMAIN

echo "Email for Let's Encrypt (used only if cert missing): "
read EMAIL

# -------------------------------
# 1) Vars
# -------------------------------
BASE_DIR="/opt/n8n/$DOMAIN"
DATA_DIR="$BASE_DIR/data"
ENV_FILE="$BASE_DIR/.env"
CONTAINER_NAME="n8n-${DOMAIN//./-}"

# -------------------------------
# 2) Pick free port
# -------------------------------
PORT=5680
while ss -lnt | awk '{print $4}' | grep -q ":$PORT$"; do
  PORT=$((PORT+1))
done
echo "[+] Using free port $PORT for $DOMAIN"

# -------------------------------
# 3) Prepare folders & permissions
# -------------------------------
mkdir -p "$DATA_DIR"
# Fix permissions for n8n user inside container
chown -R 1000:1000 "$DATA_DIR"
chmod -R 755 "$DATA_DIR"

# -------------------------------
# 4) Create .env
# -------------------------------
cat > "$ENV_FILE" <<EOF
N8N_PORT=5678
N8N_EDITOR_BASE_URL=https://$DOMAIN/
WEBHOOK_URL=https://$DOMAIN/
EOF
chown 1000:1000 "$ENV_FILE"
chmod 644 "$ENV_FILE"

# -------------------------------
# 5) Nginx config (HTTP for certbot)
# -------------------------------
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
mkdir -p /var/www/letsencrypt
nginx -t && systemctl reload nginx

# -------------------------------
# 6) Issue cert if not exists
# -------------------------------
if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  certbot certonly --webroot -w /var/www/letsencrypt -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive
fi

# -------------------------------
# 7) Final nginx (HTTPS + proxy)
# -------------------------------
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
EOF

nginx -t && systemctl reload nginx

# -------------------------------
# 8) Run container
# -------------------------------
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p 127.0.0.1:$PORT:5678 \
  -v "$DATA_DIR:/home/node/.n8n" \
  --env-file "$ENV_FILE" \
  n8nio/n8n

echo
echo "[✓] n8n deployed at: https://$DOMAIN"
echo "[i] Container: $CONTAINER_NAME"
echo "[i] Local port: $PORT"
