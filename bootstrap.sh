#!/bin/bash
set -e
# ─────────────────────────────────────────────────────────────
#  Ugly Stack — Bootstrap Script
#  Frischer Ubuntu 24.04 VPS — als root ausführen
#  curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh -o bootstrap.sh
#  chmod +x bootstrap.sh && ./bootstrap.sh
# ─────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()  { echo -e "${YELLOW}[?]${NC} $1"; }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        Ugly Stack — Bootstrap            ║"
echo "║        beautymolt.com                    ║"
echo "╚══════════════════════════════════════════╝"
echo ""

[ "$EUID" -ne 0 ] && fail "Bitte als root ausführen"

STACK_DIR="/home/alex/ugly-stack"
CF_API="https://api.cloudflare.com/client/v4"

# ─────────────────────────────────────────────────────────────
# SCHRITT 1 — CLOUDFLARE API TOKEN
# ─────────────────────────────────────────────────────────────
info "Schritt 1/6 — Cloudflare API Token..."
echo ""
ask "Cloudflare API Token (Secrets Store + R2 Rechte):"
read -s -p "  > " CF_TOKEN; echo ""

CF_ACCOUNT=$(curl -s "$CF_API/accounts" \
  -H "Authorization: Bearer $CF_TOKEN" \
  | jq -r '.result[0].id' 2>/dev/null)

[ -z "$CF_ACCOUNT" ] || [ "$CF_ACCOUNT" = "null" ] \
  && fail "Cloudflare Token ungültig"

log "Cloudflare Account: $CF_ACCOUNT"

# ─────────────────────────────────────────────────────────────
# SCHRITT 2 — USER ALEX ANLEGEN
# ─────────────────────────────────────────────────────────────
info "Schritt 2/6 — User 'alex' anlegen..."

if id "alex" &>/dev/null; then
  warn "User 'alex' existiert bereits"
else
  useradd -m -s /bin/bash alex
  log "User 'alex' angelegt"
fi

usermod -aG sudo alex
usermod -aG docker alex 2>/dev/null || true

echo ""
ask "Passwort für User 'alex':"
while true; do
  read -s -p "  Passwort: " ALEX_PW; echo ""
  read -s -p "  Bestätigen: " ALEX_PW2; echo ""
  [ "$ALEX_PW" = "$ALEX_PW2" ] && break
  warn "Stimmen nicht überein — nochmals"
done
echo "alex:$ALEX_PW" | chpasswd
unset ALEX_PW ALEX_PW2
log "User 'alex' bereit (sudo + docker)"

# ─────────────────────────────────────────────────────────────
# SCHRITT 3 — SYSTEM + TOOLS + DOCKER
# ─────────────────────────────────────────────────────────────
info "Schritt 3/6 — System + Docker installieren..."

apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl git unzip jq ca-certificates gnupg \
  lsb-release apt-transport-https \
  software-properties-common rclone gpg

if command -v docker &>/dev/null; then
  warn "Docker bereits installiert"
else
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker && systemctl start docker
  log "Docker installiert"
fi

usermod -aG docker alex
log "System bereit"

# ─────────────────────────────────────────────────────────────
# SCHRITT 4 — SECRETS AUS CLOUDFLARE HOLEN → .env AUFBAUEN
# ─────────────────────────────────────────────────────────────
info "Schritt 4/6 — Secrets aus Cloudflare Secrets Store holen..."

get_secret() {
  curl -s "$CF_API/accounts/$CF_ACCOUNT/secrets/$1" \
    -H "Authorization: Bearer $CF_TOKEN" \
    | jq -r '.result.value // empty' 2>/dev/null
}

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

echo "TZ=Europe/Zurich" > /tmp/ugly.env
echo "CF_TOKEN=${CF_TOKEN}" >> /tmp/ugly.env
echo "CF_ACCOUNT=${CF_ACCOUNT}" >> /tmp/ugly.env

for SECRET in "${SECRETS[@]}"; do
  VALUE=$(get_secret "$SECRET")
  if [ -n "$VALUE" ]; then
    echo "${SECRET}=${VALUE}" >> /tmp/ugly.env
    log "✓ $SECRET"
  else
    warn "$SECRET fehlt — bitte eingeben:"
    read -s -p "  > " VALUE; echo ""
    echo "${SECRET}=${VALUE}" >> /tmp/ugly.env
  fi
  unset VALUE
done

log ".env aufgebaut"

# ─────────────────────────────────────────────────────────────
# SCHRITT 5 — REPO CLONEN
# ─────────────────────────────────────────────────────────────
info "Schritt 5/6 — Repository clonen..."

if [ -d "$STACK_DIR" ]; then
  warn "$STACK_DIR existiert — wird gesichert"
  mv "$STACK_DIR" "${STACK_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
fi

git clone https://github.com/uglyatbeautymolt/VPS_Bootstrap "$STACK_DIR"

# .env ins Stack-Verzeichnis
cp /tmp/ugly.env "$STACK_DIR/.env"
rm -f /tmp/ugly.env

# Verzeichnisse anlegen (Volumes)
mkdir -p "$STACK_DIR"/{openclaw-data,n8n-data,searxng-data,www}

# rclone für R2 konfigurieren
source "$STACK_DIR/.env"
mkdir -p "$STACK_DIR/rclone"
cat > "$STACK_DIR/rclone/rclone.conf" << RCLONE
[r2]
type = s3
provider = Cloudflare
access_key_id = ${CF_R2_ACCESS_KEY}
secret_access_key = ${CF_R2_SECRET_KEY}
endpoint = ${CF_R2_ENDPOINT}
acl = private
RCLONE

chown -R alex:alex "$STACK_DIR"
log "Repository geclont"

# ─────────────────────────────────────────────────────────────
# SCHRITT 6 — BACKUP WIEDERHERSTELLEN → STACK STARTEN
# ─────────────────────────────────────────────────────────────
info "Schritt 6/6 — Backup wiederherstellen und Stack starten..."

# Neuestes Backup von R2 holen
LATEST=$(rclone ls "r2:${CF_R2_BUCKET}/backups/" \
  --config "$STACK_DIR/rclone/rclone.conf" 2>/dev/null \
  | sort | tail -1 | awk '{print $2}')

if [ -n "$LATEST" ]; then
  info "Backup gefunden: $LATEST"
  rclone copy "r2:${CF_R2_BUCKET}/backups/$LATEST" /tmp/ \
    --config "$STACK_DIR/rclone/rclone.conf"

  # Entschlüsseln + direkt in Stack-Verzeichnis entpacken
  # Backup-Struktur: openclaw-data/, n8n-data/, nginx/, www/
  echo "$BACKUP_GPG_PASSWORD" | gpg --batch --yes --passphrase-fd 0 \
    --decrypt "/tmp/$LATEST" \
    | tar -xz -C "$STACK_DIR/"

  rm -f "/tmp/$LATEST"
  log "Backup wiederhergestellt — Daten liegen in Volumes"
else
  warn "Kein Backup gefunden — frischer Start"
fi

# Backup-Cron für alex einrichten
chmod +x "$STACK_DIR/backup/backup-master.sh"
chmod +x "$STACK_DIR/backup/restore/restore-master.sh"
(crontab -u alex -l 2>/dev/null; \
  echo "0 3 * * * $STACK_DIR/backup/backup-master.sh >> $STACK_DIR/backup/backup.log 2>&1") \
  | crontab -u alex -
log "Backup-Cron eingerichtet (täglich 03:00 → R2)"

# Firewall
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw --force enable
log "Firewall konfiguriert"

# Stack starten
# Alle Volume-Daten liegen bereits an Ort und Stelle
cd "$STACK_DIR"
docker compose pull
docker compose up -d

info "Warte auf Container-Start..."
sleep 20
docker compose ps

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║      Installation abgeschlossen          ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Stack:    $STACK_DIR"
echo "  User:     alex (sudo + docker)"
echo "  Backup:   täglich 03:00 → Cloudflare R2"
echo ""
echo "  Services:"
echo "    claw.beautymolt.com    → OpenClaw"
echo "    search.beautymolt.com  → SearXNG"
echo "    n8n.beautymolt.com     → n8n"
echo "    www.beautymolt.com     → nginx"
echo ""
echo "  Container-Zugriff:"
echo "    docker exec -it ugly-agent bash"
echo "    docker exec -it n8n sh"
echo "    docker exec -it searxng sh"
echo ""
echo "  Restore:"
echo "    $STACK_DIR/backup/restore/restore-master.sh list"
echo "    $STACK_DIR/backup/restore/restore-master.sh"
echo ""
