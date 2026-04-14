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

### Voraussetzungen — Secrets

Folgende Secrets müssen in der **`.env`** hinterlegt sein (verschlüsselt als `.env.gpg` im Repo).
`BACKUP_GPG_PASSWORD` liegt in **Bitwarden** — wird beim bootstrap automatisch geholt.

| Secret | Beschreibung | Wo finden |
|--------|-------------|----------|
| `CLOUDFLARE_TUNNEL_TOKEN` | Tunnel Token | Cloudflare → Zero Trust → Tunnels → beautymoltTunnel |
| `OPENROUTER_API_KEY` | OpenRouter API Key | openrouter.ai → Keys |
| `TELEGRAM_BOT_TOKEN` | Telegram Bot Token | @BotFather auf Telegram — bestehenden weiterverwenden |
| `OPENCLAW_GATEWAY_TOKEN` | OpenClaw Gateway Token | Selbst wählen — bestehenden weiterverwenden |
| `N8N_BASIC_AUTH_USER` | n8n Benutzername | Selbst wählen |
| `N8N_BASIC_AUTH_PASSWORD` | n8n Passwort | Selbst wählen |
| `N8N_ENCRYPTION_KEY` | n8n Encryption Key (32 Zeichen) | `openssl rand -hex 16` — **bestehenden beibehalten!** |
| `ZOHO_SMTP_USER` | Zoho Mail Login E-Mail | Zoho Mail Login |
| `ZOHO_SMTP_PASSWORD` | Zoho SMTP Passwort | Zoho Mail → Einstellungen → SMTP |
| `BREVO_SMTP_USER` | Brevo SMTP Login | `a50340001@smtp-brevo.com` |
| `BREVO_SMTP_API_KEY` | Brevo SMTP API Key (xsmtpsib-...) | Brevo → SMTP & API → API Keys |
| `BREVO_KEY` | Brevo REST API Key (xkeysib-...) | Brevo → SMTP & API → API Keys |
| `BACKUP_GPG_PASSWORD` | Passwort für Backup-Verschlüsselung | In Bitwarden — wird automatisch geholt |
| `CF_R2_ACCESS_KEY` | R2 Access Key | Cloudflare → R2 → Manage API Tokens |
| `CF_R2_SECRET_KEY` | R2 Secret Key | Cloudflare → R2 → Manage API Tokens |
| `CF_R2_BUCKET` | R2 Bucket Name | Name deines R2 Buckets |
| `CF_R2_ENDPOINT` | R2 Endpoint URL | `https://<account-id>.r2.cloudflarestorage.com` |

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
docker compose logs openclaw --tail=20
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
bash set-secret.sh TELEGRAM_BOT_TOKEN "123456:ABC-DEF..."

# Nur Name, Wert wird abgefragt (unsichtbar)
bash set-secret.sh OPENROUTER_API_KEY

# Interaktiv — zeigt alle Secrets zur Auswahl
bash set-secret.sh
```

Das Script fragt automatisch ob der betroffene Container neu gestartet werden soll.

### Secret manuell in .env setzen
```bash
nano ~/ugly-stack/.env

# Nach Änderung den Container neu starten
cd ~/ugly-stack
docker compose up -d --force-recreate openclaw
```

### Welcher Container braucht welchen Key?

| Secret | Container |
|--------|-----------|
| TELEGRAM_BOT_TOKEN | openclaw |
| OPENROUTER_API_KEY | openclaw |
| OPENCLAW_GATEWAY_TOKEN | openclaw |
| BREVO_KEY | openclaw |
| N8N_* | n8n |
| CLOUDFLARE_TUNNEL_TOKEN | cloudflared |
| ZOHO_SMTP_* | n8n |
| BREVO_SMTP_* | n8n |

### Token erneuern — Schritt für Schritt
1. Neuen Token beim Anbieter generieren
2. `bash set-secret.sh SECRET_NAME "neuer-wert"` ausführen
3. Container neu starten wenn das Script fragt
4. Funktion testen (z.B. Telegram-Nachricht senden)
5. Backup machen: `bash backup/backup-master.sh`

---

## 3. Stack verwalten

```bash
cd ~/ugly-stack

# Status aller Container
docker compose ps

# Alle Container neu starten
docker compose restart

# Einen Container neu starten
docker compose restart openclaw

# Stack stoppen
docker compose down

# Stack starten
docker compose up -d

# Images updaten + neu starten
docker compose pull && docker compose up -d

# Einen Container mit neuer .env neu starten
docker compose up -d --force-recreate openclaw

# Logs live
docker compose logs -f

# Logs eines einzelnen Containers
docker compose logs openclaw -f --tail=100
```

---

## 4. Container-Zugriff

### OpenClaw (Ugly)
```bash
# Shell im Container
docker exec -it openclaw bash

# Wichtige Dateien direkt editieren (via Volume — kein Container nötig)
nano ~/ugly-stack/openclaw-data/MEMORY.md
nano ~/ugly-stack/openclaw-data/AGENTS.md
nano ~/ugly-stack/openclaw-data/USER.md
nano ~/ugly-stack/openclaw-data/SOUL.md

# Nach Änderungen Container neu starten
docker compose restart openclaw
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
Läuft täglich um 02:00 UTC via Cron.
Ziel: Cloudflare R2 → verschlüsselt mit GPG AES256.
7 normale + 4 WEEKLY Backups werden behalten.

### Manuelles Backup auslösen
```bash
bash ~/ugly-stack/backup/backup-master.sh
```

### Backup-Log prüfen
```bash
tail -f ~/ugly-stack/backup/backup.log
```

### Was wird gesichert?

| Modul | Was | Wie |
|-------|-----|-----|
| openclaw | Komplettes openclaw-data Volume (State, Memory, Skills, Credentials) | tar.gz |
| n8n | Workflows + Credentials als JSON | `n8n export` |
| nginx | Konfigurationsdateien | Direktkopie |
| www | Webseiten-Dateien | Direktkopie |
| portainer | portainer-data Volume | tar.gz |

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
bash ~/ugly-stack/backup/restore/restore-master.sh list
```

### Alles wiederherstellen
```bash
bash ~/ugly-stack/backup/restore/restore-master.sh
# → zeigt Backup-Liste zur Auswahl
# → stoppt Stack
# → stellt alle Daten wieder her
# → startet Stack
```

### Einzelnen Service wiederherstellen
```bash
# Nur OpenClaw
bash ~/ugly-stack/backup/restore/restore-master.sh openclaw

# Nur n8n
bash ~/ugly-stack/backup/restore/restore-master.sh n8n

# Nur nginx
bash ~/ugly-stack/backup/restore/restore-master.sh nginx

# Nur Webseite
bash ~/ugly-stack/backup/restore/restore-master.sh www
```

### Nach OpenClaw-Restore
Falls Telegram neu authentifiziert werden muss:
```bash
docker exec -it openclaw openclaw gateway --setup
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
bash set-secret.sh NEUER_SERVICE_API_KEY "wert"
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
bash set-secret.sh SECRET_NAME "korrekter-wert"
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
bash set-secret.sh TELEGRAM_BOT_TOKEN "neuer-token"
```

### Stack komplett neu aufsetzen (Neuinstallation)
```bash
# Auf dem alten VPS (falls noch erreichbar):
bash ~/ugly-stack/backup/backup-master.sh

# Auf dem neuen VPS:
curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh \
  -o bootstrap.sh
chmod +x bootstrap.sh
./bootstrap.sh
# → holt automatisch Secrets aus Bitwarden
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
    ├── .checksums                ← Checksummen (gitignored)
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
bash ~/ugly-stack/backup/backup-master.sh

# Prüfen ob alles in R2 ist
rclone ls r2:$CF_R2_BUCKET/backups/ --config ~/ugly-stack/rclone/rclone.conf
```

### Schritt 2 — Neuen VPS aufsetzen

```bash
# Als root auf dem neuen VPS
curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh \
  -o bootstrap.sh
chmod +x bootstrap.sh
./bootstrap.sh
```

### Schritt 3 — Services auf neuem VPS prüfen

```bash
cd ~/ugly-stack
docker compose ps
docker compose logs --tail=30
```

### Schritt 4 — Cloudflare Tunnel Routes anpassen

**Erst machen wenn der neue VPS läuft!**

Cloudflare Dashboard → Zero Trust → Networks → Tunnels → beautymoltTunnel → Edit → Routes

| Subdomain | Service |
|-----------|---------|
| `claw.beautymolt.com` | `http://nginx:80` |
| `www.beautymolt.com` | `http://nginx:80` |
| `search.beautymolt.com` | `http://nginx:80` |
| `n8n.beautymolt.com` | `http://nginx:80` |
| `mail.beautymolt.com` | `http://nginx:80` |
| `portainer.beautymolt.com` | `http://nginx:80` |

### Schritt 5 — Services testen

```bash
curl -s -o /dev/null -w "%{http_code}" https://www.beautymolt.com
curl -s -o /dev/null -w "%{http_code}" https://search.beautymolt.com
curl -s -o /dev/null -w "%{http_code}" https://n8n.beautymolt.com
curl -s -o /dev/null -w "%{http_code}" https://claw.beautymolt.com
```

Alle sollten `200` zurückgeben.

### Schritt 6 — Alten VPS herunterfahren

Erst wenn alles funktioniert:

```bash
# Auf dem alten VPS
sudo poweroff
```

Dann alten VPS bei Hostinger löschen.
