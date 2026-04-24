#!/bin/bash
set -e
# ─────────────────────────────────────────────────────────────
# Ugly Stack — Bootstrap Script
# Frischer Ubuntu 24.04 VPS — als root ausführen
# curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh -o bootstrap.sh
# chmod +x bootstrap.sh && ./bootstrap.sh
# ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()  { echo -e "${YELLOW}[?]${NC} $1"; }

BOOTSTRAP_VERSION="V.$(TZ=Europe/Zurich date '+%Y%m%d_%H%M%S')"

fix_volume_ownership() {
  local dir="$1"
  local alex_gid; alex_gid=$(id -g alex 2>/dev/null || echo "1001")
  chown -R 1000:${alex_gid} "$dir"
  chmod -R g+rX "$dir"
}

# apt-get update mit Retry — bei Mirror-Fehler Prompt anzeigen
apt_update() {
  local max_retries=3
  local attempt=1
  while true; do
    if apt-get update -qq 2>/tmp/apt_update_err; then
      return 0
    fi
    if [ $attempt -ge $max_retries ]; then
      cat /tmp/apt_update_err
      fail "apt-get update nach $max_retries Versuchen fehlgeschlagen — Abbruch"
    fi
    warn "apt-get update fehlgeschlagen — Mirror möglicherweise out-of-sync."
    warn "  Fehler: $(tail -1 /tmp/apt_update_err)"
    echo ""
    echo -e "  ${YELLOW}Retry $attempt/$((max_retries-1)) in 30s...${NC} (Enter für sofortigen Retry, Ctrl+C zum Abbrechen)"
    read -t 30 -p "  > " _ || true
    attempt=$((attempt + 1))
    info "Retry $attempt — apt-get update..."
  done
}

banner() {
  local line1="Ugly Stack — Bootstrap"
  local line2="beautymolt.com"
  local line3="$BOOTSTRAP_VERSION"
  local width=0
  for s in "$line1" "$line2" "$line3"; do
    [ ${#s} -gt $width ] && width=${#s}
  done
  local bar; bar=$(printf '%*s' $((width + 2)) '' | tr ' ' '─')
  echo ""
  echo "╔${bar}╗"
  printf "║ %-*s ║\n" "$width" "$line1"
  printf "║ %-*s ║\n" "$width" "$line2"
  printf "║ %-*s ║\n" "$width" "$line3"
  echo "╚${bar}╝"
  echo ""
}
banner

[ "$EUID" -ne 0 ] && fail "Bitte als root ausführen"

STACK_DIR="/home/alex/ugly-stack"
REPO_URL="https://github.com/uglyatbeautymolt/VPS_Bootstrap.git"

# ─────────────────────────────────────────────────────────────
# SCHRITT 1 — BITWARDEN LOGIN + SECRETS HOLEN
# ─────────────────────────────────────────────────────────────
info "Schritt 1/8 — Bitwarden Login..."
echo ""

apt_update
apt-get install -y -qq curl unzip jq gpg git sqlite3

if ! command -v bw &>/dev/null; then
  info "Bitwarden CLI installieren..."
  curl -fsSL "https://vault.bitwarden.com/download/?app=cli&platform=linux" -o /tmp/bw.zip
  unzip -q /tmp/bw.zip -d /tmp/bw
  mv /tmp/bw/bw /usr/local/bin/bw
  chmod +x /usr/local/bin/bw
  rm -rf /tmp/bw /tmp/bw.zip
  log "Bitwarden CLI installiert"
fi

ask "Bitwarden E-Mail:"; read -p "  > " BW_EMAIL
warn "Hinweis: Bitwarden sendet ein OTP per E-Mail wenn dieses Gerät neu ist."
warn "         Das OTP wird automatisch als zweiter Faktor abgefragt."
ask "Bitwarden Master-Passwort:"; read -s -p "  > " BW_PASSWORD; echo ""
export BW_PASSWORD
info "Verbinde mit Bitwarden..."
bw logout &>/dev/null || true

BW_SESSION=$(bw login "$BW_EMAIL" --passwordenv BW_PASSWORD --raw) \
  || fail "Bitwarden Login fehlgeschlagen — E-Mail, Passwort oder OTP-Code prüfen"
unset BW_PASSWORD
[ -z "$BW_SESSION" ] || [ ${#BW_SESSION} -lt 20 ] && fail "Bitwarden Session ungültig"
log "Bitwarden Login erfolgreich"

BACKUP_GPG_PASSWORD=$(bw get item "BACKUP_GPG_PASSWORD" --session "$BW_SESSION" | jq -r '.login.password')
GITHUB_TOKEN=$(bw get item "GITHUB_TOKEN" --session "$BW_SESSION" | jq -r '.login.password')
[ -z "$BACKUP_GPG_PASSWORD" ] || [ "$BACKUP_GPG_PASSWORD" = "null" ] && fail "BACKUP_GPG_PASSWORD nicht gefunden"
[ -z "$GITHUB_TOKEN" ]        || [ "$GITHUB_TOKEN" = "null" ]        && fail "GITHUB_TOKEN nicht gefunden"

bw lock --session "$BW_SESSION" &>/dev/null || true
unset BW_SESSION BW_EMAIL
log "GPG Passwort + GitHub Token geholt — Bitwarden gesperrt"

# ─────────────────────────────────────────────────────────────
# SCHRITT 2 — USER ALEX ANLEGEN + SSH OPTIMIEREN
# ─────────────────────────────────────────────────────────────
info "Schritt 2/8 — User 'alex' anlegen..."

if id "alex" &>/dev/null; then warn "User 'alex' existiert bereits"
else useradd -m -s /bin/bash alex; log "User 'alex' angelegt"; fi

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

# SSH: Reverse-DNS-Lookup deaktivieren — verhindert 3-5min Login-Verzögerung
# Ubuntu 24.04: ssh.service; ältere: sshd.service
if ! grep -q "^UseDNS no" /etc/ssh/sshd_config; then
  echo "UseDNS no" >> /etc/ssh/sshd_config
  if systemctl is-active --quiet ssh.service 2>/dev/null; then
    systemctl reload ssh.service
  elif systemctl is-active --quiet sshd.service 2>/dev/null; then
    systemctl reload sshd.service
  else
    warn "SSH-Dienst nicht gefunden — UseDNS gesetzt, aber kein reload möglich"
  fi
  log "SSH UseDNS no gesetzt — Login-Verzögerung durch Reverse-DNS behoben"
fi

# ─────────────────────────────────────────────────────────────
# SCHRITT 3 — SYSTEM + TOOLS + DOCKER + UNATTENDED-UPGRADES
# ─────────────────────────────────────────────────────────────
info "Schritt 3/8 — System + Docker + Auto-Updates installieren..."

apt_update
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl git unzip jq gpg ca-certificates gnupg \
  lsb-release apt-transport-https software-properties-common \
  rclone unattended-upgrades update-notifier-common cron sqlite3

systemctl enable cron && systemctl start cron
log "cron installiert und aktiviert"

if command -v docker &>/dev/null; then warn "Docker bereits installiert"
else
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker && systemctl start docker
  log "Docker installiert"
fi

usermod -aG docker alex
log "User 'alex' zur docker-Gruppe hinzugefügt"

if ! command -v node &>/dev/null; then
  info "Node.js LTS installieren..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs
  log "Node.js $(node --version) installiert"
else
  warn "Node.js bereits installiert ($(node --version))"
fi

cat > /etc/apt/apt.conf.d/51ugly-upgrades << 'UPGRADES'
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

# ── Mail-Script für unattended-upgrades ───────────────────────────────
curl -fsSL "https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/scripts/ugly-upgrades-mail.sh" \
  -o /usr/local/bin/ugly-upgrades-mail.sh
chmod +x /usr/local/bin/ugly-upgrades-mail.sh

mkdir -p /etc/systemd/system/apt-daily-upgrade.service.d
cat > /etc/systemd/system/apt-daily-upgrade.service.d/ugly-mail.conf << 'DROPIN'
[Service]
ExecStartPost=/usr/local/bin/ugly-upgrades-mail.sh
DROPIN

systemctl daemon-reload
systemctl enable unattended-upgrades
systemctl restart unattended-upgrades
log "unattended-upgrades konfiguriert (03:00 UTC, Reboot 03:30, Mail-Hook aktiv)"
log "System bereit"

# ─────────────────────────────────────────────────────────────
# SCHRITT 4 — REPO CLONEN ODER AKTUALISIEREN + .env ENTSCHLÜSSELN
# ─────────────────────────────────────────────────────────────
info "Schritt 4/8 — Repository clonen oder aktualisieren..."

# Clone-or-Pull: bestehendes Repo wird per git pull --rebase aktualisiert.
# Das bewahrt vom forge-Bootstrap geschriebene docker-compose.override.yml
# (in .gitignore) — sie überlebt den Re-Run unverändert.
if [ -d "$STACK_DIR/.git" ] && git -C "$STACK_DIR" remote get-url origin 2>/dev/null | grep -q "uglyatbeautymolt/VPS_Bootstrap"; then
  info "Repository vorhanden — aktualisiere via git pull --rebase..."
  git -C "$STACK_DIR" pull --rebase --autostash origin main \
    || fail "git pull --rebase fehlgeschlagen — Repository-Zustand prüfen"
  log "Repository aktualisiert"
else
  if [ -d "$STACK_DIR" ]; then
    warn "$STACK_DIR existiert (kein VPS_Bootstrap Repo) — wird gesichert"
    mv "$STACK_DIR" "${STACK_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
  fi
  git clone "$REPO_URL" "$STACK_DIR"
  log "Repository geklont"
fi
cd "$STACK_DIR"
[ ! -f ".env.gpg" ] && fail ".env.gpg nicht im Repository gefunden"

gpg --batch --yes --passphrase "$BACKUP_GPG_PASSWORD" --decrypt .env.gpg > .env

if ! grep -q "^BACKUP_GPG_PASSWORD=" "$STACK_DIR/.env"; then
  echo "BACKUP_GPG_PASSWORD=${BACKUP_GPG_PASSWORD}" >> "$STACK_DIR/.env"
else
  sed -i "s|^BACKUP_GPG_PASSWORD=.*|BACKUP_GPG_PASSWORD=${BACKUP_GPG_PASSWORD}|" "$STACK_DIR/.env"
fi
log ".env entschlüsselt"

chmod +x "$STACK_DIR/bootstrap.sh" "$STACK_DIR/set-secret.sh"
chmod +x "$STACK_DIR/backup/backup-master.sh"
chmod +x "$STACK_DIR/backup/modules/"*.sh
chmod +x "$STACK_DIR/backup/restore/restore-master.sh"
chmod +x "$STACK_DIR/backup/restore/modules/"*.sh
[ -d "$STACK_DIR/scripts" ] && chmod +x "$STACK_DIR/scripts/"*.sh

cp "$STACK_DIR/scripts/ugly-upgrades-mail.sh" /usr/local/bin/ugly-upgrades-mail.sh
chmod +x /usr/local/bin/ugly-upgrades-mail.sh
log "Scripts ausführbar + ugly-upgrades-mail.sh aus Repo installiert"

mkdir -p "$STACK_DIR"/{openclaw-data,n8n-data,searxng-data,www,hermes-data}

grep -q "roundcube-data/"             "$STACK_DIR/.gitignore" || echo "roundcube-data/"             >> "$STACK_DIR/.gitignore"
grep -q "backup/www-sync.sh"          "$STACK_DIR/.gitignore" || echo "backup/www-sync.sh"          >> "$STACK_DIR/.gitignore"
grep -q "backup/.www-checksum"        "$STACK_DIR/.gitignore" || echo "backup/.www-checksum"        >> "$STACK_DIR/.gitignore"
grep -q "docker-compose.override.yml" "$STACK_DIR/.gitignore" || echo "docker-compose.override.yml" >> "$STACK_DIR/.gitignore"
log ".gitignore aktualisiert"

cat > /etc/sudoers.d/alex-ugly-stack << SUDOERS
Defaults:alex timestamp_timeout=60
alex ALL=(root) NOPASSWD: /bin/tar -czf * -C ${STACK_DIR}/openclaw-data .
alex ALL=(root) NOPASSWD: /bin/ls * ${STACK_DIR}/openclaw-data
alex ALL=(root) NOPASSWD: /bin/cat ${STACK_DIR}/openclaw-data/*
alex ALL=(root) NOPASSWD: /usr/bin/find ${STACK_DIR}/openclaw-data *
alex ALL=(root) NOPASSWD: /usr/bin/grep -r * ${STACK_DIR}/openclaw-data/
SUDOERS
chmod 440 /etc/sudoers.d/alex-ugly-stack
log "sudoers konfiguriert"

source "$STACK_DIR/.env" 2>/dev/null || true

if [ ! -f "$STACK_DIR/openclaw-data/openclaw.json" ]; then
  cat > "$STACK_DIR/openclaw-data/openclaw.json" << CLAWCONFIG
{
  "gateway": {
    "mode": "local",
    "bind": "custom",
    "customBindHost": "0.0.0.0",
    "auth": { "mode": "token", "token": "${OPENCLAW_GATEWAY_TOKEN}" },
    "trustedProxies": ["10.0.0.0/8", "172.16.0.0/12"],
    "controlUi": {
      "allowedOrigins": ["https://claw.beautymolt.com","https://claw.beautymolt.com/"],
      "allowInsecureAuth": true,
      "dangerouslyAllowHostHeaderOriginFallback": true,
      "dangerouslyDisableDeviceAuth": true
    }
  }
}
CLAWCONFIG
  log "openclaw.json erstellt"
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

mkdir -p "$STACK_DIR/tts-data/voices"
THORSTEN="$STACK_DIR/tts-data/voices/de_DE-thorsten-medium.onnx"
if [ ! -f "$THORSTEN" ]; then
  info "Thorsten TTS-Stimme herunterladen (~61MB)..."
  BASE="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/de/de_DE/thorsten/medium"
  curl -fsSL "$BASE/de_DE-thorsten-medium.onnx"      -o "$THORSTEN"
  curl -fsSL "$BASE/de_DE-thorsten-medium.onnx.json" -o "${THORSTEN}.json"
  log "Thorsten TTS-Stimme heruntergeladen"
else
  log "Thorsten TTS-Stimme bereits vorhanden"
fi

chown -R alex:alex "$STACK_DIR"
fix_volume_ownership "$STACK_DIR/openclaw-data"
fix_volume_ownership "$STACK_DIR/n8n-data"

sudo -u alex git -C "$STACK_DIR" remote set-url origin \
  "https://${GITHUB_TOKEN}@github.com/uglyatbeautymolt/VPS_Bootstrap.git"
sudo -u alex git -C "$STACK_DIR" config user.name "Ugly"
sudo -u alex git -C "$STACK_DIR" config user.email "ugly@beautymolt.com"
sudo -u alex git -C "$STACK_DIR" config core.fileMode false
unset GITHUB_TOKEN
log "Git Remote konfiguriert (fileMode false — chmod ignoriert)"
log "Repository geclont und konfiguriert"

# ─────────────────────────────────────────────────────────────
# SCHRITT 5 — BACKUP VON R2 WIEDERHERSTELLEN
# ─────────────────────────────────────────────────────────────
info "Schritt 5/8 — Backup von R2 wiederherstellen..."
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
  gpg --batch --yes --passphrase "$BACKUP_GPG_PASSWORD" --decrypt "/tmp/$LATEST" \
    | tar -xz -C "$STAGING/"
  rm -f "/tmp/$LATEST"

  mkdir -p "$STACK_DIR/n8n-data"
  [ -f "$STAGING/n8n-data/workflows-backup.json" ] && \
    cp "$STAGING/n8n-data/workflows-backup.json" "$STACK_DIR/n8n-data/"
  [ -f "$STAGING/n8n-data/credentials-backup.json" ] && \
    cp "$STAGING/n8n-data/credentials-backup.json" "$STACK_DIR/n8n-data/"
  fix_volume_ownership "$STACK_DIR/n8n-data"

  if ls "$STAGING/openclaw-data/"*.tar.gz &>/dev/null; then
    mkdir -p "$STACK_DIR/openclaw-data"
    tar -xzf "$STAGING/openclaw-data/"*.tar.gz -C "$STACK_DIR/openclaw-data/"
    fix_volume_ownership "$STACK_DIR/openclaw-data"
    BACKUP_RESTORED=true
    log "OpenClaw Backup wiederhergestellt"
  fi

  mkdir -p "$STACK_DIR/nginx/conf.d"
  [ -d "$STAGING/nginx/conf.d" ] && cp -r "$STAGING/nginx/conf.d/." "$STACK_DIR/nginx/conf.d/"
  mkdir -p "$STACK_DIR/www"
  [ -d "$STAGING/www" ] && cp -r "$STAGING/www/." "$STACK_DIR/www/"
  rm -rf "$STAGING"
  log "Backup wiederhergestellt aus: $LATEST"
else
  warn "Kein Backup gefunden — frischer Start"
fi

# ── nginx Block für hermes.beautymolt.com (idempotent) ───────────────────────
# Wird nach Backup-Restore hinzugefügt — so bleibt das Backup-Conf erhalten
# und der Block wird nur ergänzt wenn er noch fehlt.
mkdir -p "$STACK_DIR/nginx/conf.d"
NGINX_CONF="$STACK_DIR/nginx/conf.d/default.conf"
if ! grep -q "hermes.beautymolt.com" "$NGINX_CONF" 2>/dev/null; then
  cat >> "$NGINX_CONF" << 'NGINX_HERMES'

server {
    listen 80;
    server_name hermes.beautymolt.com;
    location / {
        set $upstream http://hermes:8443;
        proxy_pass $upstream;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGINX_HERMES
  log "nginx: hermes.beautymolt.com Block hinzugefügt"
else
  log "nginx: hermes.beautymolt.com bereits vorhanden"
fi

# ── hermes config.yaml (idempotent) ──────────────────────────────────────────
# Minimal-Config damit hermes gateway run ohne interaktiven Setup-Wizard läuft.
# provider: "auto" erkennt OPENROUTER_API_KEY automatisch aus den Docker Env-Vars.
# Nicht überschreiben wenn vorhanden (z.B. nach Backup-Restore mit gespeicherter Config).
if [ ! -f "$STACK_DIR/hermes-data/config.yaml" ]; then
  mkdir -p "$STACK_DIR/hermes-data"
  cat > "$STACK_DIR/hermes-data/config.yaml" << 'HERMES_CONFIG'
model:
  provider: "auto"
  base_url: "https://openrouter.ai/api/v1"

terminal:
  backend: "local"
  cwd: "."
  timeout: 180

agent:
  max_turns: 60
HERMES_CONFIG
  log "hermes: config.yaml erstellt (~/.hermes/config.yaml im Container)"
else
  log "hermes: config.yaml bereits vorhanden"
fi

info "openclaw.json prüfen..."
if [ -f "$STACK_DIR/openclaw-data/openclaw.json" ]; then
  python3 << PYFIX
import json, sys
path = "$STACK_DIR/openclaw-data/openclaw.json"
try:
    cfg = json.load(open(path))
except Exception as e:
    print(f"Lesefehler: {e}"); sys.exit(1)
changed = False
gw = cfg.setdefault("gateway", {})
if gw.get("bind") != "custom" or gw.get("customBindHost") != "0.0.0.0":
    gw["bind"] = "custom"; gw["customBindHost"] = "0.0.0.0"; changed = True; print("  Fix: bind → custom + customBindHost 0.0.0.0")
if not cfg.get("hooks",{}).get("enabled"):
    hook_token = ""
    try:
        for line in open("$STACK_DIR/.env"):
            if line.startswith("OPENCLAW_HOOK_TOKEN="): hook_token = line.strip().split("=",1)[1]
    except: pass
    cfg["hooks"] = {"enabled": True, "token": hook_token or "UglyHook2026!beautymolt", "path": "/hooks"}
    changed = True; print("  Fix: hooks Block hinzugefügt")
# BREVO_KEY in env-Sektion sicherstellen
# Der eingebaute Brevo-Skill liest den Key aus openclaw.json env — nicht aus Docker-Env-Vars
brevo_key = ""
try:
    for line in open("$STACK_DIR/.env"):
        if line.startswith("BREVO_KEY="): brevo_key = line.strip().split("=",1)[1]
except: pass
if brevo_key:
    cfg.setdefault("env", {})
    if cfg["env"].get("BREVO_KEY") != brevo_key:
        cfg["env"]["BREVO_KEY"] = brevo_key
        changed = True; print("  Fix: BREVO_KEY in env-Sektion gesetzt")
# main-Agent in agents.list sicherstellen (ab openclaw 2026.4.15 pflicht)
agent_list = cfg.setdefault("agents", {}).setdefault("list", [])
if not any(a.get("id") == "main" for a in agent_list):
    agent_list.insert(0, {"id": "main"})
    changed = True; print("  Fix: main-Agent in agents.list eingefügt")
if changed:
    json.dump(cfg, open(path,"w"), indent=2); print("  openclaw.json aktualisiert")
else:
    print("  openclaw.json korrekt")
PYFIX
  chown 1000:$(id -g alex) "$STACK_DIR/openclaw-data/openclaw.json"
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
    log "OpenClaw Token → .env synchronisiert"
  fi
fi

# ─────────────────────────────────────────────────────────────
# SCHRITT 6 — STACK STARTEN
# ─────────────────────────────────────────────────────────────
info "Schritt 6/8 — Stack starten..."
cd "$STACK_DIR"

docker compose pull --ignore-pull-failures
docker compose up -d
sleep 30
docker compose ps

# sqlite3 im OpenClaw Container installieren
# Das offizielle ghcr.io/openclaw/openclaw Image (node:24-bookworm) enthält kein sqlite3.
# Die Agenten brauchen es um "exec: sqlite3 ..." Befehle auszuführen.
# Idempotent: wird nur installiert wenn nicht vorhanden.
info "sqlite3 im OpenClaw Container prüfen..."
if docker exec -u 0 openclaw sh -c "command -v sqlite3" > /dev/null 2>&1; then
  log "sqlite3 bereits im openclaw Container vorhanden"
else
  info "sqlite3 fehlt — installiere im openclaw Container..."
  docker exec -u 0 openclaw bash -c "apt-get update -qq && apt-get install -y -qq sqlite3"
  log "sqlite3 im openclaw Container installiert"
fi

fix_volume_ownership "$STACK_DIR/openclaw-data"
fix_volume_ownership "$STACK_DIR/n8n-data"
log "Volume-Ownership gesetzt (1000:alex, g+rX)"

source "$STACK_DIR/.env"
[ -z "$PORTAINER_ADMIN_PASSWORD" ] && fail "PORTAINER_ADMIN_PASSWORD fehlt in .env"

info "Portainer Admin-Passwort setzen..."
PORTAINER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' portainer 2>/dev/null || echo "")
if [ -n "$PORTAINER_IP" ]; then
  for i in $(seq 1 24); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      "http://${PORTAINER_IP}:9000/api/system/status" 2>/dev/null || echo "000")
    [ "$HTTP_CODE" = "200" ] && log "Portainer API bereit" && break
    warn "Portainer noch nicht bereit — warte 5s ($i/24)"; sleep 5
  done
  PORTAINER_JSON=$(jq -n --arg user "admin" --arg pass "$PORTAINER_ADMIN_PASSWORD" \
    '{"Username":$user,"Password":$pass}')
  INIT_RESPONSE=$(curl -s -X POST "http://${PORTAINER_IP}:9000/api/users/admin/init" \
    -H "Content-Type: application/json" -d "$PORTAINER_JSON")
  if   echo "$INIT_RESPONSE" | grep -q "Id";             then log "Portainer Admin eingerichtet"
  elif echo "$INIT_RESPONSE" | grep -q "already exists"; then warn "Portainer Admin existiert bereits"
  else warn "Portainer Init: $INIT_RESPONSE"; fi
else
  warn "Portainer IP nicht gefunden"
fi

# ── n8n Workflows importieren + via REST API aktivieren ──────────────
if [ -f "$STACK_DIR/n8n-data/workflows-backup.json" ]; then
  info "n8n Workflows importieren..."

  # Auf healthz warten
  for i in $(seq 1 24); do
    docker exec n8n wget -q --spider http://localhost:5678/healthz 2>/dev/null && log "n8n bereit" && break
    warn "n8n noch nicht bereit ($i/24)"; sleep 5
  done

  # Import via CLI
  docker cp "$STACK_DIR/n8n-data/workflows-backup.json"   n8n:/tmp/workflows-backup.json
  docker cp "$STACK_DIR/n8n-data/credentials-backup.json" n8n:/tmp/credentials-backup.json
  docker exec n8n n8n import:workflow    --input=/tmp/workflows-backup.json
  docker exec n8n n8n import:credentials --input=/tmp/credentials-backup.json
  rm -f "$STACK_DIR/n8n-data/workflows-backup.json" "$STACK_DIR/n8n-data/credentials-backup.json"
  log "n8n Workflows und Credentials importiert"

  # ── API Key direkt in SQLite eintragen ──
  # CLI-Aktivierung registriert Webhooks nicht korrekt — REST API ist zwingend.
  # API Keys können nicht per Env-Var gesetzt werden → direkt in DB schreiben.
  N8N_DB="$STACK_DIR/n8n-data/database.sqlite"
  N8N_API_KEY="$(openssl rand -hex 32)"
  N8N_KEY_ID="$(cat /proc/sys/kernel/random/uuid)"
  N8N_USER_ID=$(sqlite3 "$N8N_DB" "SELECT id FROM user LIMIT 1;")

  if [ -n "$N8N_USER_ID" ]; then
    sqlite3 "$N8N_DB" "
      INSERT OR REPLACE INTO user_api_keys (id, userId, label, apiKey, scopes, audience)
      VALUES (
        '${N8N_KEY_ID}',
        '${N8N_USER_ID}',
        'bootstrap',
        '${N8N_API_KEY}',
        NULL,
        'public-api'
      );
    "
    log "n8n API Key in DB eingetragen (userId: ${N8N_USER_ID})"
  else
    warn "n8n User nicht gefunden — Workflow-Aktivierung via REST API übersprungen"
    N8N_API_KEY=""
  fi

  # n8n neu starten damit der API Key geladen wird
  if [ -n "$N8N_API_KEY" ]; then
    info "n8n neu starten (API Key laden)..."
    docker restart n8n
    for i in $(seq 1 24); do
      docker exec n8n wget -q --spider http://localhost:5678/healthz 2>/dev/null && log "n8n wieder bereit" && break
      warn "n8n startet ($i/24)"; sleep 5
    done

    # n8n Container-IP ermitteln (Aufruf von ausserhalb des ugly-net Netzwerks)
    N8N_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' n8n 2>/dev/null || echo "")

    if [ -n "$N8N_IP" ]; then
      info "n8n Workflows via REST API aktivieren..."
      # Alle Workflow-IDs holen
      WF_IDS=$(curl -s \
        -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
        "http://${N8N_IP}:5678/api/v1/workflows?limit=250" \
        | jq -r '.data[].id' 2>/dev/null || echo "")

      if [ -n "$WF_IDS" ]; then
        ACTIVATED=0
        FAILED=0
        for WF_ID in $WF_IDS; do
          HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            -H "X-N8N-API-KEY: ${N8N_API_KEY}" \
            "http://${N8N_IP}:5678/api/v1/workflows/${WF_ID}/activate")
          if [ "$HTTP_CODE" = "200" ]; then
            ACTIVATED=$((ACTIVATED + 1))
          else
            FAILED=$((FAILED + 1))
            warn "Workflow ${WF_ID}: Aktivierung fehlgeschlagen (HTTP ${HTTP_CODE})"
          fi
        done
        log "n8n Workflows aktiviert: ${ACTIVATED} OK, ${FAILED} fehlgeschlagen"
      else
        warn "Keine Workflow-IDs gefunden — REST API Antwort prüfen"
      fi
    else
      warn "n8n Container-IP nicht ermittelbar — Workflows manuell aktivieren"
    fi

    # Temporären Bootstrap-API-Key wieder löschen
    sqlite3 "$N8N_DB" "DELETE FROM user_api_keys WHERE label = 'bootstrap';"
    log "Bootstrap API Key aus DB entfernt"
  fi
fi

if [ -f "$STACK_DIR/searxng-data/settings.yml" ]; then
  if ! grep -q "^\s*- json" "$STACK_DIR/searxng-data/settings.yml"; then
    sed -i 's/^\s*- html$/  - html\n  - json/' "$STACK_DIR/searxng-data/settings.yml"
    docker restart searxng 2>/dev/null || true
    log "SearXNG JSON API aktiviert"
  fi
fi

# ─────────────────────────────────────────────────────────────
# SCHRITT 7 — CRON + FIREWALL
# ─────────────────────────────────────────────────────────────
info "Schritt 7/8 — Cron + Firewall..."

cat > /etc/cron.d/ugly-backup << 'CRONFILE'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 2 * * * alex bash /home/alex/ugly-stack/backup/backup-master.sh >> /home/alex/ugly-stack/backup/backup.log 2>&1
CRONFILE
chmod 644 /etc/cron.d/ugly-backup
log "Backup-Cron eingerichtet (/etc/cron.d/ugly-backup, 02:00 UTC, User: alex)"

cat > /etc/cron.d/claude-update << 'CRONFILE'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
30 4 * * * root npm install -g @anthropic-ai/claude-code@latest >> /var/log/claude-update.log 2>&1
CRONFILE
chmod 644 /etc/cron.d/claude-update
log "Claude-Update-Cron eingerichtet (/etc/cron.d/claude-update, 04:30 UTC, User: root)"

# Gemini CLI täglich updaten (Abo-Modus via OAuth — kein API Key)
cat > /etc/cron.d/gemini-update << 'CRONFILE'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
45 4 * * * root npm install -g @google/gemini-cli@latest >> /var/log/gemini-update.log 2>&1
CRONFILE
chmod 644 /etc/cron.d/gemini-update
log "Gemini-Update-Cron eingerichtet (/etc/cron.d/gemini-update, 04:45 UTC, User: root)"

ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw --force enable
log "Firewall konfiguriert"

# ─────────────────────────────────────────────────────────────
# SCHRITT 8 — CLAUDE CODE CLI + GEMINI CLI
# ─────────────────────────────────────────────────────────────
info "Schritt 8/8 — Claude Code CLI + Gemini CLI installieren..."

CLAUDE_INSTALL_OK=false
if npm install -g @anthropic-ai/claude-code@latest >/dev/null 2>&1; then
  CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1 || echo "unbekannt")
  log "Claude Code installiert: $CLAUDE_VERSION"
  CLAUDE_INSTALL_OK=true
else
  warn "Claude Code Installation fehlgeschlagen — manuell: npm install -g @anthropic-ai/claude-code"
fi

# Abo-Modus: kein ANTHROPIC_API_KEY — Auth via OAuth (claude login)
# Alten Key bereinigen falls aus früherer Installation vorhanden (idempotent)
if grep -q "ANTHROPIC_API_KEY" /etc/environment 2>/dev/null; then
  sed -i '/^ANTHROPIC_API_KEY=/d' /etc/environment
  log "ANTHROPIC_API_KEY aus /etc/environment entfernt (Abo-Modus)"
fi
if grep -q "ANTHROPIC_API_KEY" /home/alex/.bashrc 2>/dev/null; then
  sed -i '/ANTHROPIC_API_KEY/d' /home/alex/.bashrc
  log "ANTHROPIC_API_KEY aus .bashrc entfernt (Abo-Modus)"
fi
log "Claude Code läuft im Abo-Modus — Auth nach Bootstrap: su - alex && claude login"

# Alias: claude immer mit --dangerously-skip-permissions aufrufen
# CLAUDE.md im Projektverzeichnis enthält strikte Verhaltensregeln — der Flag ist sicher
if grep -q "alias claude=" /home/alex/.bashrc 2>/dev/null; then
  sed -i "s|alias claude=.*|alias claude='claude --dangerously-skip-permissions'|" /home/alex/.bashrc
else
  echo "alias claude='claude --dangerously-skip-permissions'" >> /home/alex/.bashrc
fi
log "claude alias gesetzt (--dangerously-skip-permissions)"

# ── Gemini CLI ────────────────────────────────────────────────────────────────
# Abo-Modus: Google AI Pro/Ultra — Auth via OAuth (gemini auth login)
# Kein GEMINI_API_KEY nötig; Credentials werden in ~/.gemini/ gecacht.
GEMINI_INSTALL_OK=false
if npm install -g @google/gemini-cli@latest >/dev/null 2>&1; then
  GEMINI_VERSION=$(gemini --version 2>/dev/null | head -1 || echo "unbekannt")
  log "Gemini CLI installiert: $GEMINI_VERSION"
  GEMINI_INSTALL_OK=true
else
  warn "Gemini CLI Installation fehlgeschlagen — manuell: npm install -g @google/gemini-cli"
fi

# Alten API Key bereinigen falls vorhanden (idempotent)
if grep -q "GEMINI_API_KEY" /etc/environment 2>/dev/null; then
  sed -i '/^GEMINI_API_KEY=/d' /etc/environment
  log "GEMINI_API_KEY aus /etc/environment entfernt (Abo-Modus)"
fi
if grep -q "GEMINI_API_KEY" /home/alex/.bashrc 2>/dev/null; then
  sed -i '/GEMINI_API_KEY/d' /home/alex/.bashrc
  log "GEMINI_API_KEY aus .bashrc entfernt (Abo-Modus)"
fi
log "Gemini CLI läuft im Abo-Modus — Auth nach Bootstrap: su - alex && gemini auth login"

# ─────────────────────────────────────────────────────────────
# ABSCHLUSS-KONTROLLE — IP, DNS, CF Tunnel, Zeitpläne
# ─────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║ Abschluss-Kontrolle                      ║"
echo "╚══════════════════════════════════════════╝"
echo ""

info "VPS-IP und Hoster ermitteln..."
IPINFO=$(curl -s --max-time 5 "https://ipinfo.io/json" 2>/dev/null || echo "{}")
VPS_IP=$(echo "$IPINFO"      | jq -r '.ip       // "unbekannt"')
VPS_HOSTER=$(echo "$IPINFO"  | jq -r '.org      // "unbekannt"')
VPS_HOSTNAME=$(echo "$IPINFO"| jq -r '.hostname // "unbekannt"')
VPS_CITY=$(echo "$IPINFO"    | jq -r '.city     // ""')
VPS_COUNTRY=$(echo "$IPINFO" | jq -r '.country  // ""')

echo -e "  ${GREEN}[✓]${NC} VPS-IP:      $VPS_IP"
echo -e "  ${GREEN}[✓]${NC} Hoster:      $VPS_HOSTER"
echo -e "  ${GREEN}[✓]${NC} Hostname:    $VPS_HOSTNAME"
echo -e "  ${GREEN}[✓]${NC} Standort:    $VPS_CITY, $VPS_COUNTRY"
echo ""

source "$STACK_DIR/.env"
DNS_STATUS="nicht konfiguriert (CF_TOKEN oder CF_ZONE_ID fehlen)"

if [ -n "$CF_TOKEN" ] && [ -n "$CF_ZONE_ID" ] && [ "$VPS_IP" != "unbekannt" ]; then
  info "Cloudflare DNS — ssh.beautymolt.com → $VPS_IP ..."

  EXISTING=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=A&name=ssh.beautymolt.com" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json")

  RECORD_ID=$(echo "$EXISTING" | jq -r '.result[0].id // ""')
  RECORD_IP=$(echo "$EXISTING" | jq -r '.result[0].content // ""')

  if [ -n "$RECORD_ID" ]; then
    if [ "$RECORD_IP" = "$VPS_IP" ]; then
      log "DNS ssh.beautymolt.com bereits auf $VPS_IP — kein Update nötig"
      DNS_STATUS="bereits korrekt ($VPS_IP)"
    else
      UPDATE=$(curl -s -X PUT \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"ssh\",\"content\":\"${VPS_IP}\",\"ttl\":60,\"proxied\":false}")
      if echo "$UPDATE" | jq -e '.success' | grep -q true; then
        log "DNS ssh.beautymolt.com: $RECORD_IP → $VPS_IP (aktualisiert)"
        DNS_STATUS="aktualisiert: $RECORD_IP → $VPS_IP"
      else
        warn "DNS Update fehlgeschlagen: $(echo "$UPDATE" | jq -r '.errors[0].message // "unbekannt"')"
        DNS_STATUS="Update FEHLGESCHLAGEN — manuell setzen"
      fi
    fi
  else
    CREATE=$(curl -s -X POST \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"ssh\",\"content\":\"${VPS_IP}\",\"ttl\":60,\"proxied\":false}")
    if echo "$CREATE" | jq -e '.success' | grep -q true; then
      log "DNS ssh.beautymolt.com: neu erstellt → $VPS_IP (Proxy: off)"
      DNS_STATUS="neu erstellt → $VPS_IP"
    else
      warn "DNS Erstellen fehlgeschlagen: $(echo "$CREATE" | jq -r '.errors[0].message // "unbekannt"')"
      DNS_STATUS="Erstellen FEHLGESCHLAGEN — manuell setzen"
    fi
  fi

  echo -e "  ${GREEN}[✓]${NC} ssh.beautymolt.com → $VPS_IP  [Cloudflare DNS, Proxy: off]"
else
  echo -e "  ${YELLOW}[!]${NC} DNS-Update übersprungen — CF_TOKEN oder CF_ZONE_ID fehlen in .env"
fi
echo ""

# ── Cloudflare Tunnel Ingress sicherstellen ──────────────────────────────────
# Idempotent: GET → prüfen ob Eintrag existiert → nur bei Fehlen: PUT
# Benötigt: CF_TOKEN, CF_ACCOUNT_ID, CF_TUNNEL_ID in .env
ensure_cf_tunnel_ingress() {
  local hostname="$1"
  local service="$2"

  if [ -z "$CF_TOKEN" ] || [ -z "$CF_ACCOUNT_ID" ] || [ -z "$CF_TUNNEL_ID" ]; then
    warn "CF Tunnel: CF_TOKEN / CF_ACCOUNT_ID / CF_TUNNEL_ID fehlen — $hostname übersprungen"
    return
  fi

  local tunnel_config
  tunnel_config=$(curl -s \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" \
    -H "Authorization: Bearer ${CF_TOKEN}")

  if ! echo "$tunnel_config" | jq -e '.success' | grep -q true; then
    local err; err=$(echo "$tunnel_config" | jq -r '.errors[0].message // "Antwort ungültig"' 2>/dev/null || echo "curl-Fehler")
    warn "CF Tunnel GET fehlgeschlagen ($hostname): $err"
    return
  fi

  if echo "$tunnel_config" | jq -e --arg h "$hostname" '.result.config.ingress[] | select(.hostname == $h)' > /dev/null 2>&1; then
    log "CF Tunnel: $hostname bereits vorhanden — kein Update"
    return
  fi

  local new_config
  new_config=$(echo "$tunnel_config" | jq --arg h "$hostname" --arg s "$service" '
    .result.config.ingress = (
      [.result.config.ingress[] | select(.hostname != null and .service != "http_status:404")] +
      [{"hostname": $h, "service": $s}] +
      [{"service": "http_status:404"}]
    )
    | {config: (
        {ingress: .result.config.ingress} +
        if .result.config["warp-routing"] != null
        then {"warp-routing": .result.config["warp-routing"]}
        else {}
        end
      )}
  ')

  local put_result
  put_result=$(curl -s -X PUT \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" \
    -H "Authorization: Bearer ${CF_TOKEN}" -H "Content-Type: application/json" \
    --data "$new_config")

  if echo "$put_result" | jq -e '.success' | grep -q true; then
    log "CF Tunnel: $hostname → $service hinzugefügt"
  else
    local cf_err; cf_err=$(echo "$put_result" | jq -r '.errors[0].message // "unbekannt"')
    warn "CF Tunnel Update fehlgeschlagen ($hostname): $cf_err"
  fi
}

info "Cloudflare Tunnel Ingress prüfen..."

# Hermes — aktiv
ensure_cf_tunnel_ingress "hermes.beautymolt.com" "http://nginx:80"

# Weitere Container — in den nächsten Tagen aktivieren:
# (Zeile auskommentieren + Bootstrap erneut ausführen)
# ensure_cf_tunnel_ingress "claw.beautymolt.com"      "http://nginx:80"
# ensure_cf_tunnel_ingress "search.beautymolt.com"    "http://nginx:80"
# ensure_cf_tunnel_ingress "n8n.beautymolt.com"       "http://nginx:80"
# ensure_cf_tunnel_ingress "mail.beautymolt.com"      "http://nginx:80"
# ensure_cf_tunnel_ingress "portainer.beautymolt.com" "http://nginx:80"
echo ""

echo "  Zeitpläne (UTC):"
echo ""

SCHED_BACKUP_OK=false
CRON_DAEMON=$(systemctl is-active cron 2>/dev/null || echo "unknown")
CRON_ENTRY=$(grep "backup-master.sh" /etc/cron.d/ugly-backup 2>/dev/null || echo "")
if [ "$CRON_DAEMON" = "active" ] && [ -n "$CRON_ENTRY" ]; then
  echo -e "  ${GREEN}[✓]${NC} 02:00  Backup + .env sync + Mail     [cron]"
  SCHED_BACKUP_OK=true
else
  echo -e "  ${RED}[✗]${NC} 02:00  Backup + .env sync + Mail     [cron] — PROBLEM"
  [ "$CRON_DAEMON" != "active" ] && echo "         cron-Daemon: $CRON_DAEMON"
  [ -z "$CRON_ENTRY" ]           && echo "         /etc/cron.d/ugly-backup fehlt"
fi
echo ""

SCHED_CLAUDE_OK=false
CLAUDE_CRON_ENTRY=$(grep "claude-code" /etc/cron.d/claude-update 2>/dev/null || echo "")
if [ "$CRON_DAEMON" = "active" ] && [ -n "$CLAUDE_CRON_ENTRY" ]; then
  echo -e "  ${GREEN}[✓]${NC} 04:30  Claude Code Update             [cron]"
  SCHED_CLAUDE_OK=true
else
  echo -e "  ${RED}[✗]${NC} 04:30  Claude Code Update             [cron] — PROBLEM"
  [ -z "$CLAUDE_CRON_ENTRY" ] && echo "         /etc/cron.d/claude-update fehlt"
fi
echo ""

SCHED_GEMINI_OK=false
GEMINI_CRON_ENTRY=$(grep "gemini-cli" /etc/cron.d/gemini-update 2>/dev/null || echo "")
if [ "$CRON_DAEMON" = "active" ] && [ -n "$GEMINI_CRON_ENTRY" ]; then
  echo -e "  ${GREEN}[✓]${NC} 04:45  Gemini CLI Update              [cron]"
  SCHED_GEMINI_OK=true
else
  echo -e "  ${RED}[✗]${NC} 04:45  Gemini CLI Update              [cron] — PROBLEM"
  [ -z "$GEMINI_CRON_ENTRY" ] && echo "         /etc/cron.d/gemini-update fehlt"
fi
echo ""

SCHED_WATCHTOWER_OK=false
WATCHTOWER_RUNNING=$(docker inspect -f '{{.State.Running}}' watchtower 2>/dev/null || echo "false")
WATCHTOWER_SCHEDULE=$(docker inspect watchtower 2>/dev/null \
  | jq -r '.[0].Config.Env[] | select(startswith("WATCHTOWER_SCHEDULE="))' \
  | cut -d= -f2 2>/dev/null || echo "")
if [ "$WATCHTOWER_RUNNING" = "true" ] && [ -n "$WATCHTOWER_SCHEDULE" ]; then
  echo -e "  ${GREEN}[✓]${NC} 02:30  Watchtower Container-Updates   [Watchtower intern]"
  echo    "         Schedule: $WATCHTOWER_SCHEDULE"
  SCHED_WATCHTOWER_OK=true
else
  echo -e "  ${RED}[✗]${NC} 02:30  Watchtower Container-Updates   [Watchtower intern] — PROBLEM"
  [ "$WATCHTOWER_RUNNING" != "true" ] && echo "         Container läuft nicht"
  [ -z "$WATCHTOWER_SCHEDULE" ]       && echo "         WATCHTOWER_SCHEDULE fehlt"
fi
echo ""

SCHED_UPGRADES_OK=false
TIMER_ACTIVE=$(systemctl is-active apt-daily-upgrade.timer 2>/dev/null || echo "unknown")
TIMER_NEXT=$(systemctl show apt-daily-upgrade.timer -p NextElapseUSecRealtime --value 2>/dev/null \
  | python3 -c "
import sys,datetime
val=sys.stdin.read().strip()
try: print(datetime.datetime.utcfromtimestamp(int(val)/1e6).strftime('%Y-%m-%d %H:%M UTC'))
except: print('unbekannt')
" 2>/dev/null || echo "unbekannt")
UA_SERVICE=$(systemctl is-active unattended-upgrades 2>/dev/null || echo "unknown")
MAIL_HOOK_OK=false
[ -x /usr/local/bin/ugly-upgrades-mail.sh ] \
  && grep -q "ugly-upgrades-mail" \
     /etc/systemd/system/apt-daily-upgrade.service.d/ugly-mail.conf 2>/dev/null \
  && MAIL_HOOK_OK=true

if [ "$TIMER_ACTIVE" = "active" ] && [ "$UA_SERVICE" = "active" ]; then
  echo -e "  ${GREEN}[✓]${NC} 03:00  unattended-upgrades            [systemd Timer]"
  echo    "         Timer: active | Nächster Lauf: $TIMER_NEXT"
  if $MAIL_HOOK_OK; then
    echo -e "  ${GREEN}[✓]${NC}        Mail-Hook nach Lauf            [ExecStartPost] aktiv"
  else
    echo -e "  ${RED}[✗]${NC}        Mail-Hook nach Lauf            [ExecStartPost] FEHLT"
  fi
  SCHED_UPGRADES_OK=true
else
  echo -e "  ${RED}[✗]${NC} 03:00  unattended-upgrades            [systemd Timer] — PROBLEM"
  [ "$TIMER_ACTIVE" != "active" ] && echo "         apt-daily-upgrade.timer: $TIMER_ACTIVE"
  [ "$UA_SERVICE"   != "active" ] && echo "         unattended-upgrades.service: $UA_SERVICE"
fi
echo ""

SCHED_REBOOT_OK=false
REBOOT_TIME=$(grep "Automatic-Reboot-Time" /etc/apt/apt.conf.d/51ugly-upgrades 2>/dev/null \
  | grep -o '"[^"]*"' | tr -d '"' || echo "")
REBOOT_ENABLED=$(grep "Automatic-Reboot " /etc/apt/apt.conf.d/51ugly-upgrades 2>/dev/null \
  | grep -o '"true"' || echo "")
if [ "$REBOOT_ENABLED" = '"true"' ] && [ -n "$REBOOT_TIME" ]; then
  echo -e "  ${GREEN}[✓]${NC} 03:30  Automatischer Reboot           [unattended-upgrades]"
  echo    "         Reboot-Time: $REBOOT_TIME (nur bei Kernel-Update)"
  SCHED_REBOOT_OK=true
else
  echo -e "  ${RED}[✗]${NC} 03:30  Automatischer Reboot           [unattended-upgrades] — PROBLEM"
  [ "$REBOOT_ENABLED" != '"true"' ] && echo "         Automatic-Reboot nicht true"
  [ -z "$REBOOT_TIME" ]             && echo "         Automatic-Reboot-Time fehlt"
fi
echo ""

# ─────────────────────────────────────────────────────────────
# INSTALLATIONS-MAIL VIA BREVO
# ─────────────────────────────────────────────────────────────
if [ -n "$BREVO_KEY" ]; then
  info "Installations-Mail senden..."

  [ "$BACKUP_RESTORED" = true ] \
    && RESTORE_LINE="Ja — $LATEST" \
    || RESTORE_LINE="Nein — frischer Start (Telegram Onboarding nötig)"

  $SCHED_BACKUP_OK \
    && LINE_BACKUP="[OK] 02:00  Backup + .env sync + Mail     [cron]" \
    || LINE_BACKUP="[!!] 02:00  Backup + .env sync + Mail     [cron] — PROBLEM"

  $SCHED_CLAUDE_OK \
    && LINE_CLAUDE="[OK] 04:30  Claude Code Update             [cron]" \
    || LINE_CLAUDE="[!!] 04:30  Claude Code Update             [cron] — PROBLEM"

  $SCHED_GEMINI_OK \
    && LINE_GEMINI="[OK] 04:45  Gemini CLI Update              [cron]" \
    || LINE_GEMINI="[!!] 04:45  Gemini CLI Update              [cron] — PROBLEM"

  $SCHED_WATCHTOWER_OK \
    && LINE_WATCHTOWER="[OK] 02:30  Watchtower Container-Updates   [Watchtower intern]\n         Schedule: $WATCHTOWER_SCHEDULE" \
    || LINE_WATCHTOWER="[!!] 02:30  Watchtower Container-Updates   [Watchtower intern] — PROBLEM"

  if $SCHED_UPGRADES_OK; then
    $MAIL_HOOK_OK && HOOK_NOTE="Mail-Hook: OK" || HOOK_NOTE="Mail-Hook: FEHLT"
    LINE_UPGRADES="[OK] 03:00  unattended-upgrades            [systemd Timer]\n         Nächster Lauf: $TIMER_NEXT | $HOOK_NOTE"
  else
    LINE_UPGRADES="[!!] 03:00  unattended-upgrades            [systemd Timer] — PROBLEM"
  fi

  $SCHED_REBOOT_OK \
    && LINE_REBOOT="[OK] 03:30  Automatischer Reboot           [unattended-upgrades]\n         Reboot-Time: $REBOOT_TIME" \
    || LINE_REBOOT="[!!] 03:30  Automatischer Reboot           [unattended-upgrades] — PROBLEM"

  CONTAINER_STATUS=$(docker compose -f "$STACK_DIR/docker-compose.yml" ps \
    --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || echo "Nicht verfügbar")

  MAIL_BODY="Ugly Stack — Installation abgeschlossen
$(TZ=Europe/Zurich date '+%Y-%m-%d %H:%M:%S %Z')
========================================

VPS
  IP:        $VPS_IP
  Hoster:    $VPS_HOSTER
  Hostname:  $VPS_HOSTNAME
  Standort:  $VPS_CITY, $VPS_COUNTRY

DNS
  ssh.beautymolt.com: $DNS_STATUS

Bootstrap
  Version:   $BOOTSTRAP_VERSION

Backup wiederhergestellt:
  $RESTORE_LINE

----------------------------------------
Zeitpläne (UTC):

  $(echo -e "$LINE_BACKUP")

  $(echo -e "$LINE_WATCHTOWER")

  $(echo -e "$LINE_UPGRADES")

  $(echo -e "$LINE_REBOOT")

  $(echo -e "$LINE_CLAUDE")

  $(echo -e "$LINE_GEMINI")

----------------------------------------
Container-Status:
$CONTAINER_STATUS

----------------------------------------
Services:
  ssh://ssh.beautymolt.com:22
  https://claw.beautymolt.com
  https://search.beautymolt.com
  https://n8n.beautymolt.com
  https://www.beautymolt.com
  https://portainer.beautymolt.com
  https://hermes.beautymolt.com

----------------------------------------
Claude Code:
  Modus: Abo (OAuth)
  Auth nach Bootstrap: su - alex && claude login

Gemini CLI:
  Modus: Abo (OAuth — Google AI Pro/Ultra)
  Auth nach Bootstrap: su - alex && gemini auth login"

  MAIL_PAYLOAD=$(jq -n \
    --arg subject "Ugly Stack installiert — $VPS_IP ($VPS_HOSTER)" \
    --arg body "$MAIL_BODY" \
    '{sender:{name:"Ugly Bootstrap",email:"ugly@beautymolt.com"},to:[{email:"alex@alexstuder.ch"}],subject:$subject,textContent:$body}')

  HTTP_CODE=$(curl -s -o /tmp/brevo_install_response.txt -w "%{http_code}" \
    -X POST "https://api.brevo.com/v3/smtp/email" \
    -H "api-key: ${BREVO_KEY}" \
    -H "Content-Type: application/json" \
    -d "$MAIL_PAYLOAD")

  [ "$HTTP_CODE" = "201" ] \
    && log "Installations-Mail gesendet → alex@alexstuder.ch" \
    || warn "Mail fehlgeschlagen (HTTP $HTTP_CODE): $(cat /tmp/brevo_install_response.txt)"
else
  warn "BREVO_KEY nicht in .env — keine Installations-Mail"
fi

# ─────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────────
banner

echo -e "  ${GREEN}Stack:${NC}  $STACK_DIR"
echo -e "  ${GREEN}User:${NC}   alex (sudo, docker)"
echo -e "  ${GREEN}VPS:${NC}    $VPS_IP — $VPS_HOSTER"
echo -e "  ${GREEN}SSH:${NC}    ssh://ssh.beautymolt.com"
echo ""
echo -e "  ${GREEN}Portainer:${NC} https://portainer.beautymolt.com"
echo ""
echo "  ── Zeitplan (UTC) ─────────────────────────"
echo -e "  ${BLUE}02:00${NC}  Backup → R2 + .env → GitHub + Mail"
echo -e "  ${BLUE}02:30${NC}  Watchtower Container-Updates"
echo -e "  ${BLUE}03:00${NC}  unattended-upgrades + Mail"
echo -e "  ${BLUE}03:30${NC}  Automatischer Reboot (bei Kernel-Update)"
echo -e "  ${BLUE}04:30${NC}  Claude Code Update"
echo -e "  ${BLUE}04:45${NC}  Gemini CLI Update"
echo ""
echo "  ── Services ───────────────────────────────"
echo -e "  ${BLUE}claw.beautymolt.com${NC}       OpenClaw"
echo -e "  ${BLUE}search.beautymolt.com${NC}     SearXNG"
echo -e "  ${BLUE}n8n.beautymolt.com${NC}        n8n"
echo -e "  ${BLUE}www.beautymolt.com${NC}        nginx"
echo -e "  ${BLUE}mail.beautymolt.com${NC}       Roundcube"
echo -e "  ${BLUE}portainer.beautymolt.com${NC}  Portainer"
echo -e "  ${BLUE}hermes.beautymolt.com${NC}     Hermes Agent"
echo ""
echo "  ── Claude Code ────────────────────────────"
if $CLAUDE_INSTALL_OK; then
  echo -e "  ${GREEN}[✓]${NC} claude installiert: $CLAUDE_VERSION"
  echo -e "  ${GREEN}[✓]${NC} alias: claude --dangerously-skip-permissions"
  echo -e "  ${YELLOW}[!]${NC} Auth nötig: su - alex && claude login"
else
  echo -e "  ${YELLOW}[!]${NC} Claude Code nicht installiert — manuell: npm install -g @anthropic-ai/claude-code"
fi
echo ""
echo "  ── Gemini CLI ─────────────────────────────"
if $GEMINI_INSTALL_OK; then
  echo -e "  ${GREEN}[✓]${NC} gemini installiert: $GEMINI_VERSION"
  echo -e "  ${YELLOW}[!]${NC} Auth nötig: su - alex && gemini auth login"
else
  echo -e "  ${YELLOW}[!]${NC} Gemini CLI nicht installiert — manuell: npm install -g @google/gemini-cli"
fi
echo ""
if [ "$BACKUP_RESTORED" = false ]; then
  warn "Kein Backup wiederhergestellt — Telegram Onboarding nötig:"
  echo "    docker exec -it openclaw node /app/dist/index.js onboard"
  echo ""
fi
echo -e "  ${YELLOW}HINWEIS:${NC} Neu einloggen damit docker-Gruppe aktiv wird:"
echo    "    su - alex"
echo ""
