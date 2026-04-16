#!/bin/bash
set -e
# ─────────────────────────────────────────────────────────────
# Ugly Stack — Bootstrap Script
# Version: V.20260416_7
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

BOOTSTRAP_VERSION="V.20260416_7"

fix_volume_ownership() {
  local dir="$1"
  local alex_gid; alex_gid=$(id -g alex 2>/dev/null || echo "1001")
  chown -R 1000:${alex_gid} "$dir"
  chmod -R g+rX "$dir"
}

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║ Ugly Stack — Bootstrap                   ║"
echo "║ beautymolt.com                           ║"
echo "║ ${BOOTSTRAP_VERSION}                     ║"
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
  curl -fsSL "https://vault.bitwarden.com/download/?app=cli&platform=linux" -o /tmp/bw.zip
  unzip -q /tmp/bw.zip -d /tmp/bw
  mv /tmp/bw/bw /usr/local/bin/bw
  chmod +x /usr/local/bin/bw
  rm -rf /tmp/bw /tmp/bw.zip
  log "Bitwarden CLI installiert"
fi

ask "Bitwarden E-Mail:"; read -p "  > " BW_EMAIL
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
# SCHRITT 2 — USER ALEX ANLEGEN
# ─────────────────────────────────────────────────────────────
info "Schritt 2/7 — User 'alex' anlegen..."

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

# ─────────────────────────────────────────────────────────────
# SCHRITT 3 — SYSTEM + TOOLS + DOCKER + UNATTENDED-UPGRADES
# ─────────────────────────────────────────────────────────────
info "Schritt 3/7 — System + Docker + Auto-Updates installieren..."

apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl git unzip jq gpg ca-certificates gnupg \
  lsb-release apt-transport-https software-properties-common \
  rclone unattended-upgrades update-notifier-common cron

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

mkdir -p "$STACK_DIR"/{openclaw-data,n8n-data,searxng-data,www}

grep -q "roundcube-data/"      "$STACK_DIR/.gitignore" || echo "roundcube-data/"      >> "$STACK_DIR/.gitignore"
grep -q "backup/www-sync.sh"   "$STACK_DIR/.gitignore" || echo "backup/www-sync.sh"   >> "$STACK_DIR/.gitignore"
grep -q "backup/.www-checksum" "$STACK_DIR/.gitignore" || echo "backup/.www-checksum" >> "$STACK_DIR/.gitignore"
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
    "bind": "lan",
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

chown -R alex:alex "$STACK_DIR"
fix_volume_ownership "$STACK_DIR/openclaw-data"
fix_volume_ownership "$STACK_DIR/n8n-data"

sudo -u alex git -C "$STACK_DIR" remote set-url origin \
  "https://${GITHUB_TOKEN}@github.com/uglyatbeautymolt/VPS_Bootstrap.git"
sudo -u alex git -C "$STACK_DIR" config user.name "Ugly"
sudo -u alex git -C "$STACK_DIR" config user.email "ugly@beautymolt.com"
unset GITHUB_TOKEN
log "Git Remote konfiguriert"
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
if cfg.get("gateway",{}).get("bind") != "lan":
    cfg.setdefault("gateway",{})["bind"] = "lan"; changed = True; print("  Fix: bind → lan")
if not cfg.get("hooks",{}).get("enabled"):
    hook_token = ""
    try:
        for line in open("$STACK_DIR/.env"):
            if line.startswith("OPENCLAW_HOOK_TOKEN="): hook_token = line.strip().split("=",1)[1]
    except: pass
    cfg["hooks"] = {"enabled": True, "token": hook_token or "UglyHook2026!beautymolt", "path": "/hooks"}
    changed = True; print("  Fix: hooks Block hinzugefügt")
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
info "Schritt 6/7 — Stack starten..."
cd "$STACK_DIR"
docker compose pull
docker compose up -d
sleep 30
docker compose ps

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

if [ -f "$STACK_DIR/n8n-data/workflows-backup.json" ]; then
  info "n8n Workflows importieren..."
  for i in $(seq 1 24); do
    docker exec n8n wget -q --spider http://localhost:5678/healthz 2>/dev/null && log "n8n bereit" && break
    warn "n8n noch nicht bereit ($i/24)"; sleep 5
  done
  docker cp "$STACK_DIR/n8n-data/workflows-backup.json"   n8n:/tmp/workflows-backup.json
  docker cp "$STACK_DIR/n8n-data/credentials-backup.json" n8n:/tmp/credentials-backup.json
  docker exec n8n n8n import:workflow    --input=/tmp/workflows-backup.json
  docker exec n8n n8n import:credentials --input=/tmp/credentials-backup.json
  rm -f "$STACK_DIR/n8n-data/workflows-backup.json" "$STACK_DIR/n8n-data/credentials-backup.json"
  docker exec n8n n8n update:workflow --all --active=true 2>/dev/null || \
    warn "n8n Workflow-Aktivierung — bitte manuell in UI aktivieren"
  log "n8n Workflows importiert und aktiviert"
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
info "Schritt 7/7 — Cron + Firewall..."

(crontab -u alex -l 2>/dev/null; \
  echo "0 2 * * * bash /home/alex/ugly-stack/backup/backup-master.sh >> /home/alex/ugly-stack/backup/backup.log 2>&1") \
  | crontab -u alex -

# Kurz warten damit crontab-Datei auf Disk geschrieben ist
sleep 2
CRON_BACKUP=$(crontab -u alex -l 2>/dev/null | grep "backup-master.sh" || echo "")
if [ -z "$CRON_BACKUP" ]; then
  warn "Backup-Cron-Verifikation fehlgeschlagen — Bootstrap läuft weiter"
  warn "Manuell prüfen: crontab -u alex -l"
else
  log "Backup-Cron eingerichtet und verifiziert (02:00 UTC)"
fi

ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw --force enable
log "Firewall konfiguriert"

# ─────────────────────────────────────────────────────────────
# ABSCHLUSS-KONTROLLE — IP, DNS, Zeitpläne
# ─────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║ Abschluss-Kontrolle                      ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── VPS-IP + Hoster ───────────────────────────────────────────────────
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

# ── Cloudflare DNS — ssh.beautymolt.com auf neue IP setzen ───────────
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

# ── Zeitplan-Kontrolle ────────────────────────────────────────────────
echo "  Zeitpläne (UTC):"
echo ""

# 02:00 — Backup [cron]
SCHED_BACKUP_OK=false
CRON_DAEMON=$(systemctl is-active cron 2>/dev/null || echo "unknown")
CRON_ENTRY=$(crontab -u alex -l 2>/dev/null | grep "backup-master.sh" || echo "")
if [ "$CRON_DAEMON" = "active" ] && [ -n "$CRON_ENTRY" ]; then
  echo -e "  ${GREEN}[✓]${NC} 02:00  Backup + .env sync + Mail     [cron]"
  echo    "         $CRON_ENTRY"
  SCHED_BACKUP_OK=true
else
  echo -e "  ${RED}[✗]${NC} 02:00  Backup + .env sync + Mail     [cron] — PROBLEM"
  [ "$CRON_DAEMON" != "active" ] && echo "         cron-Daemon: $CRON_DAEMON"
  [ -z "$CRON_ENTRY" ]           && echo "         Cron-Eintrag fehlt"
fi
echo ""

# 02:30 — Watchtower [intern]
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

# 03:00 — unattended-upgrades [systemd Timer] + Mail-Hook
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

# 03:30 — Automatischer Reboot [unattended-upgrades]
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
    && LINE_BACKUP="[OK] 02:00  Backup + .env sync + Mail     [cron]\n         $CRON_ENTRY" \
    || LINE_BACKUP="[!!] 02:00  Backup + .env sync + Mail     [cron] — PROBLEM"

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
$(date '+%Y-%m-%d %H:%M:%S UTC')
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
  https://portainer.beautymolt.com"

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
echo "╔══════════════════════════════════════════╗"
echo "║ Installation abgeschlossen!              ║"
echo "║ ${BOOTSTRAP_VERSION}                     ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Stack: $STACK_DIR"
echo "  User:  alex (sudo, docker)"
echo "  VPS:   $VPS_IP — $VPS_HOSTER"
echo "  SSH:   ssh.beautymolt.com → $VPS_IP"
echo ""
echo "  Portainer: https://portainer.beautymolt.com (admin / siehe .env)"
echo ""
echo "  Zeitplan (UTC):"
echo "    02:00 — Backup → R2 + .env → GitHub + Mail  [cron]"
echo "    02:30 — Watchtower Container-Updates         [Watchtower intern]"
echo "    03:00 — unattended-upgrades + Mail           [systemd Timer + ExecStartPost]"
echo "    03:30 — Automatischer Reboot (Kernel-Update) [unattended-upgrades]"
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
