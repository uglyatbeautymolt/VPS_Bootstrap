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
REPO_URL="https://github.com/uglyatbeautymolt/VPS_Bootstrap.git"

# ─────────────────────────────────────────────────────────────
# SCHRITT 1 — BITWARDEN LOGIN + GPG PASSWORT HOLEN
# ─────────────────────────────────────────────────────────────
info "Schritt 1/7 — Bitwarden Login..."
echo ""

# Basis-Tools installieren
apt-get update -qq
apt-get install -y -qq curl unzip jq gpg git

# Bitwarden CLI installieren
if ! command -v bw &>/dev/null; then
  info "Bitwarden CLI installieren..."
  curl -fsSL "https://vault.bitwarden.com/download/?app=cli&platform=linux" \
    -o /tmp/bw.zip
  unzip -q /tmp/bw.zip -d /tmp/bw
  mv /tmp/bw/bw /usr/local/bin/bw
  chmod +x /usr/local/bin/bw
  rm -rf /tmp/bw /tmp/bw.zip
  log "Bitwarden CLI installiert"
fi

ask "Bitwarden E-Mail:"
read -p "  > " BW_EMAIL

ask "Bitwarden Master-Passwort:"
read -s -p "  > " BW_MASTER; echo ""

# Login
BW_SESSION=$(bw login "$BW_EMAIL" "$BW_MASTER" --raw 2>/dev/null \
  || bw unlock "$BW_MASTER" --raw 2>/dev/null) \
  || fail "Bitwarden Login fehlgeschlagen"

unset BW_MASTER

# GPG Passwort holen
BACKUP_GPG_PASSWORD=$(bw get item "BACKUP_GPG_PASSWORD" \
  --session "$BW_SESSION" | jq -r '.login.password')

[ -z "$BACKUP_GPG_PASSWORD" ] || [ "$BACKUP_GPG_PASSWORD" = "null" ] \
  && fail "BACKUP_GPG_PASSWORD nicht in Bitwarden gefunden"

# Bitwarden sperren
bw lock --session "$BW_SESSION" &>/dev/null
unset BW_SESSION BW_EMAIL
log "GPG Passwort aus Bitwarden geholt — Bitwarden gesperrt"

# ─────────────────────────────────────────────────────────────
# SCHRITT 2 — USER ALEX ANLEGEN
# ─────────────────────────────────────────────────────────────
info "Schritt 2/7 — User 'alex' anlegen..."

if id "alex" &>/dev/null; then
  warn "User 'alex' existiert bereits"
else
  useradd -m -s /bin/bash alex
  log "User 'alex' angelegt"
fi

usermod -aG sudo alex

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
log "User 'alex' bereit (sudo)"

# ─────────────────────────────────────────────────────────────
# SCHRITT 3 — SYSTEM + TOOLS + DOCKER
# ─────────────────────────────────────────────────────────────
info "Schritt 3/7 — System + Docker installieren..."

apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl git unzip jq gpg \
  ca-certificates gnupg \
  lsb-release apt-transport-https \
  software-properties-common rclone

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
# SCHRITT 4 — REPO CLONEN + .env ENTSCHLÜSSELN
# ─────────────────────────────────────────────────────────────
info "Schritt 4/7 — Repository clonen..."

if [ -d "$STACK_DIR" ]; then
  warn "$STACK_DIR existiert — wird gesichert"
  mv "$STACK_DIR" "${STACK_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
fi

git clone "$REPO_URL" "$STACK_DIR"
cd "$STACK_DIR"

# .env.gpg entschlüsseln
[ ! -f ".env.gpg" ] && fail ".env.gpg nicht im Repository gefunden"

gpg --batch --yes \
  --passphrase "$BACKUP_GPG_PASSWORD" \
  --decrypt .env.gpg > .env

# BACKUP_GPG_PASSWORD in .env eintragen
echo "BACKUP_GPG_PASSWORD=${BACKUP_GPG_PASSWORD}" >> .env
unset BACKUP_GPG_PASSWORD

log ".env entschlüsselt"

# Verzeichnisse anlegen
mkdir -p "$STACK_DIR"/{openclaw-data,n8n-data,searxng-data,www}

# n8n läuft als User node (UID 1000) — Volume muss entsprechend gehören
chown -R 1000:1000 "$STACK_DIR/n8n-data"

# openclaw.json vorerstellen — bind lan + controlUi
source "$STACK_DIR/.env" 2>/dev/null || true
cat > "$STACK_DIR/openclaw-data/openclaw.json" << CLAWCONFIG
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "${OPENCLAW_GATEWAY_TOKEN}"
    },
    "trustedProxies": ["10.0.0.0/8", "172.16.0.0/12"],
    "controlUi": {
      "allowedOrigins": [
        "https://claw.beautymolt.com",
        "https://claw.beautymolt.com/"
      ],
      "allowInsecureAuth": true,
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  }
}
CLAWCONFIG
chown -R 1000:1000 "$STACK_DIR/openclaw-data"
log "openclaw.json vorbereitet (bind: lan)"

# rclone konfigurieren
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
log "Repository geclont und konfiguriert"

# ─────────────────────────────────────────────────────────────
# SCHRITT 5 — BACKUP VON R2 WIEDERHERSTELLEN
# ─────────────────────────────────────────────────────────────
info "Schritt 5/7 — Backup von R2 wiederherstellen..."

LATEST=$(rclone ls "r2:${CF_R2_BUCKET}/backups/" \
  --config "$STACK_DIR/rclone/rclone.conf" 2>/dev/null \
  | sort | tail -1 | awk '{print $2}')

if [ -n "$LATEST" ]; then
  info "Backup gefunden: $LATEST"
  rclone copy "r2:${CF_R2_BUCKET}/backups/$LATEST" /tmp/ \
    --config "$STACK_DIR/rclone/rclone.conf"

  gpg --batch --yes \
    --passphrase "$BACKUP_GPG_PASSWORD" \
    --decrypt "/tmp/$LATEST" \
    | tar -xz -C "$STACK_DIR/"

  rm -f "/tmp/$LATEST"
  log "Backup wiederhergestellt"
else
  warn "Kein Backup gefunden — frischer Start"
fi

# n8n Credentials + Workflows wiederherstellen
N8N_CREDS="r2:${CF_R2_BUCKET}/n8n/credentials-backup.json.gpg"
N8N_FLOWS="r2:${CF_R2_BUCKET}/n8n/workflows-backup.json.gpg"

if rclone ls "$N8N_CREDS" --config "$STACK_DIR/rclone/rclone.conf" &>/dev/null; then
  info "n8n Backup wiederherstellen..."
  rclone copy "$N8N_CREDS" /tmp/ --config "$STACK_DIR/rclone/rclone.conf"
  rclone copy "$N8N_FLOWS" /tmp/ --config "$STACK_DIR/rclone/rclone.conf"

  gpg --batch --yes --passphrase "$BACKUP_GPG_PASSWORD" \
    --decrypt /tmp/credentials-backup.json.gpg \
    > /tmp/credentials-backup.json
  gpg --batch --yes --passphrase "$BACKUP_GPG_PASSWORD" \
    --decrypt /tmp/workflows-backup.json.gpg \
    > /tmp/workflows-backup.json

  mkdir -p "$STACK_DIR/n8n-data"
  cp /tmp/credentials-backup.json "$STACK_DIR/n8n-data/"
  cp /tmp/workflows-backup.json "$STACK_DIR/n8n-data/"
  rm -f /tmp/credentials-backup.json* /tmp/workflows-backup.json*
  log "n8n Backup bereit"
fi

# www Webseite wiederherstellen
WWW_LATEST=$(rclone ls "r2:${CF_R2_BUCKET}/www/" \
  --config "$STACK_DIR/rclone/rclone.conf" 2>/dev/null \
  | sort | tail -1 | awk '{print $2}')

if [ -n "$WWW_LATEST" ]; then
  info "www Backup wiederherstellen: $WWW_LATEST"
  rclone copy "r2:${CF_R2_BUCKET}/www/$WWW_LATEST" /tmp/ \
    --config "$STACK_DIR/rclone/rclone.conf"

  gpg --batch --yes \
    --passphrase "$BACKUP_GPG_PASSWORD" \
    --decrypt "/tmp/$WWW_LATEST" \
    | tar -xz -C "$STACK_DIR/www/"

  rm -f "/tmp/$WWW_LATEST"
  log "www Webseite wiederhergestellt → $STACK_DIR/www/"
else
  warn "Kein www Backup gefunden — leeres www Verzeichnis"
fi

# ─────────────────────────────────────────────────────────────
# SCHRITT 6 — STACK STARTEN
# ─────────────────────────────────────────────────────────────
info "Schritt 6/7 — Stack starten..."

cd "$STACK_DIR"
docker compose pull
docker compose up -d

sleep 30
docker compose ps

# OpenClaw Token aus Config lesen und .env aktualisieren
NEW_TOKEN=$(docker exec openclaw cat /home/node/.openclaw/openclaw.json 2>/dev/null   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('gateway',{}).get('auth',{}).get('token',''))" 2>/dev/null)
if [ -n "$NEW_TOKEN" ] && [ "$NEW_TOKEN" != "null" ]; then
  sed -i "s/OPENCLAW_GATEWAY_TOKEN=.*/OPENCLAW_GATEWAY_TOKEN=$NEW_TOKEN/" "$STACK_DIR/.env"
  # openclaw.json mit korrektem Token neu schreiben
  cat > "$STACK_DIR/openclaw-data/openclaw.json" << CLAWCONFIG
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "$NEW_TOKEN"
    },
    "trustedProxies": ["10.0.0.0/8", "172.16.0.0/12"],
    "controlUi": {
      "allowedOrigins": [
        "https://claw.beautymolt.com",
        "https://claw.beautymolt.com/"
      ],
      "allowInsecureAuth": true,
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  }
}
CLAWCONFIG
  chown 1000:1000 "$STACK_DIR/openclaw-data/openclaw.json"
  log "OpenClaw Gateway Token in .env aktualisiert"
fi

# n8n Workflows + Credentials importieren
if [ -f "$STACK_DIR/n8n-data/workflows-backup.json" ]; then
  info "n8n Workflows importieren..."
  docker compose exec -T n8n \
    n8n import:workflow --input=/home/node/.n8n/workflows-backup.json 2>/dev/null || true
  docker compose exec -T n8n \
    n8n import:credentials --input=/home/node/.n8n/credentials-backup.json 2>/dev/null || true
  log "n8n Workflows importiert"
fi

# ─────────────────────────────────────────────────────────────
# SCHRITT 7 — CRON + FIREWALL
# ─────────────────────────────────────────────────────────────
info "Schritt 7/7 — Cron + Firewall..."

# Backup-Cron
chmod +x "$STACK_DIR/backup/backup-master.sh"
(crontab -u alex -l 2>/dev/null; \
  echo "0 3 * * * $STACK_DIR/backup/backup-master.sh >> $STACK_DIR/backup/backup.log 2>&1") \
  | crontab -u alex -
log "Backup-Cron eingerichtet (täglich 03:00)"

# .env.gpg Sync-Cron — verschlüsselt .env und pusht zu GitHub
(crontab -u alex -l 2>/dev/null; \
  echo "*/30 * * * * cd $STACK_DIR && gpg --batch --yes --passphrase \"\$BACKUP_GPG_PASSWORD\" --symmetric --cipher-algo AES256 -o .env.gpg .env && git add .env.gpg && git diff --cached --quiet || git commit -m 'update: .env sync' && git push origin main") \
  | crontab -u alex -
log ".env Sync-Cron eingerichtet (alle 30 Min)"

# www Backup-Cron — prüft auf Änderungen und lädt zu R2 hoch
cat > "$STACK_DIR/backup/www-sync.sh" << 'WWWSYNC'
#!/bin/bash
# www Sync zu R2 — nur wenn Änderungen vorhanden
STACK_DIR="/home/alex/ugly-stack"
WWW_DIR="$STACK_DIR/www"
CHECKSUM_FILE="$STACK_DIR/backup/.www-checksum"

source "$STACK_DIR/.env"

# Aktuellen Checksum berechnen
CURRENT=$(find "$WWW_DIR" -type f -exec md5sum {} \; | sort | md5sum | cut -d' ' -f1)

# Mit letztem Checksum vergleichen
LAST=$(cat "$CHECKSUM_FILE" 2>/dev/null || echo "")

if [ "$CURRENT" = "$LAST" ]; then
  exit 0  # Keine Änderungen
fi

# Änderungen gefunden — Backup erstellen
DATE=$(date +%Y%m%d_%H%M%S)
tar -czf /tmp/www-backup-${DATE}.tar.gz -C "$WWW_DIR" .

gpg --batch --yes \
  --passphrase "$BACKUP_GPG_PASSWORD" \
  --symmetric --cipher-algo AES256 \
  /tmp/www-backup-${DATE}.tar.gz

rclone copy /tmp/www-backup-${DATE}.tar.gz.gpg \
  r2:${CF_R2_BUCKET}/www/ \
  --config "$STACK_DIR/rclone/rclone.conf"

rm -f /tmp/www-backup-${DATE}.tar.gz \
      /tmp/www-backup-${DATE}.tar.gz.gpg

# Checksum aktualisieren
echo "$CURRENT" > "$CHECKSUM_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] www Backup → R2: www-backup-${DATE}.tar.gz.gpg"
WWWSYNC

chmod +x "$STACK_DIR/backup/www-sync.sh"

(crontab -u alex -l 2>/dev/null; \
  echo "*/15 * * * * $STACK_DIR/backup/www-sync.sh >> $STACK_DIR/backup/backup.log 2>&1") \
  | crontab -u alex -
log "www Sync-Cron eingerichtet (alle 15 Min — nur bei Änderungen)"

# Firewall
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw --force enable
log "Firewall konfiguriert"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║      Installation abgeschlossen          ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Stack:    $STACK_DIR"
echo "  User:     alex (sudo)"
echo "  Backup:   täglich 03:00 → R2"
echo "  .env:     alle 30 Min → GitHub"
echo ""
echo "  Services:"
echo "    claw.beautymolt.com    → OpenClaw"
echo "    search.beautymolt.com  → SearXNG"
echo "    n8n.beautymolt.com     → n8n"
echo "    www.beautymolt.com     → nginx"
echo ""
