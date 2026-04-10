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

## Brevo

- `BREVO_KEY` (xkeysib-...): openclaw E-Mail-Versand via **Brevo Skill**
- `BREVO_SMTP_API_KEY` (xsmtpsib-...): n8n SMTP
- Absender immer: `ugly@beautymolt.com` (Name: Ugly)

## Modelle

Primary: `openrouter/deepseek/deepseek-v3.2`
Wechseln nur via CLI — Dashboard-Dropdown hat Bug.

## Backup

Täglich 03:00 → R2 (GPG AES256), 7 Backups, danach Verifikation + Mail an alex@alexstuder.ch
Manuell: `bash backup/backup-master.sh`
Verify: `bash backup/verify-backup.sh`
Skills in `openclaw-data/workspace/skills/` → im Backup enthalten.
openclaw-data Ownership: 1000:1000 → sudo nötig für Lesen/Schreiben.

## Bootstrap

Fragt nur: Bitwarden E-Mail, Master-Passwort (+ OTP falls neues Gerät), Passwort für alex.
Setzt automatisch: `bind: lan`, `hooks` Block, `chmod +x` alle Scripts, sudoers 60min.
