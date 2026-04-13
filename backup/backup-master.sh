#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  Ugly Stack — Backup Master
#  Cron: 0 3 * * * bash /home/alex/ugly-stack/backup/backup-master.sh
# ─────────────────────────────────────────────────────────────
set -e

STACK_DIR="/home/alex/ugly-stack"
MODULES_DIR="$STACK_DIR/backup/modules"
STAGING="/tmp/ugly-backup-staging"
LOG="$STACK_DIR/backup/backup.log"
CHECKSUMS_FILE="$STACK_DIR/backup/.checksums"
DATE=$(date '+%Y-%m-%d_%H-%M-%S')
DAY_OF_WEEK=$(date '+%u')  # 7 = Sonntag

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [✓] $1" | tee -a "$LOG"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [✗] $1" | tee -a "$LOG"; }
info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [→] $1" | tee -a "$LOG"; }

echo "" >> "$LOG"
info "════════ Backup Start ════════"

source "$STACK_DIR/.env"

# ─────────────────────────────────────────────────────────────
# HILFSFUNKTIONEN
# ─────────────────────────────────────────────────────────────

# Checksumme eines Verzeichnisses berechnen
dir_checksum() {
  local dir="$1"
  if [ ! -d "$dir" ] || [ -z "$(ls -A $dir 2>/dev/null)" ]; then
    echo "empty"
    return
  fi
  find "$dir" -type f | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1
}

# Checksumme einer Datei berechnen
file_checksum() {
  local file="$1"
  [ ! -f "$file" ] && echo "missing" && return
  sha256sum "$file" | cut -d' ' -f1
}

# Checksumme aus gespeicherter Datei lesen
read_checksum() {
  local key="$1"
  [ ! -f "$CHECKSUMS_FILE" ] && echo "" && return
  grep "^${key}=" "$CHECKSUMS_FILE" 2>/dev/null | cut -d'=' -f2
}

# Checksumme in Datei schreiben
write_checksum() {
  local key="$1"
  local value="$2"
  touch "$CHECKSUMS_FILE"
  if grep -q "^${key}=" "$CHECKSUMS_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$CHECKSUMS_FILE"
  else
    echo "${key}=${value}" >> "$CHECKSUMS_FILE"
  fi
}

# Mail via Brevo REST API senden
send_mail() {
  local subject="$1"
  local body="$2"
  curl -s -o /dev/null -X POST "https://api.brevo.com/v3/smtp/email" \
    -H "api-key: ${BREVO_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"sender\": {\"name\": \"Ugly Backup\", \"email\": \"ugly@beautymolt.com\"},
      \"to\": [{\"email\": \"alex@alexstuder.ch\"}],
      \"subject\": \"${subject}\",
      \"textContent\": \"${body}\"
    }"
}

# ─────────────────────────────────────────────────────────────
# CHECKSUMMEN BERECHNEN
# ─────────────────────────────────────────────────────────────
info "Checksummen berechnen..."

CURR_ENV=$(file_checksum "$STACK_DIR/.env")
CURR_OPENCLAW=$(dir_checksum "$STACK_DIR/openclaw-data")
CURR_N8N=$(dir_checksum "$STACK_DIR/n8n-data")
CURR_NGINX=$(dir_checksum "$STACK_DIR/nginx/conf.d")
CURR_WWW=$(dir_checksum "$STACK_DIR/www")
CURR_PORTAINER=$(docker run --rm \
  -v portainer-data:/data \
  alpine sh -c "sha256sum /data/portainer.db 2>/dev/null | cut -d' ' -f1 || echo missing" 2>/dev/null || echo "missing")

PREV_ENV=$(read_checksum "env")
PREV_OPENCLAW=$(read_checksum "openclaw")
PREV_N8N=$(read_checksum "n8n")
PREV_NGINX=$(read_checksum "nginx")
PREV_WWW=$(read_checksum "www")
PREV_PORTAINER=$(read_checksum "portainer")

# ─────────────────────────────────────────────────────────────
# .env PRÜFEN + GITHUB PUSH
# ─────────────────────────────────────────────────────────────
ENV_STATUS=""
if [ "$CURR_ENV" != "$PREV_ENV" ]; then
  info ".env geändert → GPG + GitHub push..."
  gpg --batch --yes \
    --passphrase "$BACKUP_GPG_PASSWORD" \
    --symmetric --cipher-algo AES256 \
    -o "$STACK_DIR/.env.gpg" "$STACK_DIR/.env"
  cd "$STACK_DIR"
  git add .env.gpg
  git diff --cached --quiet || git commit -m "update: .env sync $(date '+%Y-%m-%d %H:%M')"
  git push origin main
  log ".env → GitHub gepusht"
  ENV_STATUS="geändert → GitHub push OK"
else
  info ".env nicht geändert — kein Push"
  ENV_STATUS="nicht geändert → kein Push"
fi

# ─────────────────────────────────────────────────────────────
# ÄNDERUNGEN FESTSTELLEN
# ─────────────────────────────────────────────────────────────
IS_SUNDAY=false
[ "$DAY_OF_WEEK" = "7" ] && IS_SUNDAY=true

declare -A CHANGED
declare -A STATUS

for KEY in openclaw n8n nginx www portainer; do
  CURR_VAR="CURR_${KEY^^}"
  PREV_VAR="PREV_${KEY^^}"
  CURR="${!CURR_VAR}"
  PREV="${!PREV_VAR}"
  if [ "$CURR" != "$PREV" ] || [ -z "$PREV" ]; then
    CHANGED[$KEY]=true
    STATUS[$KEY]="geändert → wird gesichert"
  else
    CHANGED[$KEY]=false
    STATUS[$KEY]="nicht geändert → übersprungen"
  fi
done

# Backup nötig?
NEEDS_BACKUP=false
for KEY in openclaw n8n nginx www portainer; do
  [ "${CHANGED[$KEY]}" = "true" ] && NEEDS_BACKUP=true
done
$IS_SUNDAY && NEEDS_BACKUP=true

# ─────────────────────────────────────────────────────────────
# BACKUP AUSFÜHREN (wenn nötig)
# ─────────────────────────────────────────────────────────────
BACKUP_STATUS=""
BACKUP_SIZE=""
ERRORS=0

if [ "$NEEDS_BACKUP" = "true" ]; then

  if $IS_SUNDAY; then
    FILENAME="backup-WEEKLY-${DATE}.tar.gz.gpg"
    info "Sonntags-Pflichtbackup → $FILENAME"
  else
    FILENAME="backup-${DATE}.tar.gz.gpg"
    info "Änderungen festgestellt → $FILENAME"
  fi

  rm -rf "$STAGING"
  mkdir -p "$STAGING"/{openclaw-data,n8n-data,nginx,www,portainer}

  for MODULE in "$MODULES_DIR"/*.sh; do
    NAME=$(basename "$MODULE" .sh)
    info "Modul: $NAME"
    if STAGING="$STAGING" STACK_DIR="$STACK_DIR" bash "$MODULE" >> "$LOG" 2>&1; then
      log "$NAME — OK"
    else
      fail "$NAME — FEHLER"
      ERRORS=$((ERRORS + 1))
      STATUS[$NAME]="FEHLER beim Backup"
    fi
  done

  info "Erstelle verschlüsseltes Backup..."
  tar -czf - -C "$STAGING" . | \
    gpg --batch --yes --symmetric \
        --cipher-algo AES256 \
        --passphrase "$BACKUP_GPG_PASSWORD" \
        -o "/tmp/$FILENAME"

  BACKUP_SIZE=$(du -sh "/tmp/$FILENAME" | cut -f1)
  log "Backup erstellt: $FILENAME ($BACKUP_SIZE)"

  info "Upload zu Cloudflare R2..."
  rclone copy "/tmp/$FILENAME" "r2:${CF_R2_BUCKET}/backups/" \
    --config "$STACK_DIR/rclone/rclone.conf"
  log "Upload OK"

  rm -f "/tmp/$FILENAME"
  rm -rf "$STAGING"

  # Normale Backups: letzte 7 behalten
  NORMAL_BACKUPS=$(rclone ls "r2:${CF_R2_BUCKET}/backups/" \
    --config "$STACK_DIR/rclone/rclone.conf" \
    | sort | awk '{print $2}' | grep -v 'WEEKLY')
  COUNT=$(echo "$NORMAL_BACKUPS" | grep -c . || true)
  if [ "$COUNT" -gt 7 ]; then
    TO_DELETE=$(echo "$NORMAL_BACKUPS" | head -n $((COUNT - 7)))
    for F in $TO_DELETE; do
      rclone delete "r2:${CF_R2_BUCKET}/backups/$F" \
        --config "$STACK_DIR/rclone/rclone.conf"
      log "Gelöscht: $F"
    done
  fi

  # WEEKLY Backups: letzte 4 behalten
  WEEKLY_BACKUPS=$(rclone ls "r2:${CF_R2_BUCKET}/backups/" \
    --config "$STACK_DIR/rclone/rclone.conf" \
    | sort | awk '{print $2}' | grep 'WEEKLY')
  COUNT=$(echo "$WEEKLY_BACKUPS" | grep -c . || true)
  if [ "$COUNT" -gt 4 ]; then
    TO_DELETE=$(echo "$WEEKLY_BACKUPS" | head -n $((COUNT - 4)))
    for F in $TO_DELETE; do
      rclone delete "r2:${CF_R2_BUCKET}/backups/$F" \
        --config "$STACK_DIR/rclone/rclone.conf"
      log "Gelöscht (WEEKLY alt): $F"
    done
  fi

  if $IS_SUNDAY; then
    BACKUP_STATUS="WEEKLY-Backup erstellt: $FILENAME ($BACKUP_SIZE)"
  else
    BACKUP_STATUS="Backup erstellt: $FILENAME ($BACKUP_SIZE)"
  fi

  # Checksummen aktualisieren
  write_checksum "env" "$CURR_ENV"
  write_checksum "openclaw" "$CURR_OPENCLAW"
  write_checksum "n8n" "$CURR_N8N"
  write_checksum "nginx" "$CURR_NGINX"
  write_checksum "www" "$CURR_WWW"
  write_checksum "portainer" "$CURR_PORTAINER"

else
  BACKUP_STATUS="Kein Backup nötig — nichts geändert"
  info "Nichts geändert — kein Backup"
fi

# Log kürzen
tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

# ─────────────────────────────────────────────────────────────
# STATUS-MAIL SENDEN
# ─────────────────────────────────────────────────────────────
if [ $ERRORS -eq 0 ]; then
  SUBJECT="Ugly Stack Backup — $(date '+%Y-%m-%d') — OK"
else
  SUBJECT="Ugly Stack Backup — $(date '+%Y-%m-%d') — FEHLER ($ERRORS)"
fi

BODY="Ugly Stack Backup-Report\n$(date '+%Y-%m-%d %H:%M:%S')\n"
BODY+="════════════════════════════\n\n"
BODY+=".env:\n  $ENV_STATUS\n\n"
BODY+="Backup-Kandidaten:\n"
for KEY in openclaw n8n nginx www portainer; do
  BODY+="  $KEY: ${STATUS[$KEY]}\n"
done
BODY+="\nR2-Backup:\n  $BACKUP_STATUS\n"
if [ $ERRORS -gt 0 ]; then
  BODY+="\nFEHLER: $ERRORS Module fehlgeschlagen — Log prüfen:\n"
  BODY+="  tail -50 $LOG\n"
else
  BODY+="\nFehler: keine\n"
fi

send_mail "$SUBJECT" "$BODY"
log "Status-Mail gesendet"

info "════════ Backup Ende — Fehler: $ERRORS ════════"
exit $ERRORS
