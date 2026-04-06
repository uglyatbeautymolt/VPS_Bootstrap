# Migration — Alter VPS → Neuer VPS

## Reihenfolge einhalten!

Die Migration muss in dieser Reihenfolge erfolgen damit keine Ausfallzeit entsteht.

---

## Schritt 1 — Vorbereitung auf dem alten VPS

Sicherstellen dass alle Backups aktuell sind:

```bash
# Manuelles Backup auslösen
~/ugly-stack/backup/backup-master.sh

# n8n Backup zu R2
~/backup-n8n.sh   # falls vorhanden

# www Backup zu R2
~/backup-www.sh

# Prüfen ob alles in R2 ist
rclone ls r2:ugly-vps-backup/ --config ~/.config/rclone/rclone.conf
```

---

## Schritt 2 — Neuen VPS aufsetzen

```bash
# Als root auf dem neuen VPS
curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh \
  -o bootstrap.sh
chmod +x bootstrap.sh
./bootstrap.sh
```

Das Script fragt nach:
1. Bitwarden E-Mail
2. Bitwarden Master-Passwort

Alles andere läuft automatisch.

---

## Schritt 3 — Services prüfen (noch über alte IP)

```bash
# Auf dem neuen VPS
cd ~/ugly-stack
docker compose ps

# Logs prüfen
docker compose logs --tail=30
```

---

## Schritt 4 — Cloudflare Tunnel Routes anpassen

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

---

## Schritt 5 — Cloudflare Tunnel Token

Der Tunnel Token muss auf den neuen VPS zeigen.

**Option A — Bestehenden Token weiterverwenden:**
Der Token ist bereits in der `.env` — der Tunnel verbindet sich automatisch zum neuen VPS sobald `cloudflared` Container läuft.

**Option B — Token rotieren (empfohlen):**
- beautymoltTunnel → Rotate token
- Neuen Token in Bitwarden aktualisieren
- `.env.gpg` neu verschlüsseln und zu GitHub pushen:

```bash
cd ~/ugly-stack
./set-secret.sh CLOUDFLARE_TUNNEL_TOKEN "neuer-token"
```

---

## Schritt 6 — OpenClaw Onboarding

Da OpenClaw neu konfiguriert wird:

```bash
# In den Container
docker exec -it ugly-agent bash

# Onboarding starten
openclaw onboard

# Gateway starten
openclaw gateway start
```

Telegram Bot Token ist bereits in der `.env` — derselbe Bot funktioniert weiter.

---

## Schritt 7 — Services testen

```bash
# Alle Subdomains testen
curl -s -o /dev/null -w "%{http_code}" https://www.beautymolt.com
curl -s -o /dev/null -w "%{http_code}" https://search.beautymolt.com
curl -s -o /dev/null -w "%{http_code}" https://n8n.beautymolt.com
curl -s -o /dev/null -w "%{http_code}" https://claw.beautymolt.com
```

Alle sollten `200` oder `301` zurückgeben.

---

## Schritt 8 — Alten VPS herunterfahren

Erst wenn alle Services auf dem neuen VPS funktionieren:

```bash
# Auf dem alten VPS
docker compose down  # oder
sudo poweroff
```

Dann alten VPS bei Hostinger kündigen/löschen.

---

## Troubleshooting

**Tunnel verbindet sich nicht:**
```bash
docker compose logs cloudflared
```

**nginx zeigt falschen Inhalt:**
```bash
docker exec nginx nginx -t
docker compose restart nginx
```

**n8n Credentials fehlen:**
```bash
docker compose exec n8n n8n import:credentials \
  --input=/home/node/.n8n/credentials-backup.json
```

**OpenClaw antwortet nicht auf Telegram:**
```bash
docker exec -it ugly-agent openclaw gateway --setup
```
