#!/bin/bash
# Restore: portainer
SRC="$STAGING/portainer"
[ ! -f "$SRC/portainer-data.tar.gz" ] && echo "portainer: Kein Backup gefunden" && exit 1

# Portainer stoppen
docker compose -f "$STACK_DIR/docker-compose.yml" stop portainer 2>/dev/null || true

# Volume leeren und wiederherstellen
docker run --rm \
  -v portainer-data:/target \
  -v "$SRC":/backup \
  alpine sh -c "rm -rf /target/* && tar -xzf /backup/portainer-data.tar.gz -C /target"

# Portainer starten
docker compose -f "$STACK_DIR/docker-compose.yml" start portainer 2>/dev/null || true

echo "portainer: Restore abgeschlossen"
