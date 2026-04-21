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

dir_checksum() {
  local dir="$1"
  if [ ! -d "$dir" ] || [ -z "$(ls -A $dir 2>/dev/null)" ]; then
    echo "empty"
    return
  fi
  find "$dir" -type f | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1
}

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
# CHECKSUMMEN BERECHNEN
# ─────────────────────────────────────────────────────────────
info "Checksummen berechnen..."

CURR_ENV=$(file_checksum "$STACK_DIR/.env")
CURR_OPENCLAW=$(dir_checksum "$STACK_DIR/openclaw-data")
CURR_N8N=$(dir_checksum "$STACK_DIR/n8n-data")
CURR_NGINX=$(dir_checksum "$STACK_DIR/nginx/conf.d")
CURR_WWW=$(dir_checksum "$STACK_DIR/www")
# Portainer: DB aendert sich laufend (Sessions) - keine Checksumme, immer gesichert

PREV_ENV=$(read_checksum "env")
PREV_OPENCLAW=$(read_checksum "openclaw")
PREV_N8N=$(read_checksum "n8n")
PREV_NGINX=$(read_checksum "nginx")
PREV_WWW=$(read_checksum "www")

# ─────────────────────────────────────────────────────────────
# .env PRUEFEN + GITHUB PUSH
# ─────────────────────────────────────────────────────────────
info ".env pruefen..."
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
  log ".env.gpg nach GitHub gepusht"
  ENV_STATUS="geaendert - .env.gpg nach GitHub gepusht"
else
  info ".env nicht geaendert - kein Push noetig"
  ENV_STATUS="nicht geaendert - kein Push"
fi

sep

# ─────────────────────────────────────────────────────────────
# BACKUP-KANDIDATEN PRUEFEN
# Portainer wird nicht gecheckt — DB aendert sich laufend
# Portainer wird immer gesichert wenn ein Backup stattfindet
# ─────────────────────────────────────────────────────────────
info "Backup-Kandidaten pruefen..."

IS_SUNDAY=false
[ "$DAY_OF_WEEK" = "7" ] && IS_SUNDAY=true

declare -A CHANGED
declare -A STATUS

for KEY in openclaw n8n nginx www; do
  CURR_VAR="CURR_${KEY^^}"
  PREV_VAR="PREV_${KEY^^}"
  CURR="${!CURR_VAR}"
  PREV="${!PREV_VAR}"
  if [ "$CURR" != "$PREV" ] || [ -z "$PREV" ]; then
    CHANGED[$KEY]=true
    STATUS[$KEY]="geaendert - wird gesichert"
    info "  $KEY: geaendert"
  else
    CHANGED[$KEY]=false
    STATUS[$KEY]="unveraendert - uebersprungen"
    info "  $KEY: unveraendert"
  fi
done
# Portainer: immer im Backup enthalten wenn Backup laeuft
STATUS[portainer]="immer gesichert (DB)"
info "  portainer: immer gesichert"

# Backup noetig?
NEEDS_BACKUP=false
CHANGED_LIST=""
for KEY in openclaw n8n nginx www; do
  if [ "${CHANGED[$KEY]}" = "true" ]; then
    NEEDS_BACKUP=true
    CHANGED_LIST="$CHANGED_LIST $KEY"
  fi
done
$IS_SUNDAY && NEEDS_BACKUP=true

sep

# ─────────────────────────────────────────────────────────────
# BACKUP AUSFUEHREN (wenn noetig)
# ─────────────────────────────────────────────────────────────
BACKUP_STATUS=""
BACKUP_SIZE=""
ERRORS=0

if [ "$NEEDS_BACKUP" = "true" ]; then

  if $IS_SUNDAY; then
    FILENAME="backup-WEEKLY-${DATE}.tar.gz.gpg"
    info "Sonntags-Pflichtbackup - erstelle: $FILENAME"
  else
    FILENAME="backup-${DATE}.tar.gz.gpg"
    info "Geaenderte Kandidaten:${CHANGED_LIST} - erstelle: $FILENAME"
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
      STATUS[$NAME]="FEHLER beim Backup"
    fi
  done

  # ── config-ref: Referenzkopien zur Rekonstruktion ──────────────────────
  # Diese Dateien werden beim Restore NICHT automatisch eingespielt.
  # Sie dienen ausschliesslich zur manuellen Einsicht / Rekonstruktion.
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
  # ── Ende config-ref ────────────────────────────────────────────────────

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
    TO_DELETE=$(echo "$WEEKLY_BACKUPS" | head -d $((COUNT - 4)))
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

  # Checksummen aktualisieren (ohne portainer)
  write_checksum "env" "$CURR_ENV"
  write_checksum "openclaw" "$CURR_OPENCLAW"
  write_checksum "n8n" "$CURR_N8N"
  write_checksum "nginx" "$CURR_NGINX"
  write_checksum "www" "$CURR_WWW"

else
  BACKUP_STATUS="Kein Backup noetig - nichts geaendert"
  STATUS[portainer]="kein Backup - nichts geaendert"
  info "Nichts geaendert - kein R2-Backup"
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
Backup-Kandidaten (R2):
  openclaw:  ${STATUS[openclaw]}
  n8n:       ${STATUS[n8n]}
  nginx:     ${STATUS[nginx]}
  www:       ${STATUS[www]}
  portainer: ${STATUS[portainer]}

----------------------------------------
R2-Backup:
  $BACKUP_STATUS"

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
