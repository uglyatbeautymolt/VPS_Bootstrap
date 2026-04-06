#!/bin/bash
# Modul: n8n — Workflows + Credentials exportieren
DEST="$STAGING/n8n-data"
mkdir -p "$DEST"
docker compose -f "$STACK_DIR/docker-compose.yml" exec -T n8n \
  n8n export:workflow --all --output=/home/node/.n8n/workflows-backup.json 2>/dev/null || true
docker compose -f "$STACK_DIR/docker-compose.yml" exec -T n8n \
  n8n export:credentials --all --output=/home/node/.n8n/credentials-backup.json 2>/dev/null || true
docker cp n8n:/home/node/.n8n/workflows-backup.json    "$DEST/" 2>/dev/null || true
docker cp n8n:/home/node/.n8n/credentials-backup.json  "$DEST/" 2>/dev/null || true
echo "n8n: Workflows + Credentials gesichert"
