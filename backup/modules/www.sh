#!/bin/bash
# Modul: www
DEST="$STAGING/www"
mkdir -p "$DEST"
cp -r "$STACK_DIR/www/." "$DEST/" 2>/dev/null || true
echo "www: $(find $DEST -type f 2>/dev/null | wc -l) Dateien gesichert"
