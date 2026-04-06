#!/bin/bash
# Restore: OpenClaw
# Stellt das komplette State + Workspace Verzeichnis wieder her
STACK_DIR="/home/alex/ugly-stack"
SRC="$STAGING/openclaw-data"

# Backup-Datei finden
BACKUP_FILE=$(ls "$SRC"/*.tar.gz 2>/dev/null | head -1)
if [ -z "$BACKUP_FILE" ]; then
  echo "OpenClaw: Kein Backup gefunden in $SRC"
  exit 1
fi

echo "OpenClaw: Restore aus $(basename $BACKUP_FILE)"

# Ziel-Verzeichnis vorbereiten
# WICHTIG: altes openclaw-data sichern, nicht einfach löschen
if [ -d "$STACK_DIR/openclaw-data" ]; then
  mv "$STACK_DIR/openclaw-data" \
     "$STACK_DIR/openclaw-data.pre-restore.$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$STACK_DIR/openclaw-data"

# Backup entpacken direkt ins Volume
tar -xzf "$BACKUP_FILE" -C "$STACK_DIR/openclaw-data/"

# Korrekte Berechtigungen setzen
chown -R 1000:1000 "$STACK_DIR/openclaw-data/" 2>/dev/null || true

echo "OpenClaw: Restore abgeschlossen"
echo "  Beim Container-Start sind alle Daten verfügbar:"
echo "  MEMORY.md, USER.md, AGENTS.md, Skills, Credentials, Telegram-Session"
echo ""
echo "  Hinweis: Falls Telegram neu authentifiziert werden muss:"
echo "  docker exec -it ugly-agent openclaw gateway --setup"
