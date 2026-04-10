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
DATE=$(TZ="${TZ:-Europe/Zurich}" date '+%Y-%m-%d_%H-%M-%S')
FILENAME="backup-${DATE}.tar.gz.gpg"

log()  { echo "[$(TZ="${TZ:-Europe/Zurich}" date '+%Y-%m-%d %H:%M:%S')] [✓] $1" | tee -a "$LOG"; }
fail() { echo "[$(TZ="${TZ:-Europe/Zurich}" date '+%Y-%m-%d %H:%M:%S')] [✗] $1" | tee -a "$LOG"; }
info() { echo "[$(TZ="${TZ:-Europe/Zurich}" date '+%Y-%m-%d %H:%M:%S')] [→] $1" | tee -a "$LOG"; }

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
  if echo "$MODULE_OUTPUT" | grep -qi "FEHLER\|permission denied"; then
    fail "$NAME — FEHLER"
    MODULE_LOG="${MODULE_LOG}\n❌ $NAME: FEHLER"
    ERRORS=$((ERRORS + 1))
  else
    log "$NAME — OK"
    MODULE_LOG="${MODULE_LOG}\n✅ $NAME: OK"
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

# ── Verifikation (1 Min nach Upload) ─────────────────────────
info "Warte 60s vor Verifikation..."
sleep 60

info "Starte Verifikation..."
VERIFY_LOG=""
VERIFY_ERRORS=0

# Backup von R2 holen und entpacken
VERIFY_DIR="/tmp/ugly-verify-$$"
mkdir -p "$VERIFY_DIR"

LATEST=$(rclone ls "r2:${CF_R2_BUCKET}/backups/" \
  --config "$STACK_DIR/rclone/rclone.conf" 2>/dev/null \
  | sort | tail -1 | awk '{print $2}')

if [ -z "$LATEST" ]; then
  VERIFY_LOG="❌ Kein Backup in R2 gefunden"
  VERIFY_ERRORS=1
else
  rclone copy "r2:${CF_R2_BUCKET}/backups/$LATEST" /tmp/ \
    --config "$STACK_DIR/rclone/rclone.conf" 2>/dev/null

  gpg --batch --yes \
    --passphrase "$BACKUP_GPG_PASSWORD" \
    --decrypt "/tmp/$LATEST" \
    | tar -xz -C "$VERIFY_DIR/" 2>/dev/null
  rm -f "/tmp/$LATEST"

  VERIFY_LOG="Backup: $LATEST\n"

  # openclaw tar.gz prüfen
  BACKUP_TAR=$(ls "$VERIFY_DIR/openclaw-data/"*.tar.gz 2>/dev/null | head -1)
  if [ -z "$BACKUP_TAR" ]; then
    VERIFY_LOG="${VERIFY_LOG}❌ openclaw: kein tar.gz\n"
    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
  else
    TMP_CLAW="/tmp/verify-claw-$$"
    mkdir -p "$TMP_CLAW"
    tar -xzf "$BACKUP_TAR" -C "$TMP_CLAW/" 2>/dev/null

    WORKSPACE_ORIG="$STACK_DIR/openclaw-data/workspace"
    WORKSPACE_BACK="$TMP_CLAW/workspace"

    # Workspace-Dateien
    for FILE in AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md; do
      ORIG="$WORKSPACE_ORIG/$FILE"
      BACK="$WORKSPACE_BACK/$FILE"
      BACK_EXISTS=false; [ -f "$BACK" ] && BACK_EXISTS=true
      ORIG_EXISTS=false; sudo test -f "$ORIG" 2>/dev/null && ORIG_EXISTS=true

      if [ "$ORIG_EXISTS" = false ] && [ "$BACK_EXISTS" = false ]; then
        continue
      elif [ "$BACK_EXISTS" = false ]; then
        VERIFY_LOG="${VERIFY_LOG}⚠️  $FILE: fehlt im Backup\n"
      elif [ "$ORIG_EXISTS" = false ]; then
        VERIFY_LOG="${VERIFY_LOG}⚠️  $FILE: nur im Backup\n"
      elif sudo diff -q "$ORIG" "$BACK" &>/dev/null; then
        VERIFY_LOG="${VERIFY_LOG}✅ $FILE: identisch\n"
      else
        VERIFY_LOG="${VERIFY_LOG}❌ $FILE: UNTERSCHIED\n"
        VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
      fi
    done

    # Skills
    SKILLS_ORIG="$WORKSPACE_ORIG/skills"
    SKILLS_BACK="$WORKSPACE_BACK/skills"
    SKILLS_ORIG_EXISTS=false; sudo test -d "$SKILLS_ORIG" && SKILLS_ORIG_EXISTS=true
    SKILLS_BACK_EXISTS=false; [ -d "$SKILLS_BACK" ] && SKILLS_BACK_EXISTS=true

    if [ "$SKILLS_ORIG_EXISTS" = true ] && [ "$SKILLS_BACK_EXISTS" = true ]; then
      if sudo diff -rq "$SKILLS_ORIG/" "$SKILLS_BACK/" &>/dev/null; then
        SKILL_LIST=$(sudo ls "$SKILLS_ORIG" | tr '\n' ' ')
        VERIFY_LOG="${VERIFY_LOG}✅ skills: identisch ($SKILL_LIST)\n"
      else
        VERIFY_LOG="${VERIFY_LOG}❌ skills: UNTERSCHIED\n"
        VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
      fi
    elif [ "$SKILLS_BACK_EXISTS" = false ] && [ "$SKILLS_ORIG_EXISTS" = true ]; then
      VERIFY_LOG="${VERIFY_LOG}❌ skills: fehlen im Backup!\n"
      VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
    fi

    rm -rf "$TMP_CLAW"
  fi

  # n8n
  [ -f "$VERIFY_DIR/n8n-data/workflows-backup.json" ] \
    && VERIFY_LOG="${VERIFY_LOG}✅ n8n workflows: vorhanden\n" \
    || { VERIFY_LOG="${VERIFY_LOG}❌ n8n workflows: FEHLT\n"; VERIFY_ERRORS=$((VERIFY_ERRORS + 1)); }
  [ -f "$VERIFY_DIR/n8n-data/credentials-backup.json" ] \
    && VERIFY_LOG="${VERIFY_LOG}✅ n8n credentials: vorhanden\n" \
    || { VERIFY_LOG="${VERIFY_LOG}❌ n8n credentials: FEHLT\n"; VERIFY_ERRORS=$((VERIFY_ERRORS + 1)); }

  # nginx
  if diff -rq "$VERIFY_DIR/nginx/conf.d/" "$STACK_DIR/nginx/conf.d/" &>/dev/null; then
    VERIFY_LOG="${VERIFY_LOG}✅ nginx conf: identisch\n"
  else
    VERIFY_LOG="${VERIFY_LOG}❌ nginx conf: UNTERSCHIED\n"
    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
  fi

  rm -rf "$VERIFY_DIR"
fi

if [ $VERIFY_ERRORS -eq 0 ]; then
  log "Verifikation OK"
  VERIFY_SUMMARY="✅ Verifikation erfolgreich"
else
  fail "Verifikation: $VERIFY_ERRORS Fehler"
  VERIFY_SUMMARY="❌ Verifikation: $VERIFY_ERRORS Fehler"
  ERRORS=$((ERRORS + VERIFY_ERRORS))
fi

# ── Protokoll-Mail via Brevo ──────────────────────────────────
if [ -n "$BREVO_KEY" ]; then
  if [ "$ERRORS" -eq 0 ]; then
    SUBJECT="✅ Backup + Verifikation OK — ${DATE}"
  else
    SUBJECT="❌ Backup/Verifikation FEHLER (${ERRORS}) — ${DATE}"
  fi

  LOG_TAIL=$(tail -20 "$LOG")

  python3 - << PYEOF
import json, urllib.request, urllib.error

subject = """${SUBJECT}"""
errors = ${ERRORS}
filename = """${FILENAME}"""
size = """${SIZE}"""
module_log = """${MODULE_LOG}"""
verify_summary = """${VERIFY_SUMMARY}"""
verify_log = """${VERIFY_LOG}"""
log_tail = """${LOG_TAIL}"""
brevo_key = """${BREVO_KEY}"""

status = "Alle Prüfungen erfolgreich." if errors == 0 else f"{errors} Fehler aufgetreten!"
body = f"""Backup-Protokoll

Status: {status}
Datei: {filename} ({size})

━━━ Module ━━━
{module_log}

━━━ Verifikation ━━━
{verify_summary}
{verify_log}

━━━ Log (letzte 20 Zeilen) ━━━
{log_tail}
"""

payload = json.dumps({
    "sender": {"email": "ugly@beautymolt.com", "name": "Ugly Backup"},
    "to": [{"email": "alex@alexstuder.ch"}],
    "subject": subject,
    "textContent": body
}).encode("utf-8")

req = urllib.request.Request(
    "https://api.brevo.com/v3/smtp/email",
    data=payload,
    headers={"api-key": brevo_key, "Content-Type": "application/json"},
    method="POST"
)
try:
    with urllib.request.urlopen(req) as resp:
        print(f"Mail gesendet: {resp.read().decode()}")
except urllib.error.HTTPError as e:
    print(f"Mail Fehler {e.code}: {e.read().decode()}")
PYEOF

  if [ $? -eq 0 ]; then
    log "Protokoll-Mail gesendet an alex@alexstuder.ch"
  else
    fail "Mail-Versand fehlgeschlagen"
  fi
fi

exit $ERRORS
