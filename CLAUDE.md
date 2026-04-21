# CLAUDE.md — Verhaltensregeln für Claude CLI

## Kontext
Dieses Repo ist ugly-stack (VPS_Bootstrap) — der Betriebsstack für beautymolt.com auf Hetzner CX22.
Alle Änderungen laufen über dieses GitHub Repo. Kein manueller Eingriff auf dem VPS.
Änderungen immer via Commit → git pull → bootstrap.sh (idempotent).

---

## ✅ DARF OHNE RÜCKFRAGE (Lesen & Recherche)

Claude darf folgende Aktionen **eigenständig und ohne Nachfragen** ausführen:
- Dateien lesen (lokal, im Repo, im Container)
- `docker logs`, `docker exec ... cat`, `docker exec ... sqlite3 SELECT` — nur lesend
- Web-Recherche: Dokumentationen, GitHub Issues, Changelogs, Blogs
- URLs fetchen und Inhalte analysieren
- Logs, Configs und Datenbankinhalt analysieren
- Systemzustand erfassen (`docker ps`, `df`, `free`, `which`)
- Lösungsvorschläge erarbeiten und erklären

---

## ❌ NIEMALS OHNE MEINE EXPLIZITE FREIGABE (Schreiben & Ändern)

Claude darf folgende Aktionen **nur nach ausdrücklicher Bestätigung** ausführen:
- Dateien schreiben, ändern oder löschen
- Git Commits erstellen oder pushen
- `docker exec` mit schreibenden Befehlen (apt-get install, touch, mkdir, etc.)
- `docker compose up/down/restart` oder Container-Neustarts
- bootstrap.sh ausführen
- `.env` oder Konfigurationsdateien ändern
- Irgendetwas am laufenden System verändern

**Vor jeder dieser Aktionen:** Plan zeigen, warten auf "ja" / "ok" / "mach es".

---

## ⚠️ KEYS NIE IM KLARTEXT ANZEIGEN

**Alle Befehle die Secrets ausgeben könnten, MÜSSEN maskiert werden.**
Das gilt für: `.env`, `docker exec env`, `openclaw.json`, `rclone.conf`, und alle anderen Config-Dateien.

Anzeige von Vorhandensein ohne Wert — Konvention:
- Key vorhanden und nicht leer → `***` (z.B. `BREVO_KEY=***`)
- Key vorhanden aber leer      → `(leer)`
- Key fehlt komplett           → `(fehlt)`

Standard-Befehl für `docker exec env`:
```
docker exec <container> env | grep <TERM> | sed 's/=.*/=***/'
```

Standard-Befehl für JSON-Configs (openclaw.json etc.):
```
cat <datei> | python3 -c "
import json,sys
d=json.load(sys.stdin)
def mask(obj):
    if isinstance(obj,dict):
        return {k: '***' if any(x in k.lower() for x in ['token','key','password','secret','auth']) else mask(v) for k,v in obj.items()}
    if isinstance(obj,list): return [mask(i) for i in obj]
    return obj
print(json.dumps(mask(d),indent=2))
"
```

Standard-Befehl für `.env`:
```
grep -v '^#' <datei> | grep '=' | sed 's/=.*/=***/'
```

---

## Arbeitsweise
1. **Erst vollständig analysieren** — alle relevanten Dateien lesen, Logs prüfen, recherchieren
2. **Dann Befund + Lösungsvorschlag** präsentieren — mit Begründung und Quellen
3. **Auf Freigabe warten** — bevor irgendwas verändert wird
4. **Nach Änderungen:** immer via Commit ins Repo, nie direkt auf dem VPS patchen

---

# Ugly Stack

VPS: beautymolt.com (Hetzner CX22, Ubuntu 24.04) | Stack: /home/alex/ugly-stack | User: alex
Repo: https://github.com/uglyatbeautymolt/VPS_Bootstrap | Betriebshandbuch: BETRIEB.md

## ⚠️ ARBEITSREGEL FÜR CLAUDE

**Nie raten bei Konfigurationswerten.** Vor jeder Änderung an openclaw.json oder bootstrap.sh: offizielle Dokumentation lesen oder Wert im laufenden System verifizieren (`docker exec openclaw ...`). Kein Wert darf angewendet werden, der nicht aus einer verifizierten Quelle stammt — auch wenn er "logisch klingt". Falsche Werte crashen den Container.

## ⚠️ BEKANNTE BOOTSTRAP-BUGS (bereits gefixt — nie nochmals einbauen)

- **cron nicht installiert:** `cron` explizit in `apt-get install` + `systemctl enable/start cron`
- **crontab -u Pipe schlägt fehl** auf frischem System (kein User-Spool) → Backup-Cron immer via `/etc/cron.d/ugly-backup` (`root:root`, `chmod 644`, kein Punkt im Dateinamen)
- **Cron-Verifikation:** `warn` statt `fail` — Bootstrap muss immer durchlaufen
- **openclaw-data / n8n-data:** Owner muss `1000:1000` sein
- **n8n Import:** erst nach health-check auf `localhost:5678/healthz`
- **Portainer Admin-Init:** Bereitschaft via `/api/system/status` (nicht `/api/status` — deprecated)
- **n8n Workflow aktivieren:** `n8n update:workflow --all --active=true` (nicht `workflow activate`)
- **openclaw Onboarding:** bereits abgeschlossen — nie nochmals durchführen

---

## Philosophie — VPS-Portabilität

Frischer Ubuntu 24.04 VPS → ein Befehl → kompletter Stack. Inputs: Bitwarden E-Mail, Master-Passwort, Passwort für alex. Alles andere kommt aus `.env.gpg` (GitHub) und dem letzten Backup (Cloudflare R2).

**VPS-Wechsel:**
1. `bash backup/backup-master.sh` auf altem VPS
2. `bootstrap.sh` auf neuem VPS
3. Cloudflare Tunnel-Route umstellen
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

| Service | Zweck |
|---------|-------|
| Cloudflare | DNS, Tunnel, R2 Backups |
| Bitwarden | BACKUP_GPG_PASSWORD, GITHUB_TOKEN |
| Brevo | E-Mail-Versand (SMTP + API) |
| Zoho Mail | E-Mail-Empfang (ugly@beautymolt.com) |

## Secrets

`.env` auf VPS → `.env.gpg` im Repo (GPG). Update: `bash set-secret.sh NAME "wert"`
Scripts immer mit `bash scriptname.sh` — nie `./` (Git setzt kein +x).
sudo-Timeout: 60 Min.

## E-Mail Workflow

ugly@beautymolt.com (Zoho IMAP) → n8n → HTTP POST `http://openclaw:18789/hooks/agent`
Header: `Authorization: Bearer <OPENCLAW_HOOK_TOKEN>`
Body: `{"message":"...","name":"Email","wakeMode":"now"}`
**Handlungsauftrag MUSS im message-Feld VOR dem Mail-Inhalt stehen.**

## ⚠️ openclaw — Konfigurationsregel

**Claude darf openclaw-Konfigurationen (openclaw.json oder andere) NIE direkt bearbeiten.**
Stattdessen: entweder beschreiben, wie Alex die Änderung manuell vornimmt — oder einen Prompt formulieren, den Alex an openclaw weitergibt, damit openclaw sich selbst konfiguriert. Bevorzugte Reihenfolge: (1) openclaw konfiguriert sich selbst, (2) Alex macht es manuell, (3) Claude beschreibt den Weg.

### Kritische Einstellungen (zur Referenz)
- `bind: custom` + `customBindHost: 0.0.0.0` — bindet auf alle Interfaces (LAN + Loopback); nötig damit Subagent-Announces via `ws://127.0.0.1` nicht timeouten; nie `loopback`-only (bricht nginx) und nie `all` (kein gültiger Wert)
- `hooks` ist **Top-Level-Key** — nie unter `gateway` einbetten
- Hook Auth: `Authorization: Bearer` — nie `x-openclaw-token`
- Debugging: `tail -50 /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log`

## Volume-Ownership

- `openclaw-data` und `n8n-data`: Owner `1000:1000`, Permissions `g+rX`
- `user: "1000:1000"` explizit in `docker-compose.yml` → verhindert Ownership-Drift nach Watchtower-Updates
- bootstrap.sh setzt Ownership automatisch via `fix_volume_ownership()`

## Brevo

- `BREVO_KEY` (xkeysib-...): openclaw E-Mail-Versand via Brevo Skill
- `BREVO_SMTP_API_KEY` (xsmtpsib-...): n8n SMTP + Watchtower SMTP
- Absender immer: `ugly@beautymolt.com` (Name: Ugly)

## Modelle

Primary: `openrouter/deepseek/deepseek-v3.2`
Wechseln nur via CLI — Dashboard-Dropdown hat Bug.

## Backup

Checksummen-basiert: nur bei Änderungen wird R2-Backup erstellt. `.env` bei Änderung → GPG → GitHub.
Sonntags: WEEKLY-Backup (4 Wochen Rotation). Normale Backups: 7 Stück.
Manuell: `bash backup/backup-master.sh` | Checksummen: `backup/.checksums`

## Automatische Updates — Zeitplan (UTC)

| Zeit | Was | Mechanismus |
|------|-----|-------------|
| 02:00 | Backup + .env sync + Status-Mail | `/etc/cron.d/ugly-backup` |
| 02:30 | Watchtower — Container-Images | Watchtower intern |
| 03:00 | unattended-upgrades | systemd Timer |
| 03:30 | Automatischer Reboot falls Kernel-Update | unattended-upgrades |

## Portainer

- URL: https://portainer.beautymolt.com — HTTP intern (Port 9000), nginx Proxy
- `--trusted-origins portainer.beautymolt.com` als CLI-Flag (OHNE https://) — TRUSTED_ORIGINS als Env-Var funktioniert NICHT in 2.39
- Volume: `ugly-stack_portainer-data`
- Passwort-Reset: `docker stop portainer && docker run --rm -v ugly-stack_portainer-data:/data portainer/helper-reset-password --password 'PASSWORT' && docker start portainer`
- Login: admin / `PORTAINER_ADMIN_PASSWORD` aus `.env` — bootstrap bricht ab wenn nicht vorhanden

## Bootstrap

Fragt nur: Bitwarden E-Mail, Master-Passwort (+ OTP), Passwort für alex.
Setzt automatisch: `bind: lan`, hooks-Block, sudoers 60min, unattended-upgrades, Backup-Cron via `/etc/cron.d/`.
Versionsformat: `V.YYYYMMDD_HHMMSS` (TZ=Europe/Zurich).

## ⚠️ Regel: Architektur zuerst

Architektur vollständig verstehen und dokumentieren, BEVOR Code geschrieben oder committed wird. Jede Lösung zuerst recherchieren. (Gelernt aus dem Obsidian/CouchDB-Fehlschlag April 2026.)
