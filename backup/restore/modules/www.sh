#!/bin/bash
# Restore: www
SRC="$STAGING/www"
[ ! -d "$SRC" ] && echo "www: Kein Backup gefunden" && exit 1
cp -r "$SRC/." "$STACK_DIR/www/" 2>/dev/null || true
echo "www: Restore abgeschlossen"
