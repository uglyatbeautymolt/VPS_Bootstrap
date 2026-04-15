#!/bin/bash
# Modul: couchdb
# Sichert couchdb-data als tar.gz
STACK_DIR="/home/alex/ugly-stack"
DEST="$STAGING/couchdb-data"
mkdir -p "$DEST"

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$DEST/couchdb-backup-${DATE}.tar.gz"

# CouchDB stoppen fuer konsistentes Backup
docker compose -f "$STACK_DIR/docker-compose.yml" stop couchdb 2>/dev/null || true

# Direktes tar.gz vom couchdb-data Verzeichnis
tar -czf "$BACKUP_FILE" -C "$STACK_DIR/couchdb-data" .

# CouchDB wieder starten
docker compose -f "$STACK_DIR/docker-compose.yml" start couchdb 2>/dev/null || true

echo "CouchDB: Backup erstellt → $(basename $BACKUP_FILE)"
echo "  Inhalt: $(tar -tzf $BACKUP_FILE | wc -l) Dateien"
