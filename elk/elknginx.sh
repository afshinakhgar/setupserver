#!/usr/bin/env bash
set -euo pipefail

### ====== تنظیم متغیرها ======
ES_HOST="https://127.0.0.1:9200"
KIBANA_PORT="5601"
PUBLIC_FQDN="log.dotroot.ir"
PUBLIC_URL="https://${PUBLIC_FQDN}"
ALLOW_INGEST_IPS=("127.0.0.1" "139.59.160.160")

# پسوردها از محیط؛ اگر نبود، خطا بده
: "${ELASTIC_PASSWORD:?set ELASTIC_PASSWORD env var}"      # مثلا afshin...
: "${KIBANA_SYSTEM_PASSWORD:?set KIBANA_SYSTEM_PASSWORD}"  # مثلا a136...

HTTP_CA="/etc/elasticsearch/certs/http_ca.crt"
KBN_CA="/etc/kibana/certs/http_ca.crt"

### ====== پیش‌نیازهای کرنل/حافظه (برای جلوگیری از OOM و خطای map count) ======
echo ">> Tune vm.max_map_count"
sudo sysctl -w vm.max_map_count=262144 >/dev/null
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf >/dev/null

# (اختیاری) کاهش heap ES برای جلوگیری از OOM (2GB)
sudo mkdir -p /etc/elasticsearch/jvm.options.d
sudo bash -c 'cat >/etc/elasticsearch/jvm.options.d/heap.options' <<'EOF'
-Xms2g
-Xmx2g
EOF

### ====== اطمینان از وجود CA و رفع مشکل دسترسی Kibana ======
if [[ ! -f "$HTTP_CA" ]]; then
  echo "!! CA not found at ${HTTP_CA}. Make sure Elasticsearch has generated http_ca.crt."
  exit 1
fi

sudo mkdir -p /etc/kibana/certs
sudo cp -f "$HTTP_CA" "$KBN_CA"
sudo chown root:kibana "$KBN_CA" || true
sudo chmod 0640 "$KBN_CA" || sudo chmod 0644 "$KBN_CA"

### ====== پیکربندی kibana.yml (با حل hostname و دسترسی CA) ======
sudo mkdir -p /etc/kibana
sudo bash -c "cat >/etc/kibana/kibana.yml" <<YML
# Auto-generated
server.name: "kibana"
server.host: "0.0.0.0"
server.publicBaseUrl: "${PUBLIC_URL}"

elasticsearch.hosts: ["${ES_HOST}"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${KIBANA_SYSTEM_PASSWORD}"
elasticsearch.ssl.certificateAuthorities: ["${KBN_CA}"]
# چون به 127.0.0.1 وصل می‌شویم و cert برای اسم دیگری‌ست:
elasticsearch.ssl.verificationMode: certificate

xpack.security.encryptionKey: "AB866i4TPOMj287ARMgTGMidKj81eMza5CL1mTBg+0GL8zF9qvwVyvePlJrFgToW"
xpack.encryptedSavedObjects.encryptionKey: "IlLV2IpkVjEreiD2GH9X8wDLeNg9hIDhKVFgPbFLIOJ1eOyh/2Whr4mpIIl6bff6"
xpack.reporting.encryptionKey: "qHMnxE6plfkl6Oujz9C4T+CS+1MmHbvnUOvVFyiQcY/WWAba+LnpO5HDu+WYvu73"

logging.root.level: info
YML

### ====== Nginx: تعریف log_format و vhost عمومی + مسیر /ingest ======
# 1) log_format main اگر نبود اضافه کن
if ! sudo grep -qE '^\s*log_format\s+main' /etc/nginx/nginx.conf; then
  echo ">> Inject log_format main into nginx.conf"
  sudo sed -i '/http\s*{/a \    log_format  main  '\
'\'$remote_addr - $remote_user [$time_local] "$request" '\
'$status $body_bytes_sent "$http_referer" '\
'"$http_user_agent" "$http_x_forwarded_for"';' /etc/nginx/nginx.conf
fi

# 2) vhost برای Kibana + /ingest (proxy به ES) + لاگ‌ها
sudo bash -c "cat >/etc/nginx/sites-available/${PUBLIC_FQDN}" <<NGINX
server {
    server_name ${PUBLIC_FQDN};
    set \$kibana http://127.0.0.1:${KIBANA_PORT};

    access_log /var/log/nginx/${PUBLIC_FQDN}.access.log main;
    error_log  /var/log/nginx/${PUBLIC_FQDN}.error.log;

    # Kibana UI
    location / {
        proxy_pass \$kibana;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
        proxy_set_header Accept-Encoding "";
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
        add_header Pragma "no-cache" always;
    }

    # مسیر اختصاصی اینجست به ES (با لیست سفید IP)
    location ^~ /ingest/ {
        # allowlist
$(for ip in "${ALLOW_INGEST_IPS[@]}"; do echo "        allow ${ip};"; done)
        deny all;

        proxy_pass ${ES_HOST}/;
        proxy_http_version 1.1;
        proxy_set_header Authorization \$http_authorization;  # Basic یا ApiKey از کلاینت
        proxy_ssl_verify off;                                # چون به 127.0.0.1 می‌زنیم
        proxy_set_header Host 127.0.0.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
        proxy_set_header Accept-Encoding "";
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
        access_log /var/log/nginx/${PUBLIC_FQDN}.ingest.access.log main;
    }

    listen 443 ssl;
    ssl_certificate     /etc/letsencrypt/live/${PUBLIC_FQDN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PUBLIC_FQDN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
server {
    if (\$host = ${PUBLIC_FQDN}) { return 301 https://\$host\$request_uri; }
    listen 80;
    server_name ${PUBLIC_FQDN};
    return 404;
}
NGINX

sudo ln -sf "/etc/nginx/sites-available/${PUBLIC_FQDN}" "/etc/nginx/sites-enabled/${PUBLIC_FQDN}"
sudo nginx -t
sudo systemctl reload nginx

### ====== راه‌اندازی/سلامت ES و Kibana ======
echo ">> Restart Elasticsearch & Kibana"
sudo systemctl restart elasticsearch || true
sudo systemctl restart kibana || true

echo ">> Wait for ES..."
for i in {1..60}; do
  if curl -sk --cacert "$HTTP_CA" -u "elastic:${ELASTIC_PASSWORD}" "${ES_HOST}/_cluster/health?pretty" >/dev/null; then break; fi
  sleep 2
done

echo ">> ES health:"
curl -sk --cacert "$HTTP_CA" -u "elastic:${ELASTIC_PASSWORD}" "${ES_HOST}/_cluster/health?pretty" | sed -n '1,12p' || true

echo ">> Kibana preboot check:"
curl -sI "http://127.0.0.1:${KIBANA_PORT}" | sed -n '1,5p' || true

### ====== Filebeat: ماژول nginx + برچسب پروژه ======
sudo mkdir -p /etc/filebeat
sudo bash -c 'cat >/etc/filebeat/filebeat.yml' <<'YML'
filebeat.modules:
  - module: nginx
    access:
      enabled: true
      var.paths:
        - /var/log/nginx/*access*.log
        - /var/log/nginx/*.access.log
    error:
      enabled: true
      var.paths:
        - /var/log/nginx/*error*.log
        - /var/log/nginx/*.error.log

processors:
  - add_fields:
      target: project
      fields:
        site: "realaffiliate.com"

output.elasticsearch:
  hosts: ["https://127.0.0.1:9200"]
  username: "elastic"
  password: "'"${ELASTIC_PASSWORD}"'"
  ssl:
    certificate_authorities: ["'"${HTTP_CA}"'"]
    verification_mode: certificate

setup.ilm.enabled: true
setup.template.enabled: true
logging.to_files: true
logging.files:
  path: /var/log/filebeat
  name: filebeat
  keepfiles: 7
  permissions: 0640
YML

sudo filebeat test config -e
sudo systemctl enable --now filebeat

### ====== ILM + Template + ایندکس/الیاس nginx-realaffiliate ======
echo ">> Create ILM policy (30d)"
curl -sk --cacert "$HTTP_CA" -u "elastic:${ELASTIC_PASSWORD}" \
  -XPUT "${ES_HOST}/_ilm/policy/nginx-logs-30d" -H 'Content-Type: application/json' -d '{
  "policy":{
    "phases":{
      "hot":{"actions":{"rollover":{"max_age":"1d","max_size":"10gb"}}},
      "delete":{"min_age":"30d","actions":{"delete":{}}}
    }
  }
}' >/dev/null

echo ">> Create index template for nginx-realaffiliate-*"
curl -sk --cacert "$HTTP_CA" -u "elastic:${ELASTIC_PASSWORD}" \
  -XPUT "${ES_HOST}/_index_template/nginx-realaffiliate-template" \
  -H 'Content-Type: application/json' -d '{
  "index_patterns": ["nginx-realaffiliate-*"],
  "template": {
    "settings": {
      "index.lifecycle.name": "nginx-logs-30d",
      "index.lifecycle.rollover_alias": "nginx-realaffiliate",
      "number_of_replicas": 0
    },
    "mappings": {
      "date_detection": true,
      "properties": {
        "@timestamp": {"type":"date"},
        "project":{"properties":{"site":{"type":"keyword"}}},
        "message":{"type":"text"}
      }
    }
  },
  "priority": 500
}' >/dev/null

echo ">> Bootstrap first write index + alias"
curl -sk --cacert "$HTTP_CA" -u "elastic:${ELASTIC_PASSWORD}" \
  -XPUT "${ES_HOST}/nginx-realaffiliate-000001" \
  -H 'Content-Type: application/json' -d '{
  "aliases": { "nginx-realaffiliate": { "is_write_index": true } }
}' >/dev/null || true

echo ">> Seed one test doc (ensures @timestamp mapping exists)"
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
curl -sk --cacert "$HTTP_CA" -u "elastic:${ELASTIC_PASSWORD}" \
  -XPOST "${ES_HOST}/nginx-realaffiliate/_doc?refresh=true" \
  -H 'Content-Type: application/json' -d "{
  \"@timestamp\":\"$now\",
  \"message\":\"bootstrap test\",
  \"project\":{\"site\":\"realaffiliate.com\"},
  \"sender\":\"setup-script\"
}" >/dev/null

echo ">> Done. Quick checks:"
curl -sk --cacert "$HTTP_CA" -u "elastic:${ELASTIC_PASSWORD}" "${ES_HOST}/_cat/indices/nginx-realaffiliate-*?v"
curl -sk --cacert "$HTTP_CA" -u "elastic:${ELASTIC_PASSWORD}" "${ES_HOST}/_cat/aliases/nginx-realaffiliate?v"
