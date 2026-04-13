#!/bin/bash
set -e
# ─────────────────────────────────────────────────────────────
# Ugly Stack — Bootstrap Script
# Version: V.20260413_1325
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

bw_spinner() {
  local pid=$1
  local text=$2
  printf "  ${BLUE}→${NC} ${text} "
  while kill -0 "$pid" 2>/dev/null; do
    printf "."
    sleep 0.1
  done
  echo ""
}

BOOTSTRAP_VERSION="V.20260413_1325"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║ Ugly Stack — Bootstrap                   ║"
echo "║ beautymolt.com                           ║"
echo "║ ${BOOTSTRAP_VERSION}                  ║"
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
read -s -p "  > " BW_PASSWORD; echo ""

export BW_PASSWORD

info "Verbinde mit Bitwarden..."
bw logout &>/dev/null || true

BW_SESSION=$(bw login "$BW_EMAIL" --passwordenv BW_PASSWORD --raw) \
  || fail "Bitwarden Login fehlgeschlagen — E-Mail, Passwort oder OTP-Code prüfen"

unset BW_PASSWORD

[ -z "$BW_SESSION" ] || [ ${#BW_SESSION} -lt 20 ] \
  && fail "Bitwarden Session ungültig — Login fehlgeschlagen"

log "Bitwarden Login erfolgreich"

info "Secrets aus Bitwarden holen..."

BACKUP_GPG_PASSWORD=$(bw get item "BACKUP_GPG_PASSWORD" \
  --session "$BW_SESSION" | jq -r '.login.password') \
  || fail "Fehler beim Holen von BACKUP_GPG_PASSWORD"

GITHUB_TOKEN=$(bw get item "GITHUB_TOKEN" \
  --session "$BW_SESSION" | jq -r '.login.password') \
  || fail "Fehler beim Holen von GITHUB_TOKEN"

[ -z "$BACKUP_GPG_PASSWORD" ] || [ "$BACKUP_GPG_PASSWORD" = "null" ] \
  && fail "BACKUP_GPG_PASSWORD nicht in Bitwarden gefunden"
[ -z "$GITHUB_TOKEN" ] || [ "$GITHUB_TOKEN" = "null" ] \
  && fail "GITHUB_TOKEN nicht in Bitwarden gefunden"

bw lock --session "$BW_SESSION" &>/dev/null || true
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

# Nur sudo hier — docker-Gruppe wird nach Docker-Installation in Schritt 3 gesetzt
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
# SCHRITT 3 — SYSTEM + TOOLS + DOCKER + UNATTENDED-UPGRADES
# ─────────────────────────────────────────────────────────────
info "Schritt 3/7 — System + Docker + Auto-Updates installieren..."

apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl git unzip jq gpg \
  ca-certificates gnupg \
  lsb-release apt-transport-https \
  software-properties-common rclone \
  unattended-upgrades update-notifier-common

if command -v docker &>/dev/null; then
  warn "Docker bereits installiert"
else
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker && systemctl start docker
  log "Docker installiert"
fi

# docker-Gruppe erst NACH Docker-Installation setzen
usermod -aG docker alex
log "User 'alex' zur docker-Gruppe hinzugefügt"

# ── unattended-upgrades konfigurieren ────────────────────────
cat > /etc/apt/apt.conf.d/51ugly-upgrades << 'UPGRADES'
// Ugly Stack — Auto-Update Konfiguration
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
    "${distro_id}:${distro_codename}-updates";
    "Docker:${distro_codename}";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:30";
UPGRADES

mkdir -p /etc/systemd/system/apt-daily.timer.d
cat > /etc/systemd/system/apt-daily.timer.d/override.conf << 'TIMER'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00
RandomizedDelaySec=0
TIMER

mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf << 'TIMER'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00
RandomizedDelaySec=0
TIMER

systemctl daemon-reload
systemctl enable unattended-upgrades
systemctl restart unattended-upgrades
log "unattended-upgrades konfiguriert (täglich 03:00, Reboot 03:30)"

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

if ! grep -q "^BACKUP_GPG_PASSWORD=" "$STACK_DIR/.env"; then
  echo "BACKUP_GPG_PASSWORD=${BACKUP_GPG_PASSWORD}" >> "$STACK_DIR/.env"
else
  sed -i "s|^BACKUP_GPG_PASSWORD=.*|BACKUP_GPG_PASSWORD=${BACKUP_GPG_PASSWORD}|" "$STACK_DIR/.env"
fi
log ".env entschlüsselt"

chmod +x "$STACK_DIR/bootstrap.sh"
chmod +x "$STACK_DIR/set-secret.sh"
chmod +x "$STACK_DIR/backup/backup-master.sh"
chmod +x "$STACK_DIR/backup/modules/"*.sh
chmod +x "$STACK_DIR/backup/restore/restore-master.sh"
chmod +x "$STACK_DIR/backup/restore/modules/"*.sh
log "Scripts ausführbar gemacht"

mkdir -p "$STACK_DIR"/{openclaw-data,n8n-data,searxng-data,www}

grep -q "roundcube-data/" "$STACK_DIR/.gitignore" \
  || echo "roundcube-data/" >> "$STACK_DIR/.gitignore"
grep -q "backup/www-sync.sh" "$STACK_DIR/.gitignore" \
  || echo "backup/www-sync.sh" >> "$STACK_DIR/.gitignore"
grep -q "backup/.www-checksum" "$STACK_DIR/.gitignore" \
  || echo "backup/.www-checksum" >> "$STACK_DIR/.gitignore"
log ".gitignore aktualisiert"

cat > /etc/sudoers.d/alex-ugly-stack << SUDOERS
# sudo Passwort-Timeout: 60 Minuten
Defaults:alex timestamp_timeout=60

# Backup: tar auf openclaw-data (Ownership 1000:1000 → braucht root)
alex ALL=(root) NOPASSWD: /bin/tar -czf * -C ${STACK_DIR}/openclaw-data .

# Lesen: openclaw-data Dateien inspizieren ohne Passwort
alex ALL=(root) NOPASSWD: /bin/ls * ${STACK_DIR}/openclaw-data
alex ALL=(root) NOPASSWD: /bin/cat ${STACK_DIR}/openclaw-data/*
alex ALL=(root) NOPASSWD: /usr/bin/find ${STACK_DIR}/openclaw-data *
alex ALL=(root) NOPASSWD: /usr/bin/grep -r * ${STACK_DIR}/openclaw-data/
SUDOERS
chmod 440 /etc/sudoers.d/alex-ugly-stack
log "sudoers: 60 Min Timeout + openclaw-data Lesezugriff für alex"

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
  log "openclaw.json Basis-Konfiguration erstellt"
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

chown -R alex:alex "$STACK_DIR"
chown -R 1000:1000 "$STACK_DIR/openclaw-data"
chown -R 1000:1000 "$STACK_DIR/n8n-data"

sudo -u alex git -C "$STACK_DIR" remote set-url origin \
  "https://${GITHUB_TOKEN}@github.com/uglyatbeautymolt/VPS_Bootstrap.git"
sudo -u alex git -C "$STACK_DIR" config user.name "Ugly"
sudo -u alex git -C "$STACK_DIR" config user.email "ugly@beautymolt.com"
unset GITHUB_TOKEN
log "Git Remote mit Token konfiguriert"
log "Repository geclont und konfiguriert"

# ─────────────────────────────────────────────────────────────
# SCHRITT 5 — BACKUP VON R2 WIEDERHERSTELLEN
# ─────────────────────────────────────────────────────────────
info "Schritt 5/7 — Backup von R2 wiederherstellen..."

BACKUP_RESTORED=false

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

  # n8n
  mkdir -p "$STACK_DIR/n8n-data"
  [ -f "$STAGING/n8n-data/workflows-backup.json" ] && \
    cp "$STAGING/n8n-data/workflows-backup.json" "$STACK_DIR/n8n-data/"
  [ -f "$STAGING/n8n-data/credentials-backup.json" ] && \
    cp "$STAGING/n8n-data/credentials-backup.json" "$STACK_DIR/n8n-data/"
  chown -R 1000:1000 "$STACK_DIR/n8n-data"

  # openclaw
  if ls "$STAGING/openclaw-data/"*.tar.gz &>/dev/null; then
    mkdir -p "$STACK_DIR/openclaw-data"
    tar -xzf "$STAGING/openclaw-data/"*.tar.gz -C "$STACK_DIR/openclaw-data/"
    chown -R 1000:1000 "$STACK_DIR/openclaw-data"
    BACKUP_RESTORED=true
    log "OpenClaw Backup wiederhergestellt"
  fi

  # nginx
  mkdir -p "$STACK_DIR/nginx/conf.d"
  [ -d "$STAGING/nginx/conf.d" ] && \
    cp -r "$STAGING/nginx/conf.d/." "$STACK_DIR/nginx/conf.d/"

  # www
  mkdir -p "$STACK_DIR/www"
  [ -d "$STAGING/www" ] && \
    cp -r "$STAGING/www/." "$STACK_DIR/www/"

  rm -rf "$STAGING"
  log "Backup wiederhergestellt aus: $LATEST"
else
  warn "Kein Backup gefunden — frischer Start"
fi

info "openclaw.json prüfen und korrigieren..."
if [ -f "$STACK_DIR/openclaw-data/openclaw.json" ]; then
  python3 << PYFIX
import json, sys

path = "$STACK_DIR/openclaw-data/openclaw.json"
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception as e:
    print(f"openclaw.json Lesefehler: {e}")
    sys.exit(1)

changed = False

if cfg.get("gateway", {}).get("bind") != "lan":
    cfg.setdefault("gateway", {})["bind"] = "lan"
    changed = True
    print("  Fix: bind → lan")

if not cfg.get("hooks", {}).get("enabled"):
    hook_token = ""
    try:
        with open("$STACK_DIR/.env") as ef:
            for line in ef:
                if line.startswith("OPENCLAW_HOOK_TOKEN="):
                    hook_token = line.strip().split("=", 1)[1]
    except:
        pass
    cfg["hooks"] = {
        "enabled": True,
        "token": hook_token if hook_token else "UglyHook2026!beautymolt",
        "path": "/hooks"
    }
    changed = True
    print("  Fix: hooks Block hinzugefügt")

if changed:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print("  openclaw.json aktualisiert")
else:
    print("  openclaw.json bereits korrekt")
PYFIX
  chown 1000:1000 "$STACK_DIR/openclaw-data/openclaw.json"
  log "openclaw.json geprüft"
fi

if [ -f "$STACK_DIR/openclaw-data/openclaw.json" ]; then
  RESTORED_TOKEN=$(python3 -c "
import json
try:
  d = json.load(open('$STACK_DIR/openclaw-data/openclaw.json'))
  print(d.get('gateway',{}).get('auth',{}).get('token',''))
except: pass
" 2>/dev/null)
  if [ -n "$RESTORED_TOKEN" ] && [ "$RESTORED_TOKEN" != "None" ]; then
    sed -i "s/OPENCLAW_GATEWAY_TOKEN=.*/OPENCLAW_GATEWAY_TOKEN=$RESTORED_TOKEN/" "$STACK_DIR/.env"
    log "OpenClaw Token aus Config → .env synchronisiert"
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

chown -R 1000:1000 "$STACK_DIR/openclaw-data"
chown -R 1000:1000 "$STACK_DIR/n8n-data"
log "openclaw-data + n8n-data Ownership auf 1000:1000 gesetzt"

# ── Portainer Admin-Passwort via Container-IP setzen ─────────
# localhost:9000 ist vom Host nicht erreichbar — Container-IP verwenden
source "$STACK_DIR/.env"
PORTAINER_ADMIN_PASSWORD="${PORTAINER_ADMIN_PASSWORD:-Ugly\$Portainer\$VPSDocker}"

info "Portainer Admin-Passwort setzen..."
PORTAINER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' portainer 2>/dev/null || echo "")

if [ -n "$PORTAINER_IP" ]; then
  # Warten bis Portainer API antwortet
  for i in $(seq 1 24); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      "http://${PORTAINER_IP}:9000/api/status" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
      log "Portainer API bereit"
      break
    fi
    warn "Portainer noch nicht bereit — warte 5s ($i/24)"
    sleep 5
  done
  # Admin-User anlegen (schlägt still fehl wenn bereits vorhanden)
  curl -s -X POST "http://${PORTAINER_IP}:9000/api/users/admin/init" \
    -H "Content-Type: application/json" \
    -d "{\"Username\":\"admin\",\"Password\":\"${PORTAINER_ADMIN_PASSWORD}\"}" \
    > /dev/null 2>&1 || true
  log "Portainer Admin gesetzt: admin / PORTAINER_ADMIN_PASSWORD"
else
  warn "Portainer Container-IP nicht gefunden — Passwort manuell setzen"
fi

# ── n8n Workflows + Credentials importieren + aktivieren ─────
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
  # Alle Workflows aktivieren — IMAP Trigger läuft sonst nach Import nicht
  docker exec n8n n8n workflow activate --all 2>/dev/null || true
  log "n8n Workflows aktiviert (IMAP Trigger aktiv)"
fi

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

(crontab -u alex -l 2>/dev/null; \
  echo "0 2 * * * bash /home/alex/ugly-stack/backup/backup-master.sh >> /home/alex/ugly-stack/backup/backup.log 2>&1") \
  | crontab -u alex -
log "Backup-Cron eingerichtet (täglich 02:00)"

ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw --force enable
log "Firewall konfiguriert"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║ Installation abgeschlossen!              ║"
echo "║ ${BOOTSTRAP_VERSION}                  ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Stack: $STACK_DIR"
echo "  User:  alex (sudo, docker)"
echo ""
echo "  Portainer Login:"
echo "    URL:      https://portainer.beautymolt.com"
echo "    User:     admin"
echo "    Passwort: Ugly\$Portainer\$VPSDocker"
echo ""
echo "  Zeitplan (UTC):"
echo "    02:00 — Backup → R2 + .env → GitHub + Status-Mail"
echo "    02:30 — Watchtower → Container-Updates"
echo "    03:00 — unattended-upgrades → System + Docker Engine"
echo "    03:30 — Automatischer Neustart (falls Kernel-Update)"
echo ""
echo "  Services:"
echo "    claw.beautymolt.com      → OpenClaw"
echo "    search.beautymolt.com    → SearXNG"
echo "    n8n.beautymolt.com       → n8n"
echo "    www.beautymolt.com       → nginx"
echo "    mail.beautymolt.com      → Roundcube"
echo "    portainer.beautymolt.com → Portainer"
echo ""
if [ "$BACKUP_RESTORED" = false ]; then
  warn "Kein Backup wiederhergestellt — Telegram Onboarding nötig:"
  echo "  docker exec -it openclaw node /app/dist/index.js onboard"
  echo ""
fi
echo "  HINWEIS: Neu einloggen damit docker-Gruppe aktiv wird:"
echo "  su - alex"
echo ""
