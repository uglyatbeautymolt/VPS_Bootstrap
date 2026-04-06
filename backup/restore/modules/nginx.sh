#!/bin/bash
# Restore: nginx
SRC="$STAGING/nginx"
[ ! -d "$SRC" ] && echo "nginx: Kein Backup gefunden" && exit 1
cp -r "$SRC/conf.d/." "$STACK_DIR/nginx/conf.d/" 2>/dev/null || true
docker compose -f "$STACK_DIR/docker-compose.yml" exec -T nginx \
  nginx -s reload 2>/dev/null || true
echo "nginx: Restore abgeschlossen"
