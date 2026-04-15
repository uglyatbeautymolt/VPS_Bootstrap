# Ugly Stack

> Persönlicher KI-Agent "Ugly" auf einem selbst gehosteten VPS — vollständig automatisiert, verschlüsselt gesichert und auf jedem Ubuntu 24.04 VPS in wenigen Minuten wiederherstellbar.

Der Stack ist hosterunabhängig: Secrets liegen verschlüsselt in GitHub, Daten in Cloudflare R2, DNS und Tunnel in Cloudflare. Ein Wechsel von Hostinger zu Hetzner oder einem anderen Anbieter erfordert nur `bootstrap.sh` auf dem neuen VPS ausführen — der Rest ist automatisch.

## Schnellstart — Neuinstallation

```bash
# Als root auf frischem Ubuntu 24.04 VPS
curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh \
  -o bootstrap.sh
chmod +x bootstrap.sh
./bootstrap.sh
```

Das Script fragt nur nach:
1. Bitwarden E-Mail
2. Bitwarden Master-Passwort
3. Passwort für User `alex`

Alles andere kommt automatisch aus der verschlüsselten `.env.gpg` im Repo.
Neuestes Backup wird automatisch von Cloudflare R2 wiederhergestellt.

→ Detaillierte Installationsanleitung und Secrets-Übersicht: **[BETRIEB.md](./BETRIEB.md)**

---

![Ugly Stack Architektur](./architecture.svg)

## Services

| URL | Service |
|-----|-------|
| [claw.beautymolt.com](https://claw.beautymolt.com) | OpenClaw (Ugly) |
| [search.beautymolt.com](https://search.beautymolt.com) | SearXNG |
| [n8n.beautymolt.com](https://n8n.beautymolt.com) | n8n |
| [www.beautymolt.com](https://www.beautymolt.com) | nginx Webserver |
| [mail.beautymolt.com](https://mail.beautymolt.com) | Roundcube |
| [portainer.beautymolt.com](https://portainer.beautymolt.com) | Portainer |

## Externe Services

| Service | Link | Zweck |
|---------|------|-------|
| Cloudflare | [dash.cloudflare.com](https://dash.cloudflare.com) | DNS, Tunnel, R2 Backups, Secrets Store |
| Bitwarden | [vault.bitwarden.com](https://vault.bitwarden.com) | BACKUP_GPG_PASSWORD, GITHUB_TOKEN |
| Brevo | [app.brevo.com](https://app.brevo.com) | E-Mail-Versand (SMTP + API) |
| Zoho Mail | [mail.zoho.eu](https://mail.zoho.eu) | E-Mail-Empfang (ugly@beautymolt.com) |

## Docker Netzwerk

Alle Container laufen im internen Bridge-Netzwerk **`ugly-net`**. Nach aussen ist kein Port offen — einziger Eingang ist der Cloudflare Tunnel.

| Container | Port | User (UID) | Notes |
|-----------|------|------------|-------|
| cloudflared | — | 65532:65532 | Tunnel-Eingang |
| nginx | 80 | root | Reverse Proxy |
| openclaw | 18789 | node (1000:1000) | `user:` explizit gesetzt |
| searxng | 8080 | 977 | |
| n8n | 5678 | node (1000:1000) | `user:` explizit gesetzt |
| roundcube | 80 | www-data | |
| portainer | 9000 | root | Login: admin / siehe `.env` |
| watchtower | — | root | Socket-Zugriff nötig |

> `user: "1000:1000"` ist bei openclaw und n8n explizit gesetzt. Das verhindert Volume-Ownership-Drift nach Watchtower-Updates — bootstrap.sh setzt die Ownership vollautomatisch.

## Automatische Updates — Zeitplan (UTC)

| Zeit | Was |
|------|-----|
| 02:00 | Backup → R2 + .env → GitHub + Status-Mail |
| 02:30 | Watchtower → Container-Images |
| 03:00 | unattended-upgrades → Ubuntu + Docker Engine |
| 03:30 | Automatischer Neustart falls Kernel-Update |

## Wichtige Befehle

```bash
cd ~/ugly-stack

# Secret aktualisieren
bash set-secret.sh TELEGRAM_BOT_TOKEN "neuer-token"
bash set-secret.sh                    # interaktiv

# Stack verwalten
docker compose ps
docker compose logs -f
docker compose restart
docker compose pull && docker compose up -d

# Backup manuell
bash backup/backup-master.sh

# Restore
bash backup/restore/restore-master.sh list
bash backup/restore/restore-master.sh
```

## Backup

- Täglich 02:00 UTC — checksummen-basiert (nur bei Änderungen)
- Sonntags: WEEKLY-Backup unabhängig von Änderungen
- GPG AES256 verschlüsselt → Cloudflare R2
- 7 normale + 4 WEEKLY Backups
- Status-Mail nach jedem Lauf via Brevo

## Dokumentation

| Dokument | Inhalt |
|----------|--------|
| **[BETRIEB.md](./BETRIEB.md)** | Vollständiges Betriebshandbuch: Secrets, Troubleshooting, Migration |
| **[CLAUDE.md](./CLAUDE.md)** | Technischer Kontext für Claude-Sessions inkl. VPS-Portabilitätsphilosophie |
| **[backup/NEUES_MODUL.md](./backup/NEUES_MODUL.md)** | Neuen Container + Backup-Modul hinzufügen |

## Dateistruktur

```
~/ugly-stack/
├── bootstrap.sh              ← Neuinstallation (hosterunabhängig)
├── set-secret.sh             ← Secret aktualisieren
├── docker-compose.yml        ← Stack-Definition
├── architecture.svg          ← Architektur-Diagramm
├── nginx/conf.d/
├── openclaw-data/            ← Volume (owner: 1000:alex, g+rX)
├── n8n-data/                 ← Volume (owner: 1000:alex, g+rX)
├── searxng-data/             ← Volume
├── www/                      ← Volume
└── backup/
    ├── backup-master.sh
    ├── .checksums            ← Checksummen (gitignored)
    ├── modules/
    └── restore/
```
