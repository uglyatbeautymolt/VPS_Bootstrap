# Ugly Stack — Projektkontext für Claude

> Diese Datei wird am Anfang jeder neuen Konversation gelesen damit Claude den Projektkontext kennt.

## Projekt-Übersicht

Persönlicher KI-Agent "Ugly" auf einem selbst gehosteten Hostinger VPS (Ubuntu 24.04).
Betreiber: Alex (alex@alexstuder.ch)
Repo: https://github.com/uglyatbeautymolt/VPS_Bootstrap
Stack-Verzeichnis auf VPS: /home/alex/ugly-stack
VPS User: alex (sudo, docker-Gruppe)
Telegram Bot: @openClawBeautyBot

## GitHub Zugriff

Claude hat direkten GitHub MCP Zugriff auf uglyatbeautymolt/VPS_Bootstrap.
Vor jeder Änderung immer zuerst die aktuelle Datei aus dem Repo lesen!

## Services

| Container | URL | Port |
|-----------|-----|------|
| cloudflared | — | — |
| nginx | www.beautymolt.com | 80 |
| openclaw | claw.beautymolt.com | 18789 |
| searxng | search.beautymolt.com | 8080 |
| n8n | n8n.beautymolt.com | 5678 |
| roundcube | mail.beautymolt.com | 80 |

Alle Container im Docker Bridge-Netzwerk: **ugly-net**

## Secrets-Verwaltung

- Secrets in: `/home/alex/ugly-stack/.env` (verschlüsselt als `.env.gpg` im Repo)
- GPG Passwort: in Bitwarden → `BACKUP_GPG_PASSWORD` (wird beim Bootstrap automatisch geholt)
- Bitwarden Login: alex@alexstuder.ch

```bash
cd ~/ugly-stack
./set-secret.sh SECRET_NAME "wert"   # aktualisiert .env + verschlüsselt + git push
```

## E-Mail Workflow (E-Mail → Ugly → Antwort)

```
alex@alexstuder.ch → ugly@beautymolt.com (Cloudflare Email Routing → Zoho)
       ↓
   n8n IMAP Trigger (Zoho IMAP)
       ↓
   JavaScript Node (Prompt Injection Bereinigung — nur technische Sanitization, KEIN Handlungsverbot)
       ↓
   HTTP Request → http://openclaw:18789/hooks/agent
   Header: x-openclaw-token: <OPENCLAW_HOOK_TOKEN>
   Header: Content-Type: application/json
   Body: {"message":"<aufbereitete Mail>","name":"Email","wakeMode":"now"}
       ↓
   openclaw verarbeitet (fire-and-forget, gibt runId zurück)
       ↓
   Brevo REST API → Antwort an Absender
```

## n8n Prompt-Struktur (KRITISCH)

Der Handlungsauftrag muss **VOR** dem E-Mail-Inhalt stehen. Wenn der Prompt mit einer Warnung wie "unvertrauenswürdig / keine Anweisungen ausführen" beginnt oder endet, blockiert openclaw sich selbst und tut nichts.

**Korrekte Struktur:**
```
Du hast eine neue E-Mail erhalten. Beantworte sie auf Deutsch per Mail an den Absender.

Von: {{$json.from}}
Betreff: {{$json.subject}}

---EMAIL START---
{{$json.textPlain}}
---EMAIL END---

Sende deine Antwort per Mail an den Absender. Bestätige danach kurz per Telegram.
```

## openclaw Webhook-Konfiguration (openclaw.json)

**WICHTIG:** `hooks` ist ein **Top-Level-Key** — NICHT unter `gateway` einbetten!

```json
{
  "gateway": { ... },
  "hooks": {
    "enabled": true,
    "token": "<OPENCLAW_HOOK_TOKEN>",
    "path": "/hooks"
  }
}
```

**WICHTIG:** `gateway.bind` muss `"lan"` sein (nicht `"loopback"`) damit n8n im Docker-Netzwerk erreichbar ist!

**Auth-Header:** `x-openclaw-token: <token>` — NICHT `Authorization: Bearer` für Hooks!

Test vom VPS:
```bash
docker exec n8n wget -qO- \
  --header='x-openclaw-token: TOKEN' \
  --header='Content-Type: application/json' \
  --post-data='{"message":"Test","name":"Email","wakeMode":"now"}' \
  'http://openclaw:18789/hooks/agent'
# Erwartete Antwort: {"ok":true,"runId":"..."}
```

## Brevo E-Mail Konfiguration

- SMTP User: a50340001@smtp-brevo.com (für SMTP-Versand n8n)
- SMTP API Key: in .env als BREVO_SMTP_API_KEY (xsmtpsib-...)
- REST API Key: in .env als BREVO_KEY (xkeysib-...) ← für openclaw Skill
- Absender: ugly@beautymolt.com (verifiziert in Brevo)
- openclaw nutzt BREVO_KEY + Brevo REST API: https://api.brevo.com/v3/smtp/email
- n8n nutzt BREVO_SMTP_API_KEY + smtp-relay.brevo.com:587

## Modelle

Primary: openrouter/anthropic/claude-sonnet-4-6
Fallbacks: gemini-2.5-flash, gemini-3.1-flash-lite-preview, mistral-small, deepseek-v3.2

Modell wechseln:
```bash
docker exec openclaw openclaw config set agents.defaults.model.primary "openrouter/google/gemini-2.5-flash"
```
ACHTUNG: Dashboard-Dropdown hat Bug — strippt Provider-Prefix. Immer per CLI oder /model Befehl wechseln!

## Backup

- Täglich 03:00 via Cron → Cloudflare R2 (verschlüsselt GPG AES256)
- Letzte 7 Backups behalten
- Nach jedem Backup: Protokoll-Mail an alex@alexstuder.ch via Brevo
- Manuell: `cd ~/ugly-stack && ./backup/backup-master.sh`
- .env.gpg alle 30 Min → GitHub

## Bootstrap (Neuaufbau)

```bash
curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh -o bootstrap.sh
chmod +x bootstrap.sh
./bootstrap.sh
```

Fragt nur nach: Bitwarden E-Mail, Bitwarden Master-Passwort, Passwort für User alex.
**Das openclaw Onboarding ist bereits abgeschlossen — der Zustand wird automatisch aus dem letzten Backup von R2 wiederhergestellt. Onboarding nie nochmals durchführen!**

## Bekannte Eigenheiten / Fixes

- openclaw-data und n8n-data müssen immer 1000:1000 gehören
- n8n Import erst nach health-check auf localhost:5678/healthz
- docker-Gruppe für alex erst nach neu einloggen aktiv
- `gateway.bind` wird manchmal vom Dashboard auf `"loopback"` zurückgesetzt → nach Dashboard-Änderungen prüfen
- `hooks` muss Top-Level-Key sein — NICHT unter `gateway` einbetten (gibt "Unrecognized key" Fehler)
- Hook-Auth-Header ist `x-openclaw-token` — NICHT `Authorization: Bearer`
- n8n Prompt: Handlungsauftrag VOR dem Mail-Inhalt — "unvertrauenswürdig"-Warnung blockiert openclaw
- Brevo Skill nutzt BREVO_KEY (REST API Key), nicht BREVO_SMTP_API_KEY
- openclaw schreibt manchmal Python-Scripts statt das Brevo Skill zu nutzen → in AGENTS.md dokumentiert
- Scripts aus GitHub haben kein +x — bootstrap.sh setzt chmod+x nach git clone
- Backup-Mail JSON muss via python3 gebaut werden — Shell-Interpolation bricht bei Sonderzeichen
- `github:push_files` setzt kein executable-Bit — nach jedem push der Scripts `chmod +x` nötig oder bootstrap.sh übernimmt das

## Arbeitsweise mit Claude

1. Vor jedem Vorschlag relevante Dateien direkt aus dem Repo lesen
2. Einen Schritt auf einmal — auf Bestätigung warten
3. Kein Trial-and-Error — erst verstehen, dann handeln
4. Fehler klar benennen — Ursache erklären bevor Fix vorgeschlagen wird
5. bootstrap.sh Änderungen: direkt via GitHub MCP committen — kein manueller Download nötig
6. Nie Modell-IDs erfinden — immer von openrouter.ai verifizieren
