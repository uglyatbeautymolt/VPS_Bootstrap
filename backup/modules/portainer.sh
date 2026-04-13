#!/bin/bash
# Modul: portainer
DEST="$STAGING/portainer"
mkdir -p "$DEST"

# Portainer Container stoppen für konsistentes Backup
docker compose -f "$STACK_DIR/docker-compose.yml" stop portainer 2>/dev/null || true

# Named Volume sichern
docker run --rm \
  -v portainer-data:/source:ro \
  -v "$DEST":/backup \
  alpine tar -czf /backup/portainer-data.tar.gz -C /source .

# Portainer wieder starten
docker compose -f "$STACK_DIR/docker-compose.yml" start portainer 2>/dev/null || true

echo "portainer: $(du -sh $DEST/portainer-data.tar.gz 2>/dev/null | cut -f1) gesichert"
