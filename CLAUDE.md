# Ugly Stack — Projektkontext für Claude

> Diese Datei wird am Anfang jeder neuen Konversation gelesen damit Claude den Projektkontext kennt.

## Projekt-Übersicht

Persönlicher KI-Agent "Ugly" auf einem selbst gehosteten Hostinger VPS (Ubuntu 24.04).
Betreiber: Alex (alex@alexstuder.ch)
Repo: https://github.com/uglyatbeautymolt/VPS_Bootstrap
Stack-Verzeichnis auf VPS: /home/alex/ugly-stack
VPS User: alex (sudo, docker-Gruppe)

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

## Wichtige Zugangsdaten (nur Struktur, keine echten Werte)

- Secrets in: `/home/alex/ugly-stack/.env` (verschlüsselt als `.env.gpg` im Repo)
- GPG Passwort: in Bitwarden → `BACKUP_GPG_PASSWORD` (wird beim Bootstrap automatisch geholt)
- Bitwarden Login: alex@alexstuder.ch

## Secrets-Verwaltung

```bash
cd ~/ugly-stack
./set-secret.sh SECRET_NAME "wert"   # aktualisiert .env + verschlüsselt + git push
```

Das Script macht: git pull → .env updaten → GPG verschlüsseln → git push → Container neu starten

## E-Mail Workflow (E-Mail → Ugly → Antwort)

```
alex@alexstuder.ch → ugly@beautymolt.com (Cloudflare Email Routing → Zoho)
       ↓
   n8n IMAP Trigger (Zoho IMAP)
       ↓
   JavaScript Node (Prompt Injection bereinigung)
       ↓
   HTTP Request → http://openclaw:18789/hooks/agent
   Header: Authorization: Bearer UglyHook2026!beautymolt
   Body: {message, name:"Email", wakeMode:"now", deliver:false}
       ↓
   openclaw verarbeitet
       ↓
   Brevo REST API → Antwort an Absender
```

## Brevo E-Mail Konfiguration

- SMTP User: a50340001@smtp-brevo.com (für SMTP-Versand)
- SMTP API Key: in .env als BREVO_SMTP_API_KEY (xsmtpsib-...)
- REST API Key: in .env als BREVO_KEY (xkeysib-...) ← für openclaw Skill
- Absender: ugly@beautymolt.com (verifiziert in Brevo)
- openclaw nutzt BREVO_KEY + Brevo REST API: https://api.brevo.com/v3/smtp/email
- n8n nutzt BREVO_SMTP_API_KEY + smtp-relay.brevo.com:587

## openclaw Hooks Konfiguration

In openclaw.json (auf VPS, nicht im Repo):
```json
"hooks": {
  "enabled": true,
  "token": "UglyHook2026!beautymolt",
  "path": "/hooks"
}
```

Achtung: "bind" muss "lan" sein (nicht "loopback") damit n8n erreichbar ist!
Das Dashboard setzt es manchmal auf "loopback" zurück → nach Dashboard-Änderungen prüfen.

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
- Manuell: `cd ~/ugly-stack && ./backup/backup-master.sh`
- .env.gpg alle 30 Min → GitHub

## Bootstrap (Neuaufbau)

```bash
curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh -o bootstrap.sh
chmod +x bootstrap.sh
./bootstrap.sh
```

Fragt nur nach: Bitwarden E-Mail, Bitwarden Master-Passwort, Passwort für User alex

## Bekannte Eigenheiten / Fixes

- openclaw-data und n8n-data müssen immer 1000:1000 gehören
- n8n Import erst nach health-check auf localhost:5678/healthz
- openclaw.json "bind" wird manchmal vom Dashboard auf "loopback" zurückgesetzt → prüfen
- Brevo Skill nutzt BREVO_KEY (REST API Key), nicht BREVO_SMTP_API_KEY
- openclaw schreibt manchmal Python-Scripts statt das Brevo Skill zu nutzen → in AGENTS.md dokumentiert

## Arbeitsweise mit Claude

1. Vor jedem Vorschlag relevante Dateien direkt aus dem Repo lesen
2. Einen Schritt auf einmal — auf Bestätigung warten
3. Kein Trial-and-Error — erst verstehen, dann handeln
4. Bei bootstrap.sh Änderungen: komplette Datei direkt via GitHub MCP committen
5. Nie Modell-IDs erfinden — immer von openrouter.ai verifizieren
