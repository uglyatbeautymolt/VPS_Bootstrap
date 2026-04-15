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
9. [VPS wechseln oder neu aufsetzen](#9-vps-wechseln-oder-neu-aufsetzen)

---

## 1. Erste Installation

### Secrets — Übersicht

Die `.env` liegt verschlüsselt als `.env.gpg` im Repo. `BACKUP_GPG_PASSWORD` und `GITHUB_TOKEN` werden beim bootstrap automatisch aus **Bitwarden** geholt.

**Wichtig:** `PORTAINER_ADMIN_PASSWORD` muss in `.env` vorhanden sein — bootstrap bricht sonst mit Fehlermeldung ab. Kein Fallback.

| Secret | Wo finden |
|--------|----------|
| `CLOUDFLARE_TUNNEL_TOKEN` | Cloudflare → Zero Trust → Tunnels → beautymoltTunnel |
| `OPENROUTER_API_KEY` | openrouter.ai → Keys |
| `TELEGRAM_BOT_TOKEN` | @BotFather auf Telegram — bestehenden weiterverwenden |
| `OPENCLAW_GATEWAY_TOKEN` | Selbst wählen — bestehenden beibehalten |
| `N8N_BASIC_AUTH_USER` | Selbst wählen |
| `N8N_BASIC_AUTH_PASSWORD` | Selbst wählen |
| `N8N_ENCRYPTION_KEY` | `openssl rand -hex 16` — **bestehenden beibehalten!** |
| `ZOHO_SMTP_USER` | Zoho Mail Login E-Mail |
| `ZOHO_SMTP_PASSWORD` | Zoho Mail → Einstellungen → SMTP |
| `BREVO_SMTP_USER` | `a50340001@smtp-brevo.com` |
| `BREVO_SMTP_API_KEY` | Brevo → SMTP & API → API Keys (xsmtpsib-...) |
| `BREVO_KEY` | Brevo → SMTP & API → API Keys (xkeysib-...) |
| `PORTAINER_ADMIN_PASSWORD` | Selbst wählen — Portainer Admin-Login |
| `BACKUP_GPG_PASSWORD` | Bitwarden — wird automatisch geholt |
| `CF_R2_ACCESS_KEY` | Cloudflare → R2 → Manage API Tokens |
| `CF_R2_SECRET_KEY` | Cloudflare → R2 → Manage API Tokens |
| `CF_R2_BUCKET` | Name des R2 Buckets |
| `CF_R2_ENDPOINT` | `https://<account-id>.r2.cloudflarestorage.com` |

### Installation

```bash
ssh root@deine-vps-ip
curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh \
  -o bootstrap.sh
chmod +x bootstrap.sh
./bootstrap.sh
```

Das Script fragt nach Bitwarden E-Mail, Master-Passwort und Passwort für User `alex`. Alles andere ist automatisch.

### Nach der Installation prüfen

```bash
ssh alex@deine-vps-ip
cd ~/ugly-stack
docker compose ps
docker compose logs --tail=50
```

---

## 2. Tokens und API Keys verwalten

```bash
cd ~/ugly-stack

# Empfohlen: aktualisiert .env + Cloudflare Secrets Store
bash set-secret.sh TELEGRAM_BOT_TOKEN "123456:ABC..."
bash set-secret.sh OPENROUTER_API_KEY   # Wert wird unsichtbar abgefragt
bash set-secret.sh                      # interaktiv
```

Das Script fragt ob der betroffene Container neu gestartet werden soll.

### Welcher Container braucht welchen Key?

| Secret | Container |
|--------|----------|
| TELEGRAM_BOT_TOKEN | openclaw |
| OPENROUTER_API_KEY | openclaw |
| OPENCLAW_GATEWAY_TOKEN | openclaw |
| BREVO_KEY | openclaw |
| N8N_* | n8n |
| CLOUDFLARE_TUNNEL_TOKEN | cloudflared |
| ZOHO_SMTP_* | n8n |
| BREVO_SMTP_* | n8n |
| PORTAINER_ADMIN_PASSWORD | bootstrap (einmalig) |

---

## 3. Stack verwalten

```bash
cd ~/ugly-stack

docker compose ps
docker compose restart
docker compose restart openclaw
docker compose down
docker compose up -d
docker compose pull && docker compose up -d
docker compose up -d --force-recreate openclaw
docker compose logs -f
docker compose logs openclaw -f --tail=100
```

---

## 4. Container-Zugriff

```bash
# OpenClaw
docker exec -it openclaw bash
nano ~/ugly-stack/openclaw-data/MEMORY.md
nano ~/ugly-stack/openclaw-data/AGENTS.md
docker compose restart openclaw

# n8n
docker exec -it n8n sh

# nginx
docker exec nginx nginx -t
docker exec nginx nginx -s reload
```

---

## 5. Backup

Läuft täglich 02:00 UTC via Cron. Checksummen-basiert — nur geänderte Module werden gesichert. Sonntags immer WEEKLY-Backup.

```bash
# Manuell auslösen
bash ~/ugly-stack/backup/backup-master.sh

# Log prüfen
tail -f ~/ugly-stack/backup/backup.log
```

| Modul | Was |
|-------|-----|
| openclaw | komplettes openclaw-data Volume (tar.gz) |
| n8n | Workflows + Credentials (JSON-Export) |
| nginx | Konfigurationsdateien |
| www | Webseiten-Dateien |
| portainer | portainer-data Volume |

**Manuelles Backup empfohlen nach:** Token-Änderungen, n8n Workflow-Änderungen, openclaw MEMORY.md / AGENTS.md bearbeitet.

---

## 6. Restore

```bash
# Verfügbare Backups anzeigen
bash ~/ugly-stack/backup/restore/restore-master.sh list

# Alles wiederherstellen (interaktiv)
bash ~/ugly-stack/backup/restore/restore-master.sh

# Einzelnen Service
bash ~/ugly-stack/backup/restore/restore-master.sh openclaw
bash ~/ugly-stack/backup/restore/restore-master.sh n8n
```

---

## 7. Neue Container hinzufügen

1. Service in `docker-compose.yml` ergänzen → ins `ugly-net` Netzwerk einhängen
2. nginx-Block in `nginx/conf.d/default.conf` ergänzen → `docker exec nginx nginx -s reload`
3. Cloudflare Tunnel Route: Dashboard → Zero Trust → beautymoltTunnel → neue Route `neuerservice.beautymolt.com` → `http://nginx:80`
4. Backup-Modul: siehe **[backup/NEUES_MODUL.md](./backup/NEUES_MODUL.md)**
5. Secret: `bash set-secret.sh NEUER_SERVICE_KEY "wert"`

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
tail -20 ~/ugly-stack/backup/backup.log
rclone ls r2:$CF_R2_BUCKET --config ~/ugly-stack/rclone/rclone.conf
```

### Telegram funktioniert nicht
```bash
grep TELEGRAM_BOT_TOKEN ~/ugly-stack/.env
bash set-secret.sh TELEGRAM_BOT_TOKEN "neuer-token"
```

### Volume-Ownership falsch (nach unerwartetem Watchtower-Verhalten)
```bash
# Normalerweise nicht nötig — bootstrap.sh und docker-compose.yml (user: 1000:1000)
# verhindern das automatisch. Nur als letztes Mittel:
sudo chown -R 1000:$(id -g) ~/ugly-stack/openclaw-data ~/ugly-stack/n8n-data
sudo chmod -R g+rX ~/ugly-stack/openclaw-data ~/ugly-stack/n8n-data
```

### Portainer-Passwort unbekannt
```bash
# Passwort aus .env lesen
grep PORTAINER_ADMIN_PASSWORD ~/ugly-stack/.env

# Portainer zurücksetzen (löscht alle Portainer-Daten)
docker compose stop portainer
sudo rm -rf /var/lib/docker/volumes/ugly-stack_portainer-data/_data
docker compose up -d portainer
# bootstrap-Logik manuell nachholen:
PORTAINER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' portainer)
source ~/ugly-stack/.env
curl -s -X POST "http://${PORTAINER_IP}:9000/api/users/admin/init" \
  -H "Content-Type: application/json" \
  -d "{\"Username\":\"admin\",\"Password\":\"${PORTAINER_ADMIN_PASSWORD}\"}" | jq .
```

---

## 9. VPS wechseln oder neu aufsetzen

Der Stack ist hosterunabhängig konzipiert. Alle Secrets liegen in `.env.gpg` (GitHub), alle Daten in Cloudflare R2, DNS und Tunnel in Cloudflare. Ein Hoster-Wechsel — z.B. von Hostinger zu Hetzner — erfordert nur 4 Schritte.

### Schritt 1 — Backup auf altem VPS
```bash
bash ~/ugly-stack/backup/backup-master.sh
rclone ls r2:$CF_R2_BUCKET/backups/ --config ~/ugly-stack/rclone/rclone.conf
```

### Schritt 2 — Neuen VPS aufsetzen
```bash
curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh \
  -o bootstrap.sh
chmod +x bootstrap.sh
./bootstrap.sh
```

### Schritt 3 — Prüfen
```bash
cd ~/ugly-stack
docker compose ps
docker compose logs --tail=30
```

### Schritt 4 — Cloudflare Tunnel-Route auf neuen VPS umstellen

**Erst wenn der neue VPS läuft!** Dashboard → Zero Trust → Networks → Tunnels → beautymoltTunnel → Edit → Routes

| Subdomain | Service |
|-----------|--------|
| `claw.beautymolt.com` | `http://nginx:80` |
| `www.beautymolt.com` | `http://nginx:80` |
| `search.beautymolt.com` | `http://nginx:80` |
| `n8n.beautymolt.com` | `http://nginx:80` |
| `mail.beautymolt.com` | `http://nginx:80` |
| `portainer.beautymolt.com` | `http://nginx:80` |

### Schritt 5 — Testen
```bash
curl -s -o /dev/null -w "%{http_code}" https://www.beautymolt.com
curl -s -o /dev/null -w "%{http_code}" https://claw.beautymolt.com
curl -s -o /dev/null -w "%{http_code}" https://n8n.beautymolt.com
```

### Schritt 6 — Alten VPS abschalten
```bash
sudo poweroff
```
Dann beim Hoster löschen.
