#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  Ugly Stack — Secret setzen / aktualisieren
#  Aktualisiert .env UND Cloudflare Secrets Store gleichzeitig
#
#  Verwendung:
#    ./set-secret.sh TELEGRAM_BOT_TOKEN "123456:ABC..."
#    ./set-secret.sh                    (interaktiv)
# ─────────────────────────────────────────────────────────────

STACK_DIR="/home/alex/ugly-stack"
CF_API="https://api.cloudflare.com/client/v4"

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

[ -z "$CF_TOKEN" ]   && fail "CF_TOKEN fehlt in .env"
[ -z "$CF_ACCOUNT" ] && fail "CF_ACCOUNT fehlt in .env"

# Argumente oder interaktiv
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
    BACKUP_GPG_PASSWORD
    CF_R2_ACCESS_KEY
    CF_R2_SECRET_KEY
    CF_R2_BUCKET
    CF_R2_ENDPOINT
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

# ── 1. Cloudflare Secrets Store ──────────────────────────────
info "Cloudflare Secrets Store..."
CF_RESPONSE=$(curl -s -X PUT \
  "$CF_API/accounts/$CF_ACCOUNT/secrets/$SECRET_NAME" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$SECRET_NAME\",\"value\":\"$SECRET_VALUE\"}")

CF_SUCCESS=$(echo "$CF_RESPONSE" | jq -r '.success' 2>/dev/null)
if [ "$CF_SUCCESS" = "true" ]; then
  log "Cloudflare Secrets Store — OK"
else
  CF_ERROR=$(echo "$CF_RESPONSE" | jq -r '.errors[0].message' 2>/dev/null)
  warn "Cloudflare Fehler: $CF_ERROR"
  warn "Nur .env wird aktualisiert"
fi

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

# ── 3. Container neu starten? ────────────────────────────────
echo ""

# Welcher Container braucht den Key?
case "$SECRET_NAME" in
  TELEGRAM_BOT_TOKEN|OPENCLAW_GATEWAY_TOKEN|OPENROUTER_API_KEY)
    CONTAINER="ugly-agent"
    ;;
  N8N_*|ZOHO_SMTP_USER|ZOHO_SMTP_PASSWORD|BREVO_SMTP_USER|BREVO_SMTP_API_KEY)
    CONTAINER="n8n"
    ;;
  CLOUDFLARE_TUNNEL_TOKEN)
    CONTAINER="cloudflared"
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
    docker compose up -d --force-recreate "$CONTAINER"
    log "$CONTAINER neu gestartet"
  else
    warn "$CONTAINER läuft noch mit altem Wert — manuell neu starten:"
    warn "  cd $STACK_DIR && docker compose up -d --force-recreate $CONTAINER"
  fi
fi

echo ""
log "Fertig — $SECRET_NAME aktualisiert"
echo ""
