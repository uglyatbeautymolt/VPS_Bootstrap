# Ugly Stack

> Persönlicher KI-Agent "Ugly" auf einem selbst gehosteten VPS — vollständig automatisiert, verschlüsselt gesichert und in wenigen Minuten wiederherstellbar.

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

→ Alle Voraussetzungen, Secrets und Installationsdetails: **[BETRIEB.md — Erste Installation](./BETRIEB.md#1-erste-installation)**

---

![Ugly Stack Architektur](./architecture.svg)

## Services

| URL | Service |
|-----|---------|
| [claw.beautymolt.com](https://claw.beautymolt.com) | OpenClaw (Ugly) |
| [search.beautymolt.com](https://search.beautymolt.com) | SearXNG |
| [n8n.beautymolt.com](https://n8n.beautymolt.com) | n8n |
| [www.beautymolt.com](https://www.beautymolt.com) | nginx Webserver |
| [mail.beautymolt.com](https://mail.beautymolt.com) | Roundcube |
| [portainer.beautymolt.com](https://portainer.beautymolt.com) | Portainer (Docker Management) |

## Docker Netzwerk

Alle Container laufen im internen Bridge-Netzwerk **`ugly-net`**. Nach aussen ist kein Port offen — der einzige Eingang ist der Cloudflare Tunnel.

```
Internet
   │
   ▼
cloudflared (Cloudflare Tunnel)
   │
   ▼
nginx :80  (Reverse Proxy)
   ├──► openclaw  :18789   (claw.beautymolt.com)
   ├──► searxng   :8080    (search.beautymolt.com)
   ├──► n8n       :5678    (n8n.beautymolt.com)
   ├──► nginx www          (www.beautymolt.com)
   ├──► roundcube :80      (mail.beautymolt.com)
   └──► portainer :9000    (portainer.beautymolt.com)

watchtower  — kein HTTP, nur Docker Socket
```

| Container | Interner Host | Port | Netzwerk |
|-----------|--------------|------|----------|
| cloudflared | cloudflared | — | ugly-net |
| nginx | nginx | 80 | ugly-net |
| openclaw | openclaw | 18789 | ugly-net |
| searxng | searxng | 8080 | ugly-net |
| n8n | n8n | 5678 | ugly-net |
| roundcube | roundcube | 80 | ugly-net |
| portainer | portainer | 9000 | ugly-net |
| watchtower | watchtower | — | ugly-net |

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

# Container-Shell
docker exec -it openclaw bash
docker exec -it n8n sh

# Backup manuell
bash backup/backup-master.sh

# Restore
bash backup/restore/restore-master.sh list
bash backup/restore/restore-master.sh
bash backup/restore/restore-master.sh n8n

# Watchtower manuell auslösen
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  nickfedor/watchtower:latest --run-once openclaw searxng nginx roundcube
```

## Backup

- Täglich 02:00 UTC via Cron
- Checksummen-basiert — nur bei Änderungen wird R2-Backup erstellt
- Sonntags: WEEKLY-Backup unabhängig von Änderungen
- GPG AES256 verschlüsselt → Cloudflare R2
- 7 normale + 4 WEEKLY Backups werden behalten
- .env: bei Änderung als .env.gpg → GitHub gepusht
- Status-Mail nach jedem Lauf via Brevo

## Dokumentation

Vollständiges Betriebshandbuch: **[BETRIEB.md](./BETRIEB.md)**

Neuen Container hinzufügen: **[backup/NEUES_MODUL.md](./backup/NEUES_MODUL.md)**

## Dateistruktur

```
~/ugly-stack/
├── bootstrap.sh              ← Neuinstallation
├── set-secret.sh             ← Secret aktualisieren
├── docker-compose.yml        ← Stack-Definition
├── architecture.svg          ← Architektur-Diagramm
├── README.md
├── BETRIEB.md                ← Betriebshandbuch
├── nginx/conf.d/
├── openclaw-data/            ← Volume
├── n8n-data/                 ← Volume
├── searxng-data/             ← Volume
├── www/                      ← Volume
└── backup/
    ├── backup-master.sh
    ├── .checksums            ← Checksummen (gitignored)
    ├── modules/
    └── restore/
```
