# Ugly Stack — Betriebshandbuch

## Inhaltsverzeichnis
1. [Erste Installation](#1-erste-installation)
2. [Tokens und API Keys verwalten](#2-tokens-und-api-keys-verwalten)
3. [Stack verwalten](#3-stack-verwalten)
4. [Container-Zugriff](#4-container-zugriff)
5. [Backup](#5-backup)
6. [Restore](#6-restore)
7. [Neue Container hinzufügen](#7-neue-container-hinzufügen)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Erste Installation

### Vorbereitung
Bevor du `bootstrap.sh` startest, sammle folgende Informationen:

| Secret | Wo finden |
|--------|-----------|
| `CLOUDFLARE_TUNNEL_TOKEN` | Cloudflare → Zero Trust → Tunnels → beautymoltTunnel |
| `OPENROUTER_API_KEY` | openrouter.ai → Keys |
| `TELEGRAM_BOT_TOKEN` | @BotFather auf Telegram — bestehenden weiterverwenden |
| `OPENCLAW_GATEWAY_TOKEN` | Selbst wählen — bestehenden weiterverwenden |
| `N8N_BASIC_AUTH_USER` | Selbst wählen |
| `N8N_BASIC_AUTH_PASSWORD` | Selbst wählen |
| `N8N_ENCRYPTION_KEY` | `openssl rand -hex 16` — bestehenden beibehalten! |
| `ZOHO_SMTP_USER` | ugly@beautymolt.com |
| `ZOHO_SMTP_PASSWORD` | Zoho Mail → Einstellungen → SMTP |
| `BREVO_SMTP_USER` | Brevo Login E-Mail (alex@alexstuder.ch) |
| `BREVO_SMTP_API_KEY` | Brevo → SMTP & API → API Keys |
| `BACKUP_GPG_PASSWORD` | In Bitwarden — wird automatisch geholt |
| `CF_R2_ACCESS_KEY` | Cloudflare → R2 → Manage API Tokens |
| `CF_R2_SECRET_KEY` | Cloudflare → R2 → Manage API Tokens |
| `CF_R2_BUCKET` | `ugly-vps-backup` |
| `CF_R2_ENDPOINT` | `https://<account-id>.r2.cloudflarestorage.com` |

### Vorbereitung .env

Die `.env` liegt verschlüsselt als `.env.gpg` im GitHub Repo.
`BACKUP_GPG_PASSWORD` liegt in **Bitwarden** — wird beim bootstrap automatisch geholt.

**bootstrap.sh fragt nur nach:**
1. Bitwarden E-Mail
2. Bitwarden Master-Passwort

Alles andere kommt automatisch aus der entschlüsselten `.env.gpg`.

### Installation starten
```bash
# Als root auf dem frischen VPS einloggen
ssh root@deine-vps-ip

# Script herunterladen
curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh \
  -o bootstrap.sh
chmod +x bootstrap.sh

# Installation starten
./bootstrap.sh
```

Das Script fragt nach:
1. Bitwarden E-Mail
2. Bitwarden Master-Passwort
3. Passwort für User `alex`

Alles andere kommt automatisch aus der verschlüsselten `.env.gpg`.

### Nach der Installation prüfen
```bash
# Als alex einloggen
ssh alex@deine-vps-ip

# Stack-Status prüfen
cd ~/ugly-stack
docker compose ps

# Logs prüfen
docker compose logs --tail=50

# Jeden Service einzeln prüfen
docker compose logs ugly-agent --tail=20
docker compose logs n8n --tail=20
docker compose logs searxng --tail=20
docker compose logs nginx --tail=20
```

---

## 2. Tokens und API Keys verwalten

### Secret aktualisieren (empfohlener Weg)
Das `set-secret.sh` Script aktualisiert `.env` UND Cloudflare Secrets Store gleichzeitig:

```bash
cd ~/ugly-stack

# Mit Argumenten
./set-secret.sh TELEGRAM_BOT_TOKEN "123456:ABC-DEF..."

# Nur Name, Wert wird abgefragt (unsichtbar)
./set-secret.sh OPENROUTER_API_KEY

# Interaktiv — zeigt alle Secrets zur Auswahl
./set-secret.sh
```

Das Script fragt automatisch ob der betroffene Container neu gestartet werden soll.

### Secret manuell in .env setzen
```bash
nano ~/ugly-stack/.env

# Nach Änderung den Container neu starten
cd ~/ugly-stack
docker compose up -d --force-recreate ugly-agent
```

### Welcher Container braucht welchen Key?

| Secret | Container |
|--------|-----------|
| TELEGRAM_BOT_TOKEN | ugly-agent |
| OPENROUTER_API_KEY | ugly-agent |
| OPENCLAW_GATEWAY_TOKEN | ugly-agent |
| N8N_* | n8n |
| CLOUDFLARE_TUNNEL_TOKEN | cloudflared |
| ZOHO_SMTP_* | n8n |
| BREVO_SMTP_* | n8n |

### Token erneuern — Schritt für Schritt
1. Neuen Token beim Anbieter generieren
2. `./set-secret.sh SECRET_NAME "neuer-wert"` ausführen
3. Container neu starten wenn das Script fragt
4. Funktion testen (z.B. Telegram-Nachricht senden)
5. Backup machen: `./backup/backup-master.sh`

---

## 3. Stack verwalten

```bash
cd ~/ugly-stack

# Status aller Container
docker compose ps

# Alle Container neu starten
docker compose restart

# Einen Container neu starten
docker compose restart ugly-agent

# Stack stoppen
docker compose down

# Stack starten
docker compose up -d

# Images updaten + neu starten
docker compose pull && docker compose up -d

# Einen Container mit neuer .env neu starten
docker compose up -d --force-recreate ugly-agent

# Logs live
docker compose logs -f

# Logs eines einzelnen Containers
docker compose logs ugly-agent -f --tail=100
```

---

## 4. Container-Zugriff

### OpenClaw (Ugly)
```bash
# Shell im Container
docker exec -it ugly-agent bash

# Wichtige Dateien direkt editieren (via Volume — kein Container nötig)
nano ~/ugly-stack/openclaw-data/MEMORY.md
nano ~/ugly-stack/openclaw-data/AGENTS.md
nano ~/ugly-stack/openclaw-data/USER.md
nano ~/ugly-stack/openclaw-data/SOUL.md

# Nach Änderungen Container neu starten
docker compose restart ugly-agent
```

### n8n
```bash
docker exec -it n8n sh
```

### SearXNG
```bash
docker exec -it searxng sh
```

### nginx
```bash
docker exec -it nginx sh

# Config testen
docker exec nginx nginx -t

# Config neu laden (ohne Neustart)
docker exec nginx nginx -s reload
```

---

## 5. Backup

### Automatisches Backup
Läuft täglich um 03:00 Uhr via Cron.
Ziel: Cloudflare R2 → verschlüsselt mit GPG AES256.
Letzte 7 Backups werden behalten.

### Manuelles Backup auslösen
```bash
~/ugly-stack/backup/backup-master.sh
```

### Backup-Log prüfen
```bash
tail -f ~/ugly-stack/backup/backup.log
```

### Was wird gesichert?

| Modul | Was | Wie |
|-------|-----|-----|
| openclaw | Komplettes ~/.openclaw (State, Workspace, Credentials, Telegram-Session, Skills) | `openclaw backup create --verify` |
| n8n | Workflows + Credentials als JSON | `n8n export` |
| nginx | Konfigurationsdateien | Direktkopie |
| www | Webseiten-Dateien | Direktkopie |

### Backup nach wichtigen Änderungen
Nach diesen Ereignissen immer manuell ein Backup auslösen:
- Neuer Token / API Key eingetragen
- n8n Workflow erstellt oder geändert
- OpenClaw MEMORY.md / AGENTS.md bearbeitet
- Neuer Container hinzugefügt

---

## 6. Restore

### Verfügbare Backups anzeigen
```bash
~/ugly-stack/backup/restore/restore-master.sh list
```

### Alles wiederherstellen
```bash
~/ugly-stack/backup/restore/restore-master.sh
# → zeigt Backup-Liste zur Auswahl
# → stoppt Stack
# → stellt alle Daten wieder her
# → startet Stack
```

### Einzelnen Service wiederherstellen
```bash
# Nur OpenClaw
~/ugly-stack/backup/restore/restore-master.sh openclaw

# Nur n8n
~/ugly-stack/backup/restore/restore-master.sh n8n

# Nur nginx
~/ugly-stack/backup/restore/restore-master.sh nginx

# Nur Webseite
~/ugly-stack/backup/restore/restore-master.sh www
```

### Nach OpenClaw-Restore
Falls Telegram neu authentifiziert werden muss:
```bash
docker exec -it ugly-agent openclaw gateway --setup
```

---

## 7. Neue Container hinzufügen

### docker-compose.yml erweitern
```bash
nano ~/ugly-stack/docker-compose.yml
# Neuen Service hinzufügen
# Ins ugly-net Netzwerk einhängen
```

### nginx Reverse Proxy konfigurieren
```bash
nano ~/ugly-stack/nginx/conf.d/default.conf
# Neuen server-Block hinzufügen
docker exec nginx nginx -s reload
```

### Cloudflare Tunnel Route hinzufügen
- Cloudflare Dashboard → Zero Trust → Tunnels → beautymoltTunnel → Edit
- Neue Route: `neuerservice.beautymolt.com` → `http://nginx:80`

### Backup-Modul erstellen
Siehe `backup/NEUES_MODUL.md` für die vollständige Anleitung.

### Secret hinzufügen
```bash
./set-secret.sh NEUER_SERVICE_API_KEY "wert"
```

---

## 8. Troubleshooting

### Container startet nicht
```bash
docker compose logs CONTAINER_NAME --tail=50
docker compose up -d --force-recreate CONTAINER_NAME
```

### .env Wert falsch
```bash
./set-secret.sh SECRET_NAME "korrekter-wert"
docker compose up -d --force-recreate CONTAINER_NAME
```

### Backup schlägt fehl
```bash
# Log prüfen
tail -20 ~/ugly-stack/backup/backup.log

# R2 Verbindung testen
rclone ls r2:$CF_R2_BUCKET --config ~/ugly-stack/rclone/rclone.conf

# Manuell testen
STAGING=/tmp/test-staging STACK_DIR=~/ugly-stack \
  bash ~/ugly-stack/backup/modules/openclaw.sh
```

### Telegram funktioniert nicht
```bash
# Token prüfen
grep TELEGRAM_BOT_TOKEN ~/ugly-stack/.env

# Neu setzen
./set-secret.sh TELEGRAM_BOT_TOKEN "neuer-token"

# Gateway neu einrichten
docker exec -it ugly-agent openclaw gateway --setup
```

### Stack komplett neu aufsetzen (Neuinstallation)
```bash
# Auf dem alten VPS (falls noch erreichbar):
~/ugly-stack/backup/backup-master.sh

# Auf dem neuen VPS:
curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh \
  -o bootstrap.sh
chmod +x bootstrap.sh
./bootstrap.sh
# → holt automatisch Secrets aus Cloudflare
# → stellt neuestes Backup von R2 wieder her
```

---

## Dateistruktur

```
~/ugly-stack/
├── .env                          ← Alle Secrets (nie ins Git!)
├── docker-compose.yml            ← Stack-Definition
├── set-secret.sh                 ← Secret aktualisieren
├── nginx/
│   └── conf.d/
│       └── default.conf          ← Reverse Proxy Konfiguration
├── openclaw-data/                ← OpenClaw Volume (automatisch gesichert)
├── n8n-data/                     ← n8n Volume
├── searxng-data/                 ← SearXNG Volume
├── www/                          ← Webseiten-Dateien
├── rclone/
│   └── rclone.conf               ← R2 Konfiguration
└── backup/
    ├── backup-master.sh          ← Alle Module + Upload zu R2
    ├── backup.log                ← Backup-Protokoll
    ├── NEUES_MODUL.md            ← Anleitung neuer Container
    ├── modules/                  ← Backup-Module
    │   ├── openclaw.sh
    │   ├── n8n.sh
    │   ├── nginx.sh
    │   └── www.sh
    └── restore/
        ├── restore-master.sh     ← Restore einzeln oder komplett
        └── modules/
            ├── openclaw.sh
            ├── n8n.sh
            ├── nginx.sh
            └── www.sh
```

---

## Migration — Alter VPS → Neuer VPS

### Reihenfolge einhalten — kein Ausfall wenn korrekt durchgeführt!

### Schritt 1 — Backups auf altem VPS aktualisieren

```bash
# Manuelles Backup auslösen
~/ugly-stack/backup/backup-master.sh

# www Backup zu R2
~/backup-www.sh

# Prüfen ob alles in R2 ist
rclone ls r2:ugly-vps-backup/ --config ~/.config/rclone/rclone.conf
```

### Schritt 2 — Neuen VPS aufsetzen

```bash
# Als root auf dem neuen VPS
curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh \
  -o bootstrap.sh
chmod +x bootstrap.sh
./bootstrap.sh
```

Fragt nur nach:
1. Bitwarden E-Mail
2. Bitwarden Master-Passwort

### Schritt 3 — Services auf neuem VPS prüfen

```bash
cd ~/ugly-stack
docker compose ps
docker compose logs --tail=30
```

### Schritt 4 — Cloudflare Tunnel Routes anpassen

**Erst machen wenn der neue VPS läuft!**

Cloudflare Dashboard → Zero Trust → Networks → Tunnels → beautymoltTunnel → Edit → Routes

Alle Routes auf `http://localhost:80` ändern:

| Subdomain | Alt | Neu |
|-----------|-----|-----|
| `claw.beautymolt.com` | `http://localhost:48116` | `http://localhost:80` |
| `www.beautymolt.com` | `http://localhost:80` | bleibt gleich ✓ |
| `search.beautymolt.com` | `http://localhost:8888` | `http://localhost:80` |
| `n8n.beautymolt.com` | `http://localhost:5678` | `http://localhost:80` |
| `mail.beautymolt.com` | `http://localhost:8080` | `http://localhost:80` |
| `dashboard.beautymolt.com` | löschen | — |

### Schritt 5 — OpenClaw Onboarding

```bash
docker exec -it ugly-agent bash
openclaw onboard
openclaw gateway start
```

### Schritt 6 — Services testen

```bash
curl -s -o /dev/null -w "%{http_code}" https://www.beautymolt.com
curl -s -o /dev/null -w "%{http_code}" https://search.beautymolt.com
curl -s -o /dev/null -w "%{http_code}" https://n8n.beautymolt.com
curl -s -o /dev/null -w "%{http_code}" https://claw.beautymolt.com
```

Alle sollten `200` zurückgeben.

### Schritt 7 — Alten VPS herunterfahren

Erst wenn alles funktioniert:

```bash
# Auf dem alten VPS
sudo poweroff
```

Dann alten VPS bei Hostinger löschen.

### Troubleshooting

```bash
# Tunnel verbindet sich nicht
docker compose logs cloudflared

# nginx Problem
docker exec nginx nginx -t
docker compose restart nginx

# n8n Credentials fehlen
docker compose exec n8n n8n import:credentials \
  --input=/home/node/.n8n/credentials-backup.json

# OpenClaw antwortet nicht auf Telegram
docker exec -it ugly-agent openclaw gateway --setup
```
