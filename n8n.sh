#!/usr/bin/env bash
set -euo pipefail

# ======== n8n + Nginx + Certbot (Cloudflare-ready) all-in-one ========
# Sequence:
# 1) Ensure ssl option files exist (avoid nginx -t failures from other vhosts)
# 2) Write HTTP site in sites-available/<domain> and symlink to sites-enabled/
# 3) Reload Nginx, then issue cert (DNS-01 via Cloudflare if token provided; else webroot)
# 4) Write HTTPS reverse-proxy block (your style), reload Nginx
# 5) Run n8n in Docker at 127.0.0.1:<PORT>, generate/reuse encryption key
# =====================================================================

log(){ printf "\033[1;32m[+] %s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
die(){ printf "\033[1;31m[✗] %s\033[0m\n" "$*"; exit 1; }
has(){ command -v "$1" >/dev/null 2>&1; }

# -------- Inputs --------
read -rp "Domain (e.g. n8n.dotroot.ir): " DOMAIN
read -rp "Email for Let's Encrypt: " EMAIL
read -rp "Local port for n8n [5678]: " PORT; PORT="${PORT:-5678}"

echo "Use Cloudflare DNS API for DNS A record + DNS-01 issuance? (y/N)"
read -r CF_USE; CF_USE="${CF_USE:-N}"

CF_API_TOKEN=""; CF_ZONE_NAME=""; CF_ZONE_ID=""
if [[ "$CF_USE" =~ ^[Yy]$ ]]; then
  read -rp "Cloudflare API Token (Zone:DNS Edit): " CF_API_TOKEN
  read -rp "Cloudflare Zone name (root, e.g. dotroot.ir): " CF_ZONE_NAME
fi

# -------- Ensure packages --------
log "Ensuring docker, nginx, certbot, curl, jq, openssl..."
apt-get update -y >/dev/null 2>&1 || true
has docker  || apt-get install -y docker.io >/dev/null 2>&1
has nginx   || apt-get install -y nginx >/dev/null 2>&1
has certbot || apt-get install -y certbot >/dev/null 2>&1
has curl    || apt-get install -y curl >/dev/null 2>&1
has jq      || apt-get install -y jq >/dev/null 2>&1
has openssl || apt-get install -y openssl >/dev/null 2>&1
systemctl enable --now docker >/dev/null 2>&1 || true
systemctl enable --now nginx  >/dev/null 2>&1 || true

# Cloudflare plugin for DNS-01
if [[ -n "$CF_API_TOKEN" && -n "$CF_ZONE_NAME" ]]; then
  apt-get install -y python3-certbot-dns-cloudflare >/dev/null 2>&1 || die "dns-cloudflare plugin install failed"
fi

# -------- Paths --------
N8N_DIR="/opt/n8n"
ENV_FILE="${N8N_DIR}/.env"
SETTINGS_FILE="${N8N_DIR}/.n8n/config"
WEBROOT="/var/www/letsencrypt"
SITE_AVAIL="/etc/nginx/sites-available/${DOMAIN}"
SITE_ENAB="/etc/nginx/sites-enabled/${DOMAIN}"
WS_MAP_CONF="/etc/nginx/conf.d/websocket_map.conf"
CF_CREDS="/root/.secrets/certbot/cloudflare.ini"

# ssl option files: create canonical in letsencrypt and also symlink under /etc/nginx/
LE_OPT_SSL="/etc/letsencrypt/options-ssl-nginx.conf"
LE_DH_PARAMS="/etc/letsencrypt/ssl-dhparams.pem"
NGX_OPT_SSL="/etc/nginx/options-ssl-nginx.conf"

# -------- Pre-create ssl option files (and nginx symlink) --------
if [[ ! -f "$LE_OPT_SSL" ]]; then
  log "Fetching $LE_OPT_SSL ..."
  curl -fsSL https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/options-ssl-nginx.conf -o "$LE_OPT_SSL" || die "Failed to fetch options-ssl-nginx.conf"
fi
if [[ ! -f "$LE_DH_PARAMS" ]]; then
  log "Fetching $LE_DH_PARAMS ..."
  curl -fsSL https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem -o "$LE_DH_PARAMS" || die "Failed to fetch ssl-dhparams.pem"
fi
# Symlink under /etc/nginx/ for vhosts that include that path
if [[ ! -f "$NGX_OPT_SSL" ]]; then
  ln -sf "$LE_OPT_SSL" "$NGX_OPT_SSL"
fi

# -------- Port check --------
if ss -ltn "( sport = :$PORT )" | grep -q "$PORT"; then
  warn "Port $PORT busy; trying 5679..."
  PORT=5679
  if ss -ltn "( sport = :$PORT )" | grep -q "$PORT"; then
    die "Both 5678 and 5679 are busy. Choose a free port and re-run."
  fi
  log "Using PORT=$PORT"
fi

# -------- WebSocket map (once) --------
if [[ ! -f "${WS_MAP_CONF}" ]]; then
  log "Writing ${WS_MAP_CONF} ..."
  cat > "${WS_MAP_CONF}" <<'MAP'
# Map Upgrade header for WebSocket
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
MAP
fi

# -------- HTTP site FIRST, then symlink & reload --------
log "Writing HTTP site at ${SITE_AVAIL} ..."
mkdir -p "${WEBROOT}/.well-known/acme-challenge"
chown -R www-data:www-data "${WEBROOT}"

cat > "${SITE_AVAIL}" <<HTTP
server {
    listen 80;
    server_name ${DOMAIN};

    # ACME challenge
    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type "text/plain";
        allow all;
    }

    # Redirect the rest (will work after cert issuance)
    location / {
        return 301 https://\$host\$request_uri;
    }
}
HTTP

ln -sf "${SITE_AVAIL}" "${SITE_ENAB}"
nginx -t && systemctl reload nginx

# -------- Cloudflare DNS (optional) --------
if [[ -n "$CF_API_TOKEN" && -n "$CF_ZONE_NAME" ]]; then
  log "Cloudflare: locating Zone ID for ${CF_ZONE_NAME}..."
  CF_ZONE_ID="$(curl -fsS -X GET \
     -H "Authorization: Bearer ${CF_API_TOKEN}" \
     -H "Content-Type: application/json" \
     "https://api.cloudflare.com/client/v4/zones?name=${CF_ZONE_NAME}&status=active" \
     | jq -r '.result[0].id // empty')"
  [[ -z "$CF_ZONE_ID" ]] && die "Could not find Zone ID for ${CF_ZONE_NAME}"

  log "Cloudflare: creating/updating A ${DOMAIN} to this server public IP..."
  mkdir -p "$(dirname "$CF_CREDS")"
  chmod 700 "$(dirname "$CF_CREDS")"
  echo "dns_cloudflare_api_token = ${CF_API_TOKEN}" > "$CF_CREDS"
  chmod 600 "$CF_CREDS"

  PUBIP="$(curl -fsS https://api.ipify.org || curl -fsS https://ifconfig.me || true)"
  [[ -z "$PUBIP" ]] && die "Cannot detect public IP."

  REC_JSON="$(curl -fsS -X GET \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=${DOMAIN}")"
  REC_ID="$(echo "$REC_JSON" | jq -r '.result[0].id // empty')"
  PROXIED=true
  if [[ -n "$REC_ID" ]]; then
    curl -fsS -X PUT \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${REC_ID}" \
      --data "{\"type\":\"A\",\"name\":\"${DOMAIN}\",\"content\":\"${PUBIP}\",\"ttl\":120,\"proxied\":${PROXIED}}" >/dev/null
  else
    curl -fsS -X POST \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
      --data "{\"type\":\"A\",\"name\":\"${DOMAIN}\",\"content\":\"${PUBIP}\",\"ttl\":120,\"proxied\":${PROXIED}}" >/dev/null
  fi
  log "Cloudflare DNS A set (proxied=true)."
else
  warn "Skipping Cloudflare API. For webroot issuance behind CF, disable proxy (gray-cloud) temporarily."
fi

# -------- Issue certificate --------
if [[ -n "$CF_API_TOKEN" && -n "$CF_ZONE_NAME" ]]; then
  log "Issuing certificate via DNS-01 (Cloudflare)..."
  certbot certonly --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_CREDS" \
    -d "${DOMAIN}" \
    -m "${EMAIL}" --agree-tos -n
else
  warn "Using webroot issuance (ACME over HTTP). If behind Cloudflare, gray-cloud is required."
  certbot certonly --webroot -w "${WEBROOT}" \
    -d "${DOMAIN}" \
    -m "${EMAIL}" --agree-tos -n
fi

# -------- Write HTTPS reverse proxy (your style), keep HTTP --------
log "Writing HTTPS reverse proxy block..."
cat > "${SITE_AVAIL}" <<SSL
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    # Use the correct certs for ${DOMAIN}
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/nginx/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    client_max_body_size 32m;

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;

        # Forward headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support (requires 'map' once in http{})
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}

# Keep HTTP for ACME + redirect
server {
    listen 80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${WEBROOT};
        default_type "text/plain";
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
SSL

ln -sf "${SITE_AVAIL}" "${SITE_ENAB}"
nginx -t && systemctl reload nginx

# -------- n8n data + env --------
log "Preparing n8n data and env..."
mkdir -p "${N8N_DIR}"/{.n8n,files}
chown -R 1000:1000 "${N8N_DIR}"/.n8n "${N8N_DIR}"/files
chmod -R u+rwX,go-rwx "${N8N_DIR}"/.n8n "${N8N_DIR}"/files

ENCKEY=""
if [[ -f "$SETTINGS_FILE" ]] && grep -q '"encryptionKey"' "$SETTINGS_FILE"; then
  ENCKEY="$(sed -n 's/.*"encryptionKey":\s*"\([^"]\+\)".*/\1/p' "$SETTINGS_FILE" | head -1 || true)"
fi
[[ -z "$ENCKEY" ]] && ENCKEY="$(openssl rand -hex 32)"

cat > "${ENV_FILE}" <<EOF
# Core
N8N_HOST=${DOMAIN}
N8N_PORT=${PORT}
N8N_PROTOCOL=https
N8N_PUBLIC_URL=https://${DOMAIN}/
N8N_EDITOR_BASE_URL=https://${DOMAIN}/
WEBHOOK_URL=https://${DOMAIN}/

# Security
N8N_ENCRYPTION_KEY=${ENCKEY}
N8N_DIAGNOSTICS_ENABLED=false
N8N_HIRING_BANNER_ENABLED=false
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true

# DB (SQLite)
DB_TYPE=sqlite
DB_SQLITE_PATH=/home/node/.n8n/database.sqlite
DB_SQLITE_POOL_SIZE=5

# Runners
N8N_RUNNERS_ENABLED=true

# Safer default
N8N_BLOCK_ENV_ACCESS_IN_NODE=true
EOF
chown 1000:1000 "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

# -------- Run n8n (Docker) --------
log "Launching n8n on 127.0.0.1:${PORT}..."
docker rm -f n8n >/dev/null 2>&1 || true
docker run -d --name n8n --restart unless-stopped \
  -p 127.0.0.1:${PORT}:5678 \
  -v "${N8N_DIR}/.n8n:/home/node/.n8n" \
  -v "${N8N_DIR}/files:/files" \
  --env-file "${ENV_FILE}" \
  n8nio/n8n:latest >/dev/null

# Tighten settings file if present
for _ in {1..10}; do
  [[ -f "$SETTINGS_FILE" ]] && { chmod 600 "$SETTINGS_FILE" || true; chown 1000:1000 "$SETTINGS_FILE" || true; break; }
  sleep 1
done

# -------- Health checks --------
log "Checking n8n health..."
for i in {1..30}; do
  if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    log "n8n healthy at http://127.0.0.1:${PORT}/healthz"
    break
  fi
  sleep 1
done

echo
log "DONE. Save your encryption key (N8N_ENCRYPTION_KEY):"
echo "------------------------------------------------------------"
echo "${ENCKEY}"
echo "------------------------------------------------------------"
echo "n8n URL        : https://${DOMAIN}/"
echo "Local health   : curl -sS http://127.0.0.1:${PORT}/healthz"
echo "Docker logs    : docker logs -f n8n"
echo "Site file      : ${SITE_AVAIL}"
echo "Symlink        : ${SITE_ENAB}"
echo "Renewal (cron) : certbot renew --quiet"
