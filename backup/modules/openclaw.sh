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

# Direktes tar.gz vom openclaw-data Verzeichnis
tar -czf "$BACKUP_FILE" -C "$STACK_DIR/openclaw-data" .

# Gateway wieder starten
docker compose -f "$STACK_DIR/docker-compose.yml" start openclaw 2>/dev/null || true

echo "OpenClaw: Backup erstellt → $(basename $BACKUP_FILE)"
echo "  Inhalt: $(tar -tzf $BACKUP_FILE | wc -l) Dateien"
