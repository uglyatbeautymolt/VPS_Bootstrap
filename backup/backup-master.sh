#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  Ugly Stack — Backup Master
#  Cron: 0 3 * * * /home/alex/ugly-stack/backup/backup-master.sh
# ─────────────────────────────────────────────────────────────
set -e

STACK_DIR="/home/alex/ugly-stack"
MODULES_DIR="$STACK_DIR/backup/modules"
STAGING="/tmp/ugly-backup-staging"
LOG="$STACK_DIR/backup/backup.log"
DATE=$(date '+%Y-%m-%d_%H-%M-%S')
FILENAME="backup-${DATE}.tar.gz.gpg"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [✓] $1" | tee -a "$LOG"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [✗] $1" | tee -a "$LOG"; }
info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [→] $1" | tee -a "$LOG"; }

echo "" >> "$LOG"
info "════════ Backup Start ════════"

source "$STACK_DIR/.env"

# Staging mit gleicher Struktur wie Stack-Verzeichnis
rm -rf "$STAGING"
mkdir -p "$STAGING"/{openclaw-data,n8n-data,nginx,www}

# Module ausführen
ERRORS=0
for MODULE in "$MODULES_DIR"/*.sh; do
  NAME=$(basename "$MODULE" .sh)
  info "Modul: $NAME"
  if STAGING="$STAGING" STACK_DIR="$STACK_DIR" bash "$MODULE" >> "$LOG" 2>&1; then
    log "$NAME — OK"
  else
    fail "$NAME — FEHLER"
    ERRORS=$((ERRORS + 1))
  fi
done

# tar.gz + GPG verschlüsseln
info "Erstelle verschlüsseltes Backup..."
tar -czf - -C "$STAGING" . | \
  gpg --batch --yes --symmetric \
      --cipher-algo AES256 \
      --passphrase "$BACKUP_GPG_PASSWORD" \
      -o "/tmp/$FILENAME"

SIZE=$(du -sh "/tmp/$FILENAME" | cut -f1)
log "Backup erstellt: $FILENAME ($SIZE)"

# Zu R2 hochladen
info "Upload zu Cloudflare R2..."
rclone copy "/tmp/$FILENAME" "r2:${CF_R2_BUCKET}/backups/" \
  --config "$STACK_DIR/rclone/rclone.conf"
log "Upload OK"

# Aufräumen
rm -f "/tmp/$FILENAME"
rm -rf "$STAGING"

# Letzte 7 Backups behalten
BACKUPS=$(rclone ls "r2:${CF_R2_BUCKET}/backups/" \
  --config "$STACK_DIR/rclone/rclone.conf" \
  | sort | awk '{print $2}')
COUNT=$(echo "$BACKUPS" | grep -c . || true)
if [ "$COUNT" -gt 7 ]; then
  TO_DELETE=$(echo "$BACKUPS" | head -n $((COUNT - 7)))
  for F in $TO_DELETE; do
    rclone delete "r2:${CF_R2_BUCKET}/backups/$F" \
      --config "$STACK_DIR/rclone/rclone.conf"
    log "Gelöscht: $F"
  done
fi

tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
info "════════ Backup Ende — Fehler: $ERRORS ════════"
exit $ERRORS
