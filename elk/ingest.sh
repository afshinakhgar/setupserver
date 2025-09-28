#!/usr/bin/env bash
set -euo pipefail

INGEST_URL_HOST="log.dotroot.ir"   # دامنه ELK
INGEST_PATH="/ingest"              # مسیر پروکسی روی Nginx
ELASTIC_USER="elastic"
: "${ELASTIC_PASSWORD:?export ELASTIC_PASSWORD before run}"

# نصب Filebeat اگر نیست:
if ! command -v filebeat >/dev/null 2>&1; then
  echo "Install Filebeat (Ubuntu)"
  sudo apt-get update
  sudo apt-get install -y filebeat
fi

sudo bash -c 'cat >/etc/filebeat/filebeat.yml' <<YML
filebeat.modules:
  - module: nginx
    access:
      enabled: true
      var.paths:
        - /var/log/nginx/*access*.log
    error:
      enabled: true
      var.paths:
        - /var/log/nginx/*error*.log

processors:
  - add_fields:
      target: project
      fields:
        site: "realaffiliate.com"

output.elasticsearch:
  hosts: ["https://${INGEST_URL_HOST}:443"]
  path: "${INGEST_PATH}"
  username: "${ELASTIC_USER}"
  password: "${ELASTIC_PASSWORD}"

setup.ilm.enabled: false   # این سرور فقط به الیاس می‌نویسد؛ ILM روی سرور اصلی است
logging.to_files: true
YML

sudo filebeat test output -e
sudo systemctl enable --now filebeat

# تست مستقیم (بدون filebeat) – یک داکیومنت خام:
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
curl -su "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
  -H 'Content-Type: application/json' \
  -XPOST "https://${INGEST_URL_HOST}${INGEST_PATH}/nginx-realaffiliate/_doc?refresh=true" \
  -d "{\"@timestamp\":\"$now\",\"message\":\"remote test log\",\"project\":{\"site\":\"realaffiliate.com\"},\"host\":{\"ip\":\"$(curl -s ifconfig.me || echo unknown)\"}}"
echo
