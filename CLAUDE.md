# Ugly Stack — Projektkontext

Persönlicher KI-Agent "Ugly" auf Hostinger VPS (Ubuntu 24.04).
Repo: https://github.com/uglyatbeautymolt/VPS_Bootstrap
Stack: /home/alex/ugly-stack | User: alex | Telegram: @openClawBeautyBot

## Services

| Container | URL | Port |
|-----------|-----|------|
| openclaw | claw.beautymolt.com | 18789 |
| nginx | www.beautymolt.com | 80 |
| searxng | search.beautymolt.com | 8080 |
| n8n | n8n.beautymolt.com | 5678 |
| roundcube | mail.beautymolt.com | 80 |
| cloudflared | — | — |

Docker Bridge-Netzwerk: **ugly-net**

## Secrets

- `.env` auf VPS (verschlüsselt als `.env.gpg` im Repo)
- GPG Passwort: Bitwarden → `BACKUP_GPG_PASSWORD`
- Update: `./set-secret.sh SECRET_NAME "wert"`

## E-Mail Workflow

```
ugly@beautymolt.com (Zoho IMAP)
  → n8n IMAP Trigger
  → JS Node (Sanitization)
  → HTTP POST http://openclaw:18789/hooks/agent
    Header: x-openclaw-token: <OPENCLAW_HOOK_TOKEN>
    Body: {"message":"...","name":"Email","wakeMode":"now"}
  → openclaw antwortet via Brevo REST API
```

**n8n Prompt:** Handlungsauftrag MUSS vor dem Mail-Inhalt stehen — sonst blockiert openclaw sich selbst.

## openclaw.json — kritische Felder

```json
{
  "gateway": { "bind": "lan" },
  "hooks": {
    "enabled": true,
    "token": "<OPENCLAW_HOOK_TOKEN>",
    "path": "/hooks"
  }
}
```

- `hooks` ist **Top-Level-Key** — nie unter `gateway` einbetten (→ "Unrecognized key" Fehler)
- `bind: lan` — nie `loopback` (Dashboard setzt es manchmal zurück → prüfen)
- Auth-Header: `x-openclaw-token` — nicht `Authorization: Bearer`

Hook testen:
```bash
docker exec n8n wget -qO- \
  --header='x-openclaw-token: TOKEN' \
  --header='Content-Type: application/json' \
  --post-data='{"message":"Test","name":"Email","wakeMode":"now"}' \
  'http://openclaw:18789/hooks/agent'
# → {"ok":true,"runId":"..."}
```

## Brevo

- SMTP: `a50340001@smtp-brevo.com` + `BREVO_SMTP_API_KEY` (für n8n)
- REST: `BREVO_KEY` (xkeysib-...) für openclaw Skill + Backup-Mails
- Absender: `ugly@beautymolt.com`
- Backup-Mail JSON immer via python3 bauen — Shell-Interpolation bricht bei Sonderzeichen

## Modelle

Primary: `openrouter/deepseek/deepseek-v3.2`
Wechseln: `docker exec openclaw openclaw config set agents.defaults.model.primary "openrouter/..."`
Dashboard-Dropdown hat Bug → immer CLI verwenden!

## Backup

- Täglich 03:00 Cron → Cloudflare R2 (GPG AES256), 7 Backups
- Protokoll-Mail nach jedem Backup an alex@alexstuder.ch
- Manuell: `./backup/backup-master.sh`
- openclaw-data braucht `sudo tar` (Ownership 1000:1000)
- Scripts aus GitHub haben kein +x → bootstrap.sh setzt `chmod +x` nach clone

## Bootstrap

```bash
curl -fsSL https://raw.githubusercontent.com/uglyatbeautymolt/VPS_Bootstrap/main/bootstrap.sh \
  -o bootstrap.sh && chmod +x bootstrap.sh && ./bootstrap.sh
```

Fragt nur: Bitwarden E-Mail, Master-Passwort, Passwort für alex.
Bootstrap setzt nach Restore automatisch: `bind: lan`, `hooks` Block, `chmod +x` alle Scripts, sudoers für tar.
