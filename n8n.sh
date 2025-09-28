#!/bin/bash
set -e

echo "Domain (e.g. n8n.dotroot.ir): "
read DOMAIN

echo "Email for Let's Encrypt (e.g. you@example.com): "
read EMAIL

echo "Local port to map (e.g. 5680): "
read HOST_PORT

DATA_DIR="/opt/n8n/$DOMAIN"
ENV_FILE="$DATA_DIR/.env"
CONTAINER_NAME="n8n-${DOMAIN//./-}"

mkdir -p "$DATA_DIR/data"

# ✅ Create .env file
cat > "$ENV_FILE" <<EOF
N8N_HOST=$DOMAIN
N8N_PORT=5678
WEBHOOK_URL=https://$DOMAIN/
GENERIC_TIMEZONE=UTC
DB_SQLITE_POOL_SIZE=2
N8N_RUNNERS_ENABLED=true
N8N_BLOCK_ENV_ACCESS_IN_NODE=false
EOF

echo "[+] .env created at $ENV_FILE"

# ✅ Run docker container
docker stop $CONTAINER_NAME >/dev/null 2>&1 || true
docker rm $CONTAINER_NAME >/dev/null 2>&1 || true

docker run -d \
  --name $CONTAINER_NAME \
  --restart unless-stopped \
  -p 127.0.0.1:$HOST_PORT:5678 \
  -v $DATA_DIR/data:/home/node/.n8n \
  --env-file $ENV_FILE \
  n8nio/n8n

echo "[+] Container $CONTAINER_NAME started on 127.0.0.1:$HOST_PORT"

# ✅ Create Nginx config
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

# ✅ Get SSL cert
certbot certonly --webroot -w /var/www/letsencrypt -d $DOMAIN --email $EMAIL --agree-tos --non-interactive

# ✅ Replace Nginx config with SSL version
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
        proxy_pass http://127.0.0.1:$HOST_PORT;
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

echo "[+] Deployment complete. Access: https://$DOMAIN"
