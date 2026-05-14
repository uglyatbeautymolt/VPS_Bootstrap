#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  Ugly Stack — Container Healthcheck
#  Cron: 30 3 * * * bash /home/alex/ugly-stack/backup/healthcheck.sh
#  Läuft NACH unattended-upgrades (~03:00) und Watchtower (02:30).
#
#  Phase 1: docker daemon prüfen
#  Phase 2: erwartete Container — bei exited 1x docker start + recheck
#  Phase 3: HTTPS-Probe der Public-URLs (E2E via Cloudflare)
#  Phase 4: Mail-Report (nur bei Auffälligkeiten)
# ─────────────────────────────────────────────────────────────

STACK_DIR="/home/alex/ugly-stack"
LOG="$STACK_DIR/backup/healthcheck.log"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $1" | tee -a "$LOG"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [!!] $1" | tee -a "$LOG"; }
info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [--] $1" | tee -a "$LOG"; }

echo "" >> "$LOG"
info "======== Healthcheck Start ========"

source "$STACK_DIR/.env"

send_mail() {
  local subject="$1"
  local body="$2"
  local payload
  payload=$(jq -n \
    --arg from_name "Ugly Healthcheck" \
    --arg from_email "ugly@beautymolt.com" \
    --arg to_email "alex@alexstuder.ch" \
    --arg subject "$subject" \
    --arg body "$body" \
    '{
      sender: {name: $from_name, email: $from_email},
      to: [{email: $to_email}],
      subject: $subject,
      textContent: $body
    }')
  local http_code
  http_code=$(curl -s -o /tmp/brevo_healthcheck_response.txt -w "%{http_code}" \
    -X POST "https://api.brevo.com/v3/smtp/email" \
    -H "api-key: ${BREVO_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload")
  if [ "$http_code" = "201" ]; then
    log "Status-Mail gesendet (HTTP $http_code)"
  else
    fail "Status-Mail fehlgeschlagen (HTTP $http_code): $(cat /tmp/brevo_healthcheck_response.txt)"
  fi
}

# ─────────────────────────────────────────────────────────────
# KONFIGURATION
# ─────────────────────────────────────────────────────────────

EXPECTED_CONTAINERS=(
  forge-postgres
  forge-db-api
  forge-dashboard
  nginx
  cloudflared
  openclaw
  n8n
  roundcube
  searxng
  portainer
  watchtower
)

PROBE_URLS=(
  https://claw.beautymolt.com/
  https://search.beautymolt.com/
  https://n8n.beautymolt.com/
  https://mail.beautymolt.com/
  https://portainer.beautymolt.com/
  https://dashboard.beautymolt.com/
)

# ─────────────────────────────────────────────────────────────
# PHASE 1 — DOCKER DAEMON
# ─────────────────────────────────────────────────────────────
if ! docker info > /dev/null 2>&1; then
  fail "Docker Daemon nicht erreichbar — FATAL"
  send_mail "Ugly Healthcheck - $(date '+%Y-%m-%d') - FATAL: Docker Daemon" \
"Ugly Stack Healthcheck-Report
$(date '+%Y-%m-%d %H:%M:%S')
========================================

FATAL: Docker Daemon nicht erreichbar.

\`docker info\` schlug fehl. Container-Checks und HTTP-Probes
wurden uebersprungen — manueller Eingriff noetig.

  systemctl status docker
  journalctl -u docker --since '10 min ago'
"
  exit 2
fi
log "Docker Daemon OK"

# ─────────────────────────────────────────────────────────────
# PHASE 2 — CONTAINER STATUS + AUTO-RESTART
# ─────────────────────────────────────────────────────────────
RESTARTED=()
PERMANENT_FAILS=()

for c in "${EXPECTED_CONTAINERS[@]}"; do
  STATUS=$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null || echo "missing")

  if [ "$STATUS" = "running" ]; then
    log "Container $c: running"
    continue
  fi

  if [ "$STATUS" = "missing" ]; then
    fail "Container $c: existiert nicht"
    PERMANENT_FAILS+=("$c (Container existiert nicht)")
    continue
  fi

  fail "Container $c: status=$STATUS — Restart-Versuch"
  if docker start "$c" > /dev/null 2>&1; then
    sleep 5
    NEW_STATUS=$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
    if [ "$NEW_STATUS" = "running" ]; then
      log "Container $c: nach Restart running"
      RESTARTED+=("$c (war: $STATUS)")
    else
      fail "Container $c: nach Restart status=$NEW_STATUS"
      PERMANENT_FAILS+=("$c (war: $STATUS, nach Restart: $NEW_STATUS)")
    fi
  else
    fail "Container $c: docker start fehlgeschlagen"
    PERMANENT_FAILS+=("$c (war: $STATUS, docker start fehlgeschlagen)")
  fi
done

# ─────────────────────────────────────────────────────────────
# PHASE 3 — HTTP-PROBE (nach Container-Restarts)
# ─────────────────────────────────────────────────────────────
HTTP_FAILS=()

for url in "${PROBE_URLS[@]}"; do
  CODE=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
  if [ "$CODE" = "000" ]; then
    fail "HTTP $url: connect-error (000)"
    HTTP_FAILS+=("$url → connect-error")
  elif [ "$CODE" -ge 500 ] 2>/dev/null; then
    fail "HTTP $url: $CODE"
    HTTP_FAILS+=("$url → $CODE")
  else
    log "HTTP $url: $CODE"
  fi
done

# ─────────────────────────────────────────────────────────────
# PHASE 4 — REPORTING
# ─────────────────────────────────────────────────────────────
TOTAL_FAILS=$((${#PERMANENT_FAILS[@]} + ${#HTTP_FAILS[@]}))

if [ ${#RESTARTED[@]} -eq 0 ] && [ $TOTAL_FAILS -eq 0 ]; then
  info "Alle Container running, alle HTTP-Probes OK — keine Mail"
  info "======== Healthcheck Ende — alles OK ========"
  exit 0
fi

if [ $TOTAL_FAILS -gt 0 ]; then
  SUBJECT="Ugly Healthcheck - $(date '+%Y-%m-%d') - FEHLER ($TOTAL_FAILS)"
else
  SUBJECT="Ugly Healthcheck - $(date '+%Y-%m-%d') - ${#RESTARTED[@]} Container restartet"
fi

format_list() {
  if [ ${#@} -eq 0 ]; then
    echo "  (keine)"
  else
    printf '  - %s\n' "$@"
  fi
}

BODY="Ugly Stack Healthcheck-Report
$(date '+%Y-%m-%d %H:%M:%S')
========================================

Container automatisch restartet (jetzt running):
$(format_list "${RESTARTED[@]}")

Container permanent down:
$(format_list "${PERMANENT_FAILS[@]}")

HTTP-Probes fehlgeschlagen (Code >= 500 oder connect-error):
$(format_list "${HTTP_FAILS[@]}")

----------------------------------------
Log: tail -100 $LOG
"

send_mail "$SUBJECT" "$BODY"
info "======== Healthcheck Ende — Restarts: ${#RESTARTED[@]}, Fails: $TOTAL_FAILS ========"
exit $TOTAL_FAILS
