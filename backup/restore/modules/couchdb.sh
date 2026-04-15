#!/bin/bash
# Restore: CouchDB
STACK_DIR="/home/alex/ugly-stack"
SRC="$STAGING/couchdb-data"

BACKUP_FILE=$(ls "$SRC"/*.tar.gz 2>/dev/null | head -1)
if [ -z "$BACKUP_FILE" ]; then
  echo "CouchDB: Kein Backup gefunden in $SRC"
  exit 1
fi

echo "CouchDB: Restore aus $(basename $BACKUP_FILE)"

# Altes Verzeichnis sichern
if [ -d "$STACK_DIR/couchdb-data" ]; then
  mv "$STACK_DIR/couchdb-data" \
     "$STACK_DIR/couchdb-data.pre-restore.$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$STACK_DIR/couchdb-data"

# Backup entpacken
tar -xzf "$BACKUP_FILE" -C "$STACK_DIR/couchdb-data/"

# CouchDB laeuft als uid 5984
chown -R 5984:5984 "$STACK_DIR/couchdb-data/" 2>/dev/null || true

echo "CouchDB: Restore abgeschlossen"
