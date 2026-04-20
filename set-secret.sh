#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  Ugly Stack — Secret setzen / aktualisieren
#  1. git pull (aktuelle .env.gpg holen)
#  2. .env aktualisieren
#  3. .env neu verschlüsseln → .env.gpg
#  4. git commit + push
#  5. Container neu starten
#
#  Verwendung:
#    ./set-secret.sh TELEGRAM_BOT_TOKEN "123456:ABC..."
#    ./set-secret.sh                    (interaktiv)
# ─────────────────────────────────────────────────────────────

STACK_DIR="/home/alex/ugly-stack"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()  { echo -e "${YELLOW}[?]${NC} $1"; }

[ ! -f "$STACK_DIR/.env" ] && fail ".env nicht gefunden: $STACK_DIR/.env"

source "$STACK_DIR/.env"

[ -z "$BACKUP_GPG_PASSWORD" ] && fail "BACKUP_GPG_PASSWORD fehlt in .env"

# ── 1. git pull ──────────────────────────────────────────────
info "git pull — aktuellen Stand holen..."
cd "$STACK_DIR"
git pull origin main || fail "git pull fehlgeschlagen"
log "git pull — OK"

# ── Secret Name + Wert bestimmen ────────────────────────────
if [ -n "$1" ] && [ -n "$2" ]; then
  SECRET_NAME="$1"
  SECRET_VALUE="$2"
elif [ -n "$1" ] && [ -z "$2" ]; then
  SECRET_NAME="$1"
  ask "Wert für $SECRET_NAME:"
  read -s -p "  > " SECRET_VALUE; echo ""
else
  echo ""
  echo "Verfügbare Secrets:"
  echo ""
  SECRETS=(
    CLOUDFLARE_TUNNEL_TOKEN
    CF_TOKEN
    CF_ZONE_ID
    CF_ACCOUNT_ID
    CF_TUNNEL_ID
    OPENROUTER_API_KEY
    TELEGRAM_BOT_TOKEN
    OPENCLAW_GATEWAY_TOKEN
    N8N_BASIC_AUTH_USER
    N8N_BASIC_AUTH_PASSWORD
    N8N_ENCRYPTION_KEY
    ZOHO_SMTP_USER
    ZOHO_SMTP_PASSWORD
    BREVO_SMTP_USER
    BREVO_SMTP_API_KEY
    BREVO_KEY
    BACKUP_GPG_PASSWORD
    CF_R2_ACCESS_KEY
    CF_R2_SECRET_KEY
    CF_R2_BUCKET
    CF_R2_ENDPOINT
    ANTHROPIC_API_KEY
    PROJEKT_GPG_KEY
  )
  for i in "${!SECRETS[@]}"; do
    echo "  $((i+1)). ${SECRETS[$i]}"
  done
  echo ""
  ask "Welches Secret? (Nummer oder Name):"
  read -p "  > " CHOICE

  if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
    SECRET_NAME="${SECRETS[$((CHOICE-1))]}"
    [ -z "$SECRET_NAME" ] && fail "Ungültige Auswahl"
  else
    SECRET_NAME="$CHOICE"
  fi

  ask "Neuer Wert für $SECRET_NAME:"
  read -s -p "  > " SECRET_VALUE; echo ""
fi

[ -z "$SECRET_NAME" ]  && fail "Kein Secret-Name angegeben"
[ -z "$SECRET_VALUE" ] && fail "Kein Wert angegeben"

echo ""
info "Aktualisiere: $SECRET_NAME"

# ── 2. .env aktualisieren ────────────────────────────────────
info ".env aktualisieren..."
if grep -q "^${SECRET_NAME}=" "$STACK_DIR/.env"; then
  sed -i "s|^${SECRET_NAME}=.*|${SECRET_NAME}=${SECRET_VALUE}|" "$STACK_DIR/.env"
  log ".env aktualisiert"
else
  echo "${SECRET_NAME}=${SECRET_VALUE}" >> "$STACK_DIR/.env"
  log ".env — neuer Eintrag hinzugefügt"
fi

unset SECRET_VALUE

# ── 3. .env verschlüsseln → .env.gpg ────────────────────────
info ".env verschlüsseln..."
gpg --batch --yes \
  --passphrase "$BACKUP_GPG_PASSWORD" \
  --symmetric \
  --cipher-algo AES256 \
  -o "$STACK_DIR/.env.gpg" \
  "$STACK_DIR/.env" || fail "GPG Verschlüsselung fehlgeschlagen"
log ".env.gpg aktualisiert"

# ── 4. git commit + push ─────────────────────────────────────
info "git push..."
cd "$STACK_DIR"
git add .env.gpg
git diff --cached --quiet && warn "Keine Änderung in .env.gpg — kein Commit nötig" || {
  git commit -m "secret: ${SECRET_NAME} aktualisiert"
  git push origin main || fail "git push fehlgeschlagen"
  log "git push — OK"
}

# ── 5. Container neu starten? ────────────────────────────────
echo ""

case "$SECRET_NAME" in
  TELEGRAM_BOT_TOKEN|OPENCLAW_GATEWAY_TOKEN|OPENROUTER_API_KEY|BREVO_KEY)
    CONTAINER="openclaw"
    ;;
  N8N_*|ZOHO_SMTP_USER|ZOHO_SMTP_PASSWORD|BREVO_SMTP_USER|BREVO_SMTP_API_KEY)
    CONTAINER="n8n openclaw"
    ;;
  CLOUDFLARE_TUNNEL_TOKEN)
    CONTAINER="cloudflared"
    ;;
  CF_TOKEN|CF_ZONE_ID|CF_ACCOUNT_ID|CF_TUNNEL_ID)
    CONTAINER=""
    warn "$SECRET_NAME ist ein Cloudflare API-Wert — kein Container-Neustart nötig"
    ;;
  *)
    CONTAINER=""
    ;;
esac

if [ -n "$CONTAINER" ]; then
  ask "Container '$CONTAINER' neu starten? (j/n)"
  read -p "  > " RESTART
  if [ "$RESTART" = "j" ] || [ "$RESTART" = "J" ]; then
    cd "$STACK_DIR"
    docker compose up -d --force-recreate $CONTAINER
    log "$CONTAINER neu gestartet"
  else
    warn "$CONTAINER läuft noch mit altem Wert — manuell neu starten:"
    warn "  cd $STACK_DIR && docker compose up -d --force-recreate $CONTAINER"
  fi
fi

echo ""
log "Fertig — $SECRET_NAME aktualisiert"
echo ""
