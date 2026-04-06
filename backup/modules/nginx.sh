#!/bin/bash
# Modul: nginx
DEST="$STAGING/nginx"
mkdir -p "$DEST"
cp -r "$STACK_DIR/nginx/conf.d" "$DEST/" 2>/dev/null || true
echo "nginx: Konfiguration gesichert"
