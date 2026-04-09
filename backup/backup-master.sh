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

# Staging
rm -rf "$STAGING"
mkdir -p "$STAGING"/{openclaw-data,n8n-data,nginx,www}

# Module ausführen
ERRORS=0
MODULE_LOG=""
for MODULE in "$MODULES_DIR"/*.sh; do
  NAME=$(basename "$MODULE" .sh)
  info "Modul: $NAME"
  MODULE_OUTPUT=$(STAGING="$STAGING" STACK_DIR="$STACK_DIR" bash "$MODULE" 2>&1)
  echo "$MODULE_OUTPUT" >> "$LOG"
  if echo "$MODULE_OUTPUT" | grep -qi "FEHLER\|error\|permission denied\|exit 1"; then
    fail "$NAME — FEHLER"
    MODULE_LOG="$MODULE_LOG\n❌ $NAME: FEHLER\n$MODULE_OUTPUT"
    ERRORS=$((ERRORS + 1))
  else
    log "$NAME — OK"
    MODULE_LOG="$MODULE_LOG\n✅ $NAME: OK"
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

# Mail-Protokoll via Brevo
if [ -n "$BREVO_KEY" ]; then
  if [ "$ERRORS" -eq 0 ]; then
    SUBJECT="✅ Backup OK — $DATE"
    STATUS="Alle Module erfolgreich."
  else
    SUBJECT="❌ Backup FEHLER ($ERRORS) — $DATE"
    STATUS="$ERRORS Modul(e) fehlgeschlagen!"
  fi

  BODY="Backup-Protokoll vom $(date '+%Y-%m-%d %H:%M:%S')\n\nStatus: $STATUS\nDatei: $FILENAME ($SIZE)\n\nModule:$(echo -e "$MODULE_LOG")\n\n--- Log (letzte 30 Zeilen) ---\n$(tail -30 $LOG)"

  curl -s -X POST https://api.brevo.com/v3/smtp/email \
    -H "api-key: $BREVO_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"sender\":{\"email\":\"ugly@beautymolt.com\",\"name\":\"Ugly Backup\"},\"to\":[{\"email\":\"alex@alexstuder.ch\"}],\"subject\":\"$SUBJECT\",\"textContent\":\"$BODY\"}" \
    >> "$LOG" 2>&1 && log "Protokoll-Mail gesendet an alex@alexstuder.ch" || fail "Mail-Versand fehlgeschlagen"
fi

exit $ERRORS
