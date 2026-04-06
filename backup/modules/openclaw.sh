#!/bin/bash
# Modul: OpenClaw
# Nutzt den eingebauten "openclaw backup create" Befehl
# Sichert: State-Dir, Workspace, Credentials, Telegram-Session, Skills, Agents
STACK_DIR="/home/alex/ugly-stack"
DEST="$STAGING/openclaw-data"
mkdir -p "$DEST"

# Gateway stoppen für konsistentes Backup
docker compose -f "$STACK_DIR/docker-compose.yml" stop openclaw 2>/dev/null || true

# Eingebauten Backup-Befehl nutzen
docker run --rm \
  -v "$STACK_DIR/openclaw-data:/root/.openclaw" \
  -v "$DEST:/backup" \
  ghcr.io/openclaw/openclaw:latest \
  openclaw backup create --output /backup --verify

# Backup-Datei prüfen
BACKUP_FILE=$(ls "$DEST"/*.tar.gz 2>/dev/null | head -1)
if [ -z "$BACKUP_FILE" ]; then
  echo "OpenClaw: FEHLER — kein Backup erstellt"
  docker compose -f "$STACK_DIR/docker-compose.yml" start openclaw
  exit 1
fi

# Verifizieren
docker run --rm \
  -v "$DEST:/backup" \
  ghcr.io/openclaw/openclaw:latest \
  openclaw backup verify "/backup/$(basename $BACKUP_FILE)"

echo "OpenClaw: Backup erstellt und verifiziert → $(basename $BACKUP_FILE)"
echo "  Inhalt: $(tar -tzf $BACKUP_FILE | wc -l) Dateien"

# Gateway wieder starten
docker compose -f "$STACK_DIR/docker-compose.yml" start openclaw
