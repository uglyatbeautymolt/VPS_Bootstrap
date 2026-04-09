#!/bin/bash
# Modul: OpenClaw
# Sichert openclaw-data als tar.gz (kompatibel mit restore/modules/openclaw.sh)
STACK_DIR="/home/alex/ugly-stack"
DEST="$STAGING/openclaw-data"
mkdir -p "$DEST"

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$DEST/openclaw-backup-${DATE}.tar.gz"

# Gateway stoppen für konsistentes Backup
docker compose -f "$STACK_DIR/docker-compose.yml" stop openclaw 2>/dev/null || true

# tar mit sudo damit 1000:1000 Ownership kein Problem ist
sudo tar -czf "$BACKUP_FILE" -C "$STACK_DIR/openclaw-data" .

# Gateway wieder starten
docker compose -f "$STACK_DIR/docker-compose.yml" start openclaw 2>/dev/null || true

FILE_COUNT=$(tar -tzf "$BACKUP_FILE" 2>/dev/null | wc -l)
echo "OpenClaw: Backup erstellt → $(basename $BACKUP_FILE)"
echo "  Inhalt: ${FILE_COUNT} Dateien"

# Fehler wenn Backup leer ist
if [ "$FILE_COUNT" -lt 5 ]; then
  echo "OpenClaw: FEHLER — Backup hat nur ${FILE_COUNT} Dateien (Permission denied?)"
  exit 1
fi
