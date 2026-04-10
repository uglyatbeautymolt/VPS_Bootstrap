#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  Ugly Stack — Backup Verifikation
#  Holt neuestes Backup von R2, entschlüsselt es und vergleicht
#  den Inhalt mit den aktuellen Dateien auf dem VPS.
#
#  Verwendung: bash ~/ugly-stack/backup/verify-backup.sh
# ─────────────────────────────────────────────────────────────

STACK_DIR="/home/alex/ugly-stack"
OPENCLAW_DATA="$STACK_DIR/openclaw-data"
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${BLUE}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

source "$STACK_DIR/.env" || { echo "Fehler: .env nicht gefunden"; exit 1; }

VERIFY_DIR="/tmp/backup-verify-$(TZ="${TZ}" date +%Y%m%d_%H%M%S)"
mkdir -p "$VERIFY_DIR"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Ugly Stack — Backup Verifikation        ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Neuestes Backup von R2 holen ─────────────────────────────
info "Suche neuestes Backup in R2..."
LATEST=$(rclone ls "r2:${CF_R2_BUCKET}/backups/" \
  --config "$STACK_DIR/rclone/rclone.conf" 2>/dev/null \
  | sort | tail -1 | awk '{print $2}')

[ -z "$LATEST" ] && { fail "Kein Backup in R2 gefunden"; exit 1; }
info "Backup: $LATEST"

info "Lade herunter..."
rclone copy "r2:${CF_R2_BUCKET}/backups/$LATEST" /tmp/ \
  --config "$STACK_DIR/rclone/rclone.conf"
ok "Download abgeschlossen"

# ── Entschlüsseln + entpacken ─────────────────────────────────
info "Entschlüssele und entpacke..."
gpg --batch --yes \
  --passphrase "$BACKUP_GPG_PASSWORD" \
  --decrypt "/tmp/$LATEST" \
  | tar -xz -C "$VERIFY_DIR/" 2>/dev/null
ok "Entpackt nach: $VERIFY_DIR"
rm -f "/tmp/$LATEST"

echo ""
echo "════════════════════════════════════════════"
echo "  VERGLEICH"
echo "════════════════════════════════════════════"

ERRORS=0

# ── openclaw workspace ────────────────────────────────────────
echo ""
info "openclaw workspace..."
BACKUP_TAR=$(ls "$VERIFY_DIR/openclaw-data/"*.tar.gz 2>/dev/null | head -1)
if [ -z "$BACKUP_TAR" ]; then
  fail "openclaw: Kein tar.gz im Backup gefunden"
  ERRORS=$((ERRORS + 1))
else
  TMP_CLAW="/tmp/backup-claw-$$"
  mkdir -p "$TMP_CLAW"
  tar -xzf "$BACKUP_TAR" -C "$TMP_CLAW/" 2>/dev/null

  WORKSPACE_ORIG="$OPENCLAW_DATA/workspace"
  WORKSPACE_BACK="$TMP_CLAW/workspace"

  # Workspace-Dateien vergleichen
  # sudo diff direkt verwenden — Exit-Code 0=gleich, 1=unterschiedlich, 2=Fehler/fehlt
  for FILE in AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md MEMORY.md HEARTBEAT.md; do
    ORIG="$WORKSPACE_ORIG/$FILE"
    BACK="$WORKSPACE_BACK/$FILE"

    # Prüfen ob Backup-Datei existiert (kein sudo nötig — /tmp gehört alex)
    BACK_EXISTS=false
    [ -f "$BACK" ] && BACK_EXISTS=true

    # Prüfen ob Original existiert (sudo nötig — 1000:1000 Ownership)
    ORIG_EXISTS=false
    sudo test -f "$ORIG" 2>/dev/null && ORIG_EXISTS=true

    if [ "$ORIG_EXISTS" = false ] && [ "$BACK_EXISTS" = false ]; then
      continue  # beide fehlen — OK, optional
    elif [ "$BACK_EXISTS" = false ]; then
      warn "openclaw/$FILE: fehlt im Backup"
    elif [ "$ORIG_EXISTS" = false ]; then
      warn "openclaw/$FILE: nur im Backup vorhanden"
    else
      if sudo diff -q "$ORIG" "$BACK" &>/dev/null; then
        ok "openclaw/$FILE: identisch"
      else
        fail "openclaw/$FILE: UNTERSCHIED"
        sudo diff "$ORIG" "$BACK" | head -10
        ERRORS=$((ERRORS + 1))
      fi
    fi
  done

  # Skills vergleichen
  echo ""
  info "openclaw skills..."
  SKILLS_ORIG="$WORKSPACE_ORIG/skills"
  SKILLS_BACK="$WORKSPACE_BACK/skills"

  SKILLS_ORIG_EXISTS=false
  sudo test -d "$SKILLS_ORIG" 2>/dev/null && SKILLS_ORIG_EXISTS=true
  SKILLS_BACK_EXISTS=false
  [ -d "$SKILLS_BACK" ] && SKILLS_BACK_EXISTS=true

  if [ "$SKILLS_ORIG_EXISTS" = false ] && [ "$SKILLS_BACK_EXISTS" = false ]; then
    warn "openclaw/skills: keine Skills vorhanden"
  elif [ "$SKILLS_BACK_EXISTS" = false ]; then
    fail "openclaw/skills: live vorhanden aber fehlen im Backup!"
    sudo ls "$SKILLS_ORIG"
    ERRORS=$((ERRORS + 1))
  elif [ "$SKILLS_ORIG_EXISTS" = false ]; then
    warn "openclaw/skills: nur im Backup vorhanden"
    ls "$SKILLS_BACK"
  else
    SKILL_DIFF=$(sudo diff -rq "$SKILLS_ORIG/" "$SKILLS_BACK/" 2>/dev/null)
    if [ -z "$SKILL_DIFF" ]; then
      ok "openclaw/skills: identisch"
      for SKILL in $(sudo ls "$SKILLS_ORIG"); do
        ok "  skill: $SKILL"
      done
    else
      fail "openclaw/skills: UNTERSCHIED"
      echo "$SKILL_DIFF"
      ERRORS=$((ERRORS + 1))
    fi
  fi

  rm -rf "$TMP_CLAW"
fi

# ── n8n ───────────────────────────────────────────────────────
echo ""
info "n8n..."
[ -f "$VERIFY_DIR/n8n-data/workflows-backup.json" ] \
  && ok "n8n/workflows-backup.json: vorhanden" \
  || { fail "n8n/workflows-backup.json: FEHLT"; ERRORS=$((ERRORS + 1)); }
[ -f "$VERIFY_DIR/n8n-data/credentials-backup.json" ] \
  && ok "n8n/credentials-backup.json: vorhanden" \
  || { fail "n8n/credentials-backup.json: FEHLT"; ERRORS=$((ERRORS + 1)); }

# ── nginx ─────────────────────────────────────────────────────
echo ""
info "nginx..."
if diff -rq \
  "$VERIFY_DIR/nginx/conf.d/" \
  "$STACK_DIR/nginx/conf.d/" &>/dev/null; then
  ok "nginx/conf.d: identisch"
else
  fail "nginx/conf.d: UNTERSCHIED"
  diff -rq "$VERIFY_DIR/nginx/conf.d/" "$STACK_DIR/nginx/conf.d/"
  ERRORS=$((ERRORS + 1))
fi

# ── Aufräumen ─────────────────────────────────────────────────
rm -rf "$VERIFY_DIR"

echo ""
echo "════════════════════════════════════════════"
if [ $ERRORS -eq 0 ]; then
  ok "Backup vollständig und aktuell — Fehler: 0"
else
  fail "Verifikation abgeschlossen — Fehler: $ERRORS"
  warn "Tipp: Erst 'backup-master.sh' ausführen, dann erneut prüfen"
fi
echo "════════════════════════════════════════════"
echo ""
exit $ERRORS
