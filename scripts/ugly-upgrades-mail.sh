#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  Ugly Stack — unattended-upgrades Status-Mail
#  Wird via systemd ExecStartPost nach apt-daily-upgrade.service
#  aufgerufen. Liest das Log aus und sendet eine Mail via Brevo.
# ─────────────────────────────────────────────────────────────

STACK_DIR="/home/alex/ugly-stack"
UA_LOG="/var/log/unattended-upgrades/unattended-upgrades.log"

[ ! -f "$STACK_DIR/.env" ] && exit 0
source "$STACK_DIR/.env"
[ -z "$BREVO_KEY" ] && exit 0

DATE=$(date '+%Y-%m-%d %H:%M:%S UTC')

# Letzten Lauf aus Log extrahieren — alles ab dem letzten "Starting unattended"
if [ -f "$UA_LOG" ]; then
  LAST_RUN=$(awk '/Starting unattended/{found=NR} found{print NR": "$0}' "$UA_LOG" \
    | tail -100 \
    | awk -F': ' '{$1=""; print $0}' \
    | sed 's/^ //')
else
  LAST_RUN="Log nicht gefunden: $UA_LOG"
fi

# Installierte Pakete extrahieren
INSTALLED=$(echo "$LAST_RUN" | grep -E "^[0-9]{4}-.*Packages.*upgraded|Upgraded:|Installed:" || true)
PKG_LIST=$(echo "$LAST_RUN" | grep -E "^\s*(Upgraded|Installed):" | sed 's/^\s*/  /' || true)
UPGRADE_COUNT=$(echo "$LAST_RUN" | grep -oE "[0-9]+ upgraded" | head -1 || echo "")
INSTALL_COUNT=$(echo "$LAST_RUN" | grep -oE "[0-9]+ newly installed" | head -1 || echo "")
REBOOT_REQUIRED=""
[ -f /var/run/reboot-required ] && REBOOT_REQUIRED="JA — Neustart um 03:30 geplant"

# Betreff + Zusammenfassung
if [ -n "$UPGRADE_COUNT" ] || [ -n "$INSTALL_COUNT" ]; then
  SUBJECT="Ugly Stack — Updates installiert $(date '+%Y-%m-%d')"
  SUMMARY="Pakete installiert:"
  [ -n "$UPGRADE_COUNT" ]  && SUMMARY="$SUMMARY $UPGRADE_COUNT"
  [ -n "$INSTALL_COUNT" ]  && SUMMARY="$SUMMARY, $INSTALL_COUNT"
else
  SUBJECT="Ugly Stack — Keine Updates $(date '+%Y-%m-%d')"
  SUMMARY="Keine Pakete installiert — System bereits aktuell."
fi

MAIL_BODY="Ugly Stack — unattended-upgrades Report
$DATE
========================================

Zusammenfassung:
  $SUMMARY

Neustart erforderlich:
  ${REBOOT_REQUIRED:-Nein}

----------------------------------------
Log (letzter Lauf):
$LAST_RUN"

MAIL_PAYLOAD=$(jq -n \
  --arg subject "$SUBJECT" \
  --arg body "$MAIL_BODY" \
  '{
    sender: {name: "Ugly Updates", email: "ugly@beautymolt.com"},
    to: [{email: "alex@alexstuder.ch"}],
    subject: $subject,
    textContent: $body
  }')

curl -s -o /tmp/brevo_upgrades_response.txt \
  -X POST "https://api.brevo.com/v3/smtp/email" \
  -H "api-key: ${BREVO_KEY}" \
  -H "Content-Type: application/json" \
  -d "$MAIL_PAYLOAD" \
  > /dev/null 2>&1 || true
