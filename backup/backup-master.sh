#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  Ugly Stack — Backup Master
#  Cron: 0 2 * * * bash /home/alex/ugly-stack/backup/backup-master.sh
# ─────────────────────────────────────────────────────────────
set -e

STACK_DIR="/home/alex/ugly-stack"
MODULES_DIR="$STACK_DIR/backup/modules"
STAGING="/tmp/ugly-backup-staging"
LOG="$STACK_DIR/backup/backup.log"
CHECKSUMS_FILE="$STACK_DIR/backup/.checksums"
DATE=$(date '+%Y-%m-%d_%H-%M-%S')
DAY_OF_WEEK=$(date '+%u')  # 7 = Sonntag

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $1" | tee -a "$LOG"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [!!] $1" | tee -a "$LOG"; }
info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [--] $1" | tee -a "$LOG"; }
sep()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [  ] ----------------------------------------" | tee -a "$LOG"; }

echo "" >> "$LOG"
info "======== Backup Start ========"

source "$STACK_DIR/.env"

# ─────────────────────────────────────────────────────────────
# HILFSFUNKTIONEN
# ─────────────────────────────────────────────────────────────

file_checksum() {
  local file="$1"
  [ ! -f "$file" ] && echo "missing" && return
  sha256sum "$file" | cut -d' ' -f1
}

read_checksum() {
  local key="$1"
  [ ! -f "$CHECKSUMS_FILE" ] && echo "" && return
  grep "^${key}=" "$CHECKSUMS_FILE" 2>/dev/null | cut -d'=' -f2
}

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

count_lines() {
  echo "${1}" | grep -v '^[[:space:]]*$' | wc -l || echo 0
}

send_mail() {
  local subject="$1"
  local body="$2"
  local payload
  payload=$(jq -n \
    --arg from_name "Ugly Backup" \
    --arg from_email "ugly@beautymolt.com" \
    --arg to_email "alex@alexstuder.ch" \
    --arg subject "$subject" \
    --arg body "$body" \
    '{
      sender: {name: $from_name, email: $from_email},
      to: [{email: $to_email}],
      subject: $subject,
      textContent: $body
    }')
  local http_code
  http_code=$(curl -s -o /tmp/brevo_response.txt -w "%{http_code}" \
    -X POST "https://api.brevo.com/v3/smtp/email" \
    -H "api-key: ${BREVO_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload")
  if [ "$http_code" = "201" ]; then
    log "Status-Mail gesendet (HTTP $http_code)"
  else
    fail "Status-Mail fehlgeschlagen (HTTP $http_code): $(cat /tmp/brevo_response.txt)"
  fi
}

# ─────────────────────────────────────────────────────────────
# .env PRUEFEN + GITHUB PUSH
# Einzige Checksumme die noch gepflegt wird — .env Push nur bei Aenderung
# ─────────────────────────────────────────────────────────────
info ".env pruefen..."
CURR_ENV=$(file_checksum "$STACK_DIR/.env")
PREV_ENV=$(read_checksum "env")
ENV_STATUS=""

if [ "$CURR_ENV" != "$PREV_ENV" ]; then
  info ".env geaendert - GPG verschluesseln + GitHub push..."
  gpg --batch --yes \
    --passphrase "$BACKUP_GPG_PASSWORD" \
    --symmetric --cipher-algo AES256 \
    -o "$STACK_DIR/.env.gpg" "$STACK_DIR/.env"
  cd "$STACK_DIR"
  git add .env.gpg
  git diff --cached --quiet || git commit -m "update: .env sync $(date '+%Y-%m-%d %H:%M')"
  git push origin main
  write_checksum "env" "$CURR_ENV"
  log ".env.gpg nach GitHub gepusht"
  ENV_STATUS="geaendert - .env.gpg nach GitHub gepusht"
else
  info ".env nicht geaendert - kein Push noetig"
  ENV_STATUS="nicht geaendert - kein Push"
fi

sep

# ─────────────────────────────────────────────────────────────
# BACKUP — immer alles sichern
# Checksummen-Logik fuer Module entfernt — jedes Backup enthaelt
# immer den vollstaendigen aktuellen Zustand aller Module.
# Grund: selektives Backup fuehrt zu Datenverlust bei Rotation
# (z.B. n8n unveraendert fuer 8 Tage → letztes n8n-Backup rotiert)
# ─────────────────────────────────────────────────────────────
info "Backup-Kandidaten pruefen..."
IS_SUNDAY=false
[ "$DAY_OF_WEEK" = "7" ] && IS_SUNDAY=true

info "  openclaw: wird gesichert"
info "  n8n:      wird gesichert"
info "  nginx:    wird gesichert"
info "  www:      wird gesichert"
info "  portainer: wird gesichert"

sep

BACKUP_STATUS=""
BACKUP_SIZE=""
ERRORS=0

if $IS_SUNDAY; then
  FILENAME="backup-WEEKLY-${DATE}.tar.gz.gpg"
  info "Sonntags-WEEKLY-Backup - erstelle: $FILENAME"
else
  FILENAME="backup-${DATE}.tar.gz.gpg"
  info "Taegliches Backup - erstelle: $FILENAME"
fi

rm -rf "$STAGING"
mkdir -p "$STAGING"/{openclaw-data,n8n-data,nginx,www,portainer,config-ref}

for MODULE in "$MODULES_DIR"/*.sh; do
  NAME=$(basename "$MODULE" .sh)
  info "Modul: $NAME"
  if STAGING="$STAGING" STACK_DIR="$STACK_DIR" bash "$MODULE" >> "$LOG" 2>&1; then
    log "$NAME - OK"
  else
    fail "$NAME - FEHLER"
    ERRORS=$((ERRORS + 1))
  fi
done

# ── config-ref: Referenzkopien zur Rekonstruktion ──────────────────────
# Werden beim Restore NICHT automatisch eingespielt — nur zur manuellen Einsicht.
# sudo cat statt sudo cp — Datei gehoert alex, kein Passwort-Prompt im Cron
info "config-ref sichern..."
cp "$STACK_DIR/.env" \
   "$STAGING/config-ref/env.ref"
cp "$STACK_DIR/docker-compose.yml" \
   "$STAGING/config-ref/docker-compose.yml.ref"
[ -f "$STACK_DIR/docker-compose.override.yml" ] && \
  cp "$STACK_DIR/docker-compose.override.yml" \
     "$STAGING/config-ref/docker-compose.override.yml.ref" || true
sudo cat "$STACK_DIR/openclaw-data/openclaw.json" \
     > "$STAGING/config-ref/openclaw.json.ref" 2>/dev/null || true
log "config-ref gesichert (env, docker-compose, override, openclaw.json)"

info "Erstelle verschluesseltes Archiv..."
tar -czf - -C "$STAGING" . | \
  gpg --batch --yes --symmetric \
      --cipher-algo AES256 \
      --passphrase "$BACKUP_GPG_PASSWORD" \
      -o "/tmp/$FILENAME"

BACKUP_SIZE=$(du -sh "/tmp/$FILENAME" | cut -f1)
log "Archiv erstellt: $FILENAME ($BACKUP_SIZE)"

info "Upload zu Cloudflare R2..."
rclone copy "/tmp/$FILENAME" "r2:${CF_R2_BUCKET}/backups/" \
  --config "$STACK_DIR/rclone/rclone.conf"
log "Upload OK"

rm -f "/tmp/$FILENAME"
rm -rf "$STAGING"

# Normale Backups: letzte 7 behalten
NORMAL_BACKUPS=$(rclone ls "r2:${CF_R2_BUCKET}/backups/" \
  --config "$STACK_DIR/rclone/rclone.conf" \
  | sort | awk '{print $2}' | grep -v 'WEEKLY' || true)
COUNT=$(count_lines "$NORMAL_BACKUPS")
if [ "$COUNT" -gt 7 ]; then
  TO_DELETE=$(echo "$NORMAL_BACKUPS" | head -n $((COUNT - 7)))
  for F in $TO_DELETE; do
    rclone delete "r2:${CF_R2_BUCKET}/backups/$F" \
      --config "$STACK_DIR/rclone/rclone.conf"
    log "Geloescht (alt): $F"
  done
fi

# WEEKLY Backups: letzte 4 behalten
WEEKLY_BACKUPS=$(rclone ls "r2:${CF_R2_BUCKET}/backups/" \
  --config "$STACK_DIR/rclone/rclone.conf" \
  | sort | awk '{print $2}' | grep 'WEEKLY' || true)
COUNT=$(count_lines "$WEEKLY_BACKUPS")
if [ "$COUNT" -gt 4 ]; then
  TO_DELETE=$(echo "$WEEKLY_BACKUPS" | head -n $((COUNT - 4)))
  for F in $TO_DELETE; do
    rclone delete "r2:${CF_R2_BUCKET}/backups/$F" \
      --config "$STACK_DIR/rclone/rclone.conf"
    log "Geloescht (WEEKLY alt): $F"
  done
fi

if $IS_SUNDAY; then
  BACKUP_STATUS="WEEKLY-Backup erstellt: $FILENAME ($BACKUP_SIZE)"
else
  BACKUP_STATUS="Backup erstellt: $FILENAME ($BACKUP_SIZE)"
fi

# Log kuerzen
tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

sep

# ─────────────────────────────────────────────────────────────
# STATUS-MAIL SENDEN
# ─────────────────────────────────────────────────────────────
info "Status-Mail senden..."

if [ $ERRORS -eq 0 ]; then
  SUBJECT="Ugly Stack Backup - $(date '+%Y-%m-%d') - OK"
else
  SUBJECT="Ugly Stack Backup - $(date '+%Y-%m-%d') - FEHLER ($ERRORS)"
fi

MAIL_BODY="Ugly Stack Backup-Report
$(date '+%Y-%m-%d %H:%M:%S')
========================================

.env / GitHub:
  $ENV_STATUS

----------------------------------------
R2-Backup:
  $BACKUP_STATUS
  Module: openclaw, n8n, nginx, www, portainer (immer vollstaendig)"

if [ $ERRORS -gt 0 ]; then
  MAIL_BODY="$MAIL_BODY

FEHLER: $ERRORS Module fehlgeschlagen
  Log pruefen: tail -50 $LOG"
else
  MAIL_BODY="$MAIL_BODY

Fehler: keine"
fi

send_mail "$SUBJECT" "$MAIL_BODY"

info "======== Backup Ende - Fehler: $ERRORS ========"
exit $ERRORS
