#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  AI Login Manager
#  Verwaltet Claude Code Authentifizierung auf dem VPS
#  Quelle: ~/ugly-stack/.env
#  Auth-Datei: ~/.claude-auth (wird von ~/.bashrc gesourced)
# ─────────────────────────────────────────────────────────────

ENV_FILE="/home/alex/ugly-stack/.env"
AUTH_FILE="/home/alex/.claude-auth"
BASHRC="/home/alex/.bashrc"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Werte aus .env lesen ─────────────────────────────────────
source "$ENV_FILE"
[ -z "$ANTHROPIC_API_KEY" ]       && { echo -e "${RED}[✗]${NC} ANTHROPIC_API_KEY fehlt in .env";      exit 1; }
[ -z "$CLAUDE_CODE_OAUTH_TOKEN" ] && { echo -e "${RED}[✗]${NC} CLAUDE_CODE_OAUTH_TOKEN fehlt in .env"; exit 1; }

# ── ~/.bashrc einmalig umstellen ─────────────────────────────
if grep -q "^export ANTHROPIC_API_KEY=" "$BASHRC"; then
  sed -i "s|^export ANTHROPIC_API_KEY=.*|source ~/.claude-auth 2>/dev/null|" "$BASHRC"
  echo -e "${YELLOW}[!]${NC} ~/.bashrc angepasst — ANTHROPIC_API_KEY durch source ~/.claude-auth ersetzt"
fi

# ── Aktuellen Modus ermitteln ─────────────────────────────────
get_active_mode() {
  if [ ! -f "$AUTH_FILE" ]; then
    echo "none"
  elif grep -q "^export CLAUDE_CODE_OAUTH_TOKEN=" "$AUTH_FILE"; then
    echo "oauth"
  elif grep -q "^export ANTHROPIC_API_KEY=" "$AUTH_FILE"; then
    echo "apikey"
  else
    echo "none"
  fi
}

# ── Auth-Datei schreiben ──────────────────────────────────────
write_auth() {
  local mode="$1"
  if [ "$mode" = "oauth" ]; then
    cat > "$AUTH_FILE" <<EOF
# AI Login — verwaltet durch ai_login.sh
# export ANTHROPIC_API_KEY="..."   ← inaktiv
export CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"
EOF
  elif [ "$mode" = "apikey" ]; then
    cat > "$AUTH_FILE" <<EOF
# AI Login — verwaltet durch ai_login.sh
export ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
# export CLAUDE_CODE_OAUTH_TOKEN="..."   ← inaktiv
EOF
  fi
  chmod 600 "$AUTH_FILE"
}

# ── Hauptmenü ────────────────────────────────────────────────
while true; do
  ACTIVE=$(get_active_mode)

  case "$ACTIVE" in
    oauth)  ACTIVE_LABEL="Claude — OAuth Token (Subscription)" ;;
    apikey) ACTIVE_LABEL="Claude — API Key" ;;
    *)      ACTIVE_LABEL="(keiner)" ;;
  esac

  clear
  echo ""
  echo -e "  ${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "  ${BOLD}║          AI Login Manager                ║${NC}"
  echo -e "  ${BOLD}╠══════════════════════════════════════════╣${NC}"
  echo -e "  ${BOLD}║${NC}  Aktiv: ${GREEN}${ACTIVE_LABEL}${NC}"
  echo -e "  ${BOLD}╠══════════════════════════════════════════╣${NC}"
  echo -e "  ${BOLD}║${NC}  ${CYAN}1)${NC} Claude — OAuth Token (Subscription)"
  echo -e "  ${BOLD}║${NC}  ${CYAN}2)${NC} Claude — API Key"
  echo -e "  ${BOLD}║${NC}  ────────────────────────────────────"
  echo -e "  ${BOLD}║${NC}  ${CYAN}q)${NC} Beenden"
  echo -e "  ${BOLD}╚══════════════════════════════════════════╝${NC}"
  echo ""
  echo -ne "  Auswahl: "
  read -r CHOICE

  case "$CHOICE" in
    1)
      write_auth "oauth"
      source "$AUTH_FILE"
      echo ""
      echo -e "  ${GREEN}[✓]${NC} Gewechselt zu: Claude OAuth Token"
      echo -e "  ${YELLOW}[!]${NC} Für neue Sessions: source ~/.bashrc"
      echo ""
      read -p "  Enter zum Fortfahren..." _
      ;;
    2)
      write_auth "apikey"
      source "$AUTH_FILE"
      echo ""
      echo -e "  ${GREEN}[✓]${NC} Gewechselt zu: Claude API Key"
      echo -e "  ${YELLOW}[!]${NC} Für neue Sessions: source ~/.bashrc"
      echo ""
      read -p "  Enter zum Fortfahren..." _
      ;;
    q|Q)
      echo ""
      echo -e "  ${BLUE}[→]${NC} Aktiv bleibt: ${GREEN}${ACTIVE_LABEL}${NC}"
      echo ""
      exit 0
      ;;
    *)
      echo ""
      echo -e "  ${RED}[✗]${NC} Ungültige Auswahl"
      sleep 1
      ;;
  esac
done
