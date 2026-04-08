#!/bin/bash
set -e
# ─────────────────────────────────────────────────────────────
# Ugly Stack — Bootstrap Script
# Frischer Ubuntu 24.04 VPS — als root ausführen
# curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh -o bootstrap.sh
# chmod +x bootstrap.sh && ./bootstrap.sh
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
echo "║ Ugly Stack — Bootstrap                   ║"
echo "║ beautymolt.com                           ║"
echo "╚══════════════════════════════════════════╝"
echo ""

[ "$EUID" -ne 0 ] && fail "Bitte als root ausführen"

STACK_DIR="/home/alex/ugly-stack"
REPO_URL="https://github.com/uglyatbeautymolt/VPS_Bootstrap.git"

# ─────────────────────────────────────────────────────────────
# SCHRITT 1 — BITWARDEN LOGIN + SECRETS HOLEN
# ─────────────────────────────────────────────────────────────
info "Schritt 1/7 — Bitwarden Login..."
echo ""

apt-get update -qq
apt-get install -y -qq curl unzip jq gpg git

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

# Login-Versuch — löst OTP aus falls New Device
info "Verbinde mit Bitwarden..."
BW_SESSION=$(bw login "$BW_EMAIL" "$BW_MASTER" --raw 2>/dev/null) || {
  # Login hat einen OTP Code per E-Mail geschickt — jetzt abfragen
  echo ""
  warn "Bitwarden hat einen Verification Code an deine E-Mail geschickt."
  warn "Schau JETZT in dein E-Mail Postfach und gib den Code ein."
  echo ""
  ask "Bitwarden OTP Code:"
  read -p "  > " BW_OTP
  echo ""
  info "Login mit OTP Code..."
  BW_SESSION=$(bw login "$BW_EMAIL" "$BW_MASTER" \
    --method 0 --code "$BW_OTP" --raw 2>/dev/null) \
    || fail "Bitwarden Login fehlgeschlagen — falscher OTP oder abgelaufen"
}
unset BW_MASTER

BACKUP_GPG_PASSWORD=$(bw get item "BACKUP_GPG_PASSWORD" \
  --session "$BW_SESSION" | jq -r '.login.password')
[ -z "$BACKUP_GPG_PASSWORD" ] || [ "$BACKUP_GPG_PASSWORD" = "null" ] \
  && fail "BACKUP_GPG_PASSWORD nicht in Bitwarden gefunden"

GITHUB_TOKEN=$(bw get item "GITHUB_TOKEN" \
  --session "$BW_SESSION" | jq -r '.login.password')
[ -z "$GITHUB_TOKEN" ] || [ "$GITHUB_TOKEN" = "null" ] \
  && fail "GITHUB_TOKEN nicht in Bitwarden gefunden"

bw lock --session "$BW_SESSION" &>/dev/null
unset BW_SESSION BW_EMAIL
log "GPG Passwort + GitHub Token aus Bitwarden geholt — Bitwarden gesperrt"

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
usermod -aG docker alex

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
log "User 'alex' bereit (sudo, docker)"

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

[ ! -f ".env.gpg" ] && fail ".env.gpg nicht im Repository gefunden"

gpg --batch --yes \
  --passphrase "$BACKUP_GPG_PASSWORD" \
  --decrypt .env.gpg > .env

echo "BACKUP_GPG_PASSWORD=${BACKUP_GPG_PASSWORD}" >> .env
log ".env entschlüsselt"

mkdir -p "$STACK_DIR"/{openclaw-data,n8n-data,searxng-data,www}

grep -q "roundcube-data/" "$STACK_DIR/.gitignore" \
  || echo "roundcube-data/" >> "$STACK_DIR/.gitignore"
grep -q "backup/www-sync.sh" "$STACK_DIR/.gitignore" \
  || echo "backup/www-sync.sh" >> "$STACK_DIR/.gitignore"
grep -q "backup/.www-checksum" "$STACK_DIR/.gitignore" \
  || echo "backup/.www-checksum" >> "$STACK_DIR/.gitignore"
log ".gitignore aktualisiert"

source "$STACK_DIR/.env" 2>/dev/null || true
if [ ! -f "$STACK_DIR/openclaw-data/openclaw.json" ]; then
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
      "dangerouslyAllowHostHeaderOriginFallback": true,
      "dangerouslyDisableDeviceAuth": true
    }
  }
}
CLAWCONFIG
  log "openclaw.json vorbereitet (bind: lan)"
else
  log "openclaw.json aus Backup wiederhergestellt — wird nicht überschrieben"
fi

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

# Ownership: alex für allgemein, 1000:1000 für Container-Volumes
chown -R alex:alex "$STACK_DIR"
chown -R 1000:1000 "$STACK_DIR/openclaw-data"
chown -R 1000:1000 "$STACK_DIR/n8n-data"

sudo -u alex git -C "$STACK_DIR" remote set-url origin \
  "https://${GITHUB_TOKEN}@github.com/uglyatbeautymolt/VPS_Bootstrap.git"
sudo -u alex git -C "$STACK_DIR" config user.name "Ugly"
sudo -u alex git -C "$STACK_DIR" config user.email "ugly@beautymolt.com"
unset GITHUB_TOKEN
log "Git Remote mit Token konfiguriert (alex kann pushen)"
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

  STAGING="/tmp/ugly-restore-staging"
  rm -rf "$STAGING" && mkdir -p "$STAGING"

  gpg --batch --yes \
    --passphrase "$BACKUP_GPG_PASSWORD" \
    --decrypt "/tmp/$LATEST" \
    | tar -xz -C "$STAGING/"

  rm -f "/tmp/$LATEST"

  mkdir -p "$STACK_DIR/n8n-data"
  [ -f "$STAGING/n8n-data/workflows-backup.json" ] && \
    cp "$STAGING/n8n-data/workflows-backup.json" "$STACK_DIR/n8n-data/"
  [ -f "$STAGING/n8n-data/credentials-backup.json" ] && \
    cp "$STAGING/n8n-data/credentials-backup.json" "$STACK_DIR/n8n-data/"
  chown -R 1000:1000 "$STACK_DIR/n8n-data"

  if ls "$STAGING/openclaw-data/"*.tar.gz &>/dev/null; then
    mkdir -p "$STACK_DIR/openclaw-data"
    tar -xzf "$STAGING/openclaw-data/"*.tar.gz -C "$STACK_DIR/openclaw-data/"
    chown -R 1000:1000 "$STACK_DIR/openclaw-data"
  fi

  mkdir -p "$STACK_DIR/nginx/conf.d"
  [ -d "$STAGING/nginx/conf.d" ] && \
    cp -r "$STAGING/nginx/conf.d/." "$STACK_DIR/nginx/conf.d/"

  mkdir -p "$STACK_DIR/www"
  [ -d "$STAGING/www" ] && \
    cp -r "$STAGING/www/." "$STACK_DIR/www/"

  rm -rf "$STAGING"
  log "Backup wiederhergestellt aus: $LATEST"
else
  warn "Kein Backup gefunden — frischer Start"
fi

if [ -f "$STACK_DIR/openclaw-data/openclaw.json" ]; then
  RESTORED_TOKEN=$(python3 -c "
import json,sys
try:
  d = json.load(open('$STACK_DIR/openclaw-data/openclaw.json'))
  print(d.get('gateway',{}).get('auth',{}).get('token',''))
except: pass
" 2>/dev/null)
  if [ -n "$RESTORED_TOKEN" ] && [ "$RESTORED_TOKEN" != "None" ]; then
    sed -i "s/OPENCLAW_GATEWAY_TOKEN=.*/OPENCLAW_GATEWAY_TOKEN=$RESTORED_TOKEN/" "$STACK_DIR/.env"
    log "OpenClaw Token aus Backup übernommen → .env synchronisiert"
  fi
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

# Container-Volumes brauchen 1000:1000
chown -R 1000:1000 "$STACK_DIR/openclaw-data"
chown -R 1000:1000 "$STACK_DIR/n8n-data"
log "openclaw-data + n8n-data Ownership auf 1000:1000 gesetzt"

# OpenClaw Token aus Config lesen und .env aktualisieren
NEW_TOKEN=$(docker exec openclaw cat /home/node/.openclaw/openclaw.json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('gateway',{}).get('auth',{}).get('token',''))" 2>/dev/null)
if [ -n "$NEW_TOKEN" ] && [ "$NEW_TOKEN" != "null" ]; then
  sed -i "s/OPENCLAW_GATEWAY_TOKEN=.*/OPENCLAW_GATEWAY_TOKEN=$NEW_TOKEN/" "$STACK_DIR/.env"
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
      "dangerouslyAllowHostHeaderOriginFallback": true,
      "dangerouslyDisableDeviceAuth": true
    }
  }
}
CLAWCONFIG
  chown 1000:1000 "$STACK_DIR/openclaw-data/openclaw.json"
  log "OpenClaw Gateway Token in .env aktualisiert"
fi

# n8n Workflows + Credentials importieren — warten bis n8n wirklich bereit
if [ -f "$STACK_DIR/n8n-data/workflows-backup.json" ]; then
  info "n8n Workflows importieren — warte bis n8n bereit..."
  for i in $(seq 1 24); do
    if docker exec n8n wget -q --spider http://localhost:5678/healthz 2>/dev/null; then
      log "n8n ist bereit"
      break
    fi
    warn "n8n noch nicht bereit — warte 5s ($i/24)"
    sleep 5
  done
  docker cp "$STACK_DIR/n8n-data/workflows-backup.json" n8n:/tmp/workflows-backup.json
  docker cp "$STACK_DIR/n8n-data/credentials-backup.json" n8n:/tmp/credentials-backup.json
  docker exec n8n n8n import:workflow --input=/tmp/workflows-backup.json
  docker exec n8n n8n import:credentials --input=/tmp/credentials-backup.json
  rm -f "$STACK_DIR/n8n-data/workflows-backup.json" "$STACK_DIR/n8n-data/credentials-backup.json"
  log "n8n Workflows + Credentials importiert"
fi

# SearXNG JSON API aktivieren
if [ -f "$STACK_DIR/searxng-data/settings.yml" ]; then
  if ! grep -q "^\s*- json" "$STACK_DIR/searxng-data/settings.yml"; then
    sed -i 's/^\s*- html$/  - html\n  - json/' "$STACK_DIR/searxng-data/settings.yml"
    docker restart searxng 2>/dev/null || true
    log "SearXNG JSON API aktiviert"
  else
    log "SearXNG JSON API bereits aktiv"
  fi
fi

# ─────────────────────────────────────────────────────────────
# SCHRITT 7 — CRON + FIREWALL
# ─────────────────────────────────────────────────────────────
info "Schritt 7/7 — Cron + Firewall..."

chmod +x "$STACK_DIR/backup/backup-master.sh"
(crontab -u alex -l 2>/dev/null; \
  echo "0 3 * * * $STACK_DIR/backup/backup-master.sh >> $STACK_DIR/backup/backup.log 2>&1") \
  | crontab -u alex -
log "Backup-Cron eingerichtet (täglich 03:00)"

(crontab -u alex -l 2>/dev/null; \
  echo "*/30 * * * * cd $STACK_DIR && source $STACK_DIR/.env && gpg --batch --yes --passphrase \"\$BACKUP_GPG_PASSWORD\" --symmetric --cipher-algo AES256 -o .env.gpg .env && git add .env.gpg && git diff --cached --quiet || git commit -m 'update: .env sync' && git push origin main") \
  | crontab -u alex -
log ".env Sync-Cron eingerichtet (alle 30 Min)"

ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw --force enable
log "Firewall konfiguriert"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║ Installation abgeschlossen!              ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Stack: $STACK_DIR"
echo "  User:  alex (sudo, docker)"
echo "  Backup: täglich 03:00 → R2"
echo "  .env:   alle 30 Min → GitHub"
echo ""
echo "  Services:"
echo "    claw.beautymolt.com   → OpenClaw"
echo "    search.beautymolt.com → SearXNG"
echo "    n8n.beautymolt.com    → n8n"
echo "    www.beautymolt.com    → nginx"
echo "    mail.beautymolt.com   → Roundcube"
echo ""
echo "  WICHTIG: OpenClaw Telegram Onboarding noch nötig!"
echo "  docker exec -it openclaw node /app/dist/index.js onboard"
echo ""
echo "  HINWEIS: Neu einloggen damit docker-Gruppe aktiv wird:"
echo "  su - alex"
echo ""
