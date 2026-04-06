#!/bin/bash
# Restore: n8n — Container muss laufen
SRC="$STAGING/n8n-data"
[ ! -d "$SRC" ] && echo "n8n: Kein Backup gefunden" && exit 1
docker cp "$SRC/workflows-backup.json"   n8n:/home/node/.n8n/ 2>/dev/null || true
docker cp "$SRC/credentials-backup.json" n8n:/home/node/.n8n/ 2>/dev/null || true
docker compose -f "$STACK_DIR/docker-compose.yml" exec -T n8n \
  n8n import:workflow --input=/home/node/.n8n/workflows-backup.json 2>/dev/null || true
docker compose -f "$STACK_DIR/docker-compose.yml" exec -T n8n \
  n8n import:credentials --input=/home/node/.n8n/credentials-backup.json 2>/dev/null || true
echo "n8n: Restore abgeschlossen"
