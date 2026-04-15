# Ugly Stack

VPS: beautymolt.com (Hetzner CX22, Ubuntu 24.04) | Stack: /home/alex/ugly-stack | User: alex
Repo: https://github.com/uglyatbeautymolt/VPS_Bootstrap

## Philosophie — VPS-Portabilität

Das Ziel ist maximale Unabhängigkeit vom Hoster. Der Stack muss auf jedem frischen Ubuntu 24.04 VPS — egal ob Hostinger, Hetzner oder ein anderer Anbieter — mit einem einzigen Befehl vollständig wiederherstellbar sein. Die einzigen drei Eingaben beim Bootstrap sind Bitwarden E-Mail, Master-Passwort und ein Passwort für User `alex`. Alles andere — Secrets, Konfiguration, Daten — kommt automatisch aus `.env.gpg` (GitHub) und dem neuesten Backup (Cloudflare R2).

**Was hosterunabhängig ist:**
- Alle Secrets → `.env.gpg` im GitHub Repo (verschlüsselt)
- Alle Daten → Cloudflare R2 (Backups, GPG-verschlüsselt)
- DNS + Tunnel → Cloudflare (hosterunabhängig)
- Domains → beautymolt.com via Cloudflare

**Was beim Wechsel zu tun ist:**
1. `bash backup/backup-master.sh` auf altem VPS
2. `bootstrap.sh` auf neuem VPS ausführen
3. Cloudflare Tunnel-Route auf neuen VPS umstellen
4. Alten VPS abschalten

## Services

| Container | URL | Port |
|-----------|-----|------|
| openclaw | claw.beautymolt.com | 18789 |
| searxng | search.beautymolt.com | 8080 |
| n8n | n8n.beautymolt.com | 5678 |
| nginx | www.beautymolt.com | 80 |
| roundcube | mail.beautymolt.com | 80 |
| portainer | portainer.beautymolt.com | 9000 (HTTP intern) |
| watchtower | — | — |
| cloudflared | — | — |

Docker Bridge-Netzwerk: **ugly-net**

## Externe Services

| Service | Link | Zweck |
|---------|------|-------|
| Cloudflare | dash.cloudflare.com | DNS, Tunnel, R2 Backups, Secrets Store |
| Bitwarden | vault.bitwarden.com | BACKUP_GPG_PASSWORD, GITHUB_TOKEN |
| Brevo | app.brevo.com | E-Mail-Versand (SMTP + API) |
| Zoho Mail | mail.zoho.eu | E-Mail-Empfang (ugly@beautymolt.com) |

## Secrets

`.env` auf VPS → `.env.gpg` im Repo (GPG). Update: `bash set-secret.sh NAME "wert"`
`.env.example` wird nie benötigt — nur `.env.gpg` zählt.
Scripts immer mit `bash scriptname.sh` — nie `./` (Git setzt kein +x).
sudo-Timeout: 60 Min (einmal Passwort → 1h gültig).
`PORTAINER_ADMIN_PASSWORD` muss in `.env` vorhanden sein — bootstrap bricht sonst ab.

## E-Mail Workflow

ugly@beautymolt.com (Zoho IMAP) → n8n → HTTP POST http://openclaw:18789/hooks/agent
Header: `Authorization: Bearer <OPENCLAW_HOOK_TOKEN>`
Body: `{"message":"...","name":"Email","wakeMode":"now"}`
**Handlungsauftrag MUSS im message-Feld VOR dem Mail-Inhalt stehen.**

## openclaw.json — Kritisch

- `bind: lan` — nie loopback (Dashboard setzt es manchmal zurück)
- `hooks` ist **Top-Level-Key** — nie unter `gateway` einbetten
- Hook Auth: `Authorization: Bearer` — nie `x-openclaw-token`
- Debugging: `tail -50 /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log`

## Volume-Ownership

- `openclaw-data` und `n8n-data`: Owner `1000:alex` (GID von alex), Permissions `g+rX`
- `user: "1000:1000"` ist explizit in docker-compose.yml gesetzt → verhindert Ownership-Drift nach Watchtower-Updates
- bootstrap.sh setzt Ownership automatisch via `fix_volume_ownership()` — nie manuell nötig
- Bei unerwartetem Permission-Problem: `sudo chown -R 1000:$(id -g) ~/ugly-stack/openclaw-data ~/ugly-stack/n8n-data && sudo chmod -R g+rX ~/ugly-stack/openclaw-data ~/ugly-stack/n8n-data`
- `couchdb-etc/` gehört uid 5984 — Änderungen immer mit `sudo`

## Brevo

- `BREVO_KEY` (xkeysib-...): openclaw E-Mail-Versand via **Brevo Skill**
- `BREVO_SMTP_API_KEY` (xsmtpsib-...): n8n SMTP + Watchtower SMTP
- Absender immer: `ugly@beautymolt.com` (Name: Ugly)
- Backup Status-Mail: `backup-master.sh` → Brevo REST API → alex@alexstuder.ch

## Modelle

Primary: `openrouter/deepseek/deepseek-v3.2`
Wechseln nur via CLI — Dashboard-Dropdown hat Bug.

## Backup

Täglich 02:00 UTC via Cron → backup-master.sh
- Checksummen-basiert: nur bei Änderungen wird R2-Backup erstellt
- .env: bei Änderung GPG verschlüsseln → .env.gpg → GitHub push
- Sonntags: WEEKLY-Backup unabhängig von Änderungen (4 Wochen Rotation)
- Normale Backups: 7 Stück behalten
- Status-Mail nach jedem Lauf via Brevo REST API

Manuell: `bash backup/backup-master.sh`
Checksummen: `backup/.checksums` (in .gitignore)

## Automatische Updates — Zeitplan (UTC)

| Zeit | Was |
|------|-----|
| 02:00 | Backup + .env sync + Status-Mail |
| 02:30 | Watchtower — Container-Images (openclaw, searxng, nginx, roundcube) |
| 03:00 | unattended-upgrades — Ubuntu Security + Docker Engine |
| 03:30 | Automatischer Neustart falls Kernel-Update nötig |

## Portainer

- URL: https://portainer.beautymolt.com
- HTTP intern (Port 9000) — nginx Proxy
- `--trusted-origins portainer.beautymolt.com` als CLI-Flag (OHNE https://) — als command in docker-compose.yml
- TRUSTED_ORIGINS als Env-Var funktioniert NICHT in 2.39 — nur CLI-Flag verwenden
- Volume: `ugly-stack_portainer-data` (named volume, Compose-Projektname als Präfix)
- Passwort-Reset: `docker stop portainer && docker run --rm -v ugly-stack_portainer-data:/data portainer/helper-reset-password --password 'PASSWORT' && docker start portainer` (einfache Anführungszeichen wegen Sonderzeichen)
- Login: admin / Passwort aus `.env` (`PORTAINER_ADMIN_PASSWORD`)

## Bootstrap

Fragt nur: Bitwarden E-Mail, Master-Passwort (+ OTP falls neues Gerät), Passwort für alex.
Setzt automatisch: `bind: lan`, `hooks` Block, `chmod +x` alle Scripts, sudoers 60min,
unattended-upgrades, systemd Timer-Overrides, Backup-Cron 02:00.
Volume-Ownership wird vollständig automatisch gesetzt — kein manueller Eingriff nötig.
Bricht ab wenn `PORTAINER_ADMIN_PASSWORD` nicht in `.env` vorhanden — kein Fallback.
- Portainer Admin-Init: POST /api/users/admin/init — Bereitschaft prüfen via /api/system/status (nicht /api/status — deprecated)
- n8n Workflow aktivieren: `n8n update:workflow --all --active=true` (nicht `workflow activate` — existiert nicht)

## GESCHEITERTE INTEGRATION: Obsidian + CouchDB (April 2026)

**Was versucht wurde:** CouchDB als Obsidian LiveSync Backend + openclaw liest Vault direkt.

**Warum es scheiterte:**
- CouchDB speichert Obsidian-Notizen intern als verschlüsselte Binär-Chunks — NICHT als lesbare Markdown-Dateien
- openclaw kann CouchDB-Daten nicht direkt lesen — es braucht echte `.md`-Dateien auf dem Filesystem
- Die Verbindung CouchDB → Filesystem existiert nicht ohne zusätzlichen Sync-Layer
- CORS-Probleme mit Cloudflare Tunnel: Cloudflare fügt eigene CORS-Header hinzu → Duplikate → LiveSync blockiert
- Viele widersprüchliche Lösungsversuche ohne vorherige Recherche — Zeit- und Geldverschwendung

**Was korrekt wäre (für zukünftige Implementation):**
1. Obsidian LiveSync + CouchDB = Sync zwischen Geräten (Mac ↔ iPhone) ✓
2. Syncthing oder ähnliches = Vault als echte `.md`-Dateien auf VPS spiegeln
3. openclaw mountet den Syncthing-Ordner als Volume → liest `.md`-Dateien direkt
4. Diese drei Komponenten müssen VOR der Implementation vollständig verstanden und recherchiert sein

**Lektion:** Architektur immer vollständig durchdenken und dokumentieren BEVOR mit der Implementation begonnen wird. Nie Lösungen vorschlagen ohne vorherige Webrecherche.
