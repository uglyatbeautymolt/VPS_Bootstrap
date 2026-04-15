# Ugly Stack

VPS: beautymolt.com (Hostinger, Ubuntu 24.04) | Stack: /home/alex/ugly-stack | User: alex
Repo: https://github.com/uglyatbeautymolt/VPS_Bootstrap

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

## Secrets

`.env` auf VPS → `.env.gpg` im Repo (GPG). Update: `bash set-secret.sh NAME "wert"`
`.env.example` wird nie benötigt — nur `.env.gpg` zählt.
Scripts immer mit `bash scriptname.sh` — nie `./` (Git setzt kein +x).
sudo-Timeout: 60 Min (einmal Passwort → 1h gültig).

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
- TRUSTED_ORIGINS=portainer.beautymolt.com (CSRF-Fix für Reverse Proxy)
- Volume: portainer-data (named volume, im Backup enthalten)

## Bootstrap

Fragt nur: Bitwarden E-Mail, Master-Passwort (+ OTP falls neues Gerät), Passwort für alex.
Setzt automatisch: `bind: lan`, `hooks` Block, `chmod +x` alle Scripts, sudoers 60min,
unattended-upgrades, systemd Timer-Overrides, Backup-Cron 02:00.
Volume-Ownership wird vollständig automatisch gesetzt — kein manueller Eingriff nötig.
