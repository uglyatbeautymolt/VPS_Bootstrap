#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  Ugly Stack — Restore Master
#  ./restore-master.sh          → alles wiederherstellen
#  ./restore-master.sh n8n      → nur n8n
#  ./restore-master.sh list     → verfügbare Backups anzeigen
# ─────────────────────────────────────────────────────────────

STACK_DIR="/home/alex/ugly-stack"
RESTORE_MODULES="$STACK_DIR/backup/restore/modules"
STAGING="/tmp/ugly-restore-staging"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [✓] $1"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [✗] $1"; exit 1; }
info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [→] $1"; }

source "$STACK_DIR/.env"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        Ugly Stack — Restore              ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Verfügbare Backups anzeigen
if [ "$1" = "list" ]; then
  info "Verfügbare Backups in R2:"
  rclone ls "r2:${CF_R2_BUCKET}/backups/" --config "$STACK_DIR/rclone.conf" | sort
  exit 0
fi

# Backup auswählen
BACKUPS=$(rclone ls "r2:${CF_R2_BUCKET}/backups/" \
  --config "$STACK_DIR/rclone.conf" | sort | awk '{print $2}')

if [ -z "$BACKUPS" ]; then
  fail "Keine Backups in R2 gefunden"
fi

echo "Verfügbare Backups:"
echo "$BACKUPS" | nl -w2 -s'. '
echo ""
echo "Welches Backup wiederherstellen? (Enter = neuestes)"
read -p "  Nummer: " CHOICE

if [ -z "$CHOICE" ]; then
  FILENAME=$(echo "$BACKUPS" | tail -1)
else
  FILENAME=$(echo "$BACKUPS" | sed -n "${CHOICE}p")
fi

[ -z "$FILENAME" ] && fail "Ungültige Auswahl"
info "Lade Backup: $FILENAME"

# Von R2 herunterladen
rclone copy "r2:${CF_R2_BUCKET}/backups/$FILENAME" /tmp/ \
  --config "$STACK_DIR/rclone.conf"

# Entschlüsseln + entpacken
rm -rf "$STAGING" && mkdir -p "$STAGING"
echo "$BACKUP_GPG_PASSWORD" | gpg --batch --yes --passphrase-fd 0 \
  --decrypt "/tmp/$FILENAME" | tar -xz -C "$STAGING/"
rm -f "/tmp/$FILENAME"
log "Backup entschlüsselt und entpackt"

# Stack stoppen
info "Stoppe Stack..."
cd "$STACK_DIR" && docker compose stop

# Module ausführen
ERRORS=0
if [ -n "$1" ] && [ "$1" != "list" ]; then
  # Einzelnes Modul
  MODULE="$RESTORE_MODULES/$1.sh"
  [ ! -f "$MODULE" ] && fail "Modul '$1' nicht gefunden"
  STAGING="$STAGING" bash "$MODULE" && log "$1 — OK" || { fail "$1 — FEHLER"; ERRORS=1; }
else
  # Alle Module
  for MODULE in "$RESTORE_MODULES"/*.sh; do
    NAME=$(basename "$MODULE" .sh)
    info "Restore: $NAME"
    if STAGING="$STAGING" bash "$MODULE"; then
      log "$NAME — OK"
    else
      echo "[!] $NAME — FEHLER"
      ERRORS=$((ERRORS + 1))
    fi
  done
fi

# Stack starten
info "Starte Stack..."
docker compose start

rm -rf "$STAGING"

echo ""
log "Restore abgeschlossen — Fehler: $ERRORS"
echo ""
exit $ERRORS
