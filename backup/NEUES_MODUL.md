# Neues Backup-Modul hinzufügen

## Schritt 1 — Backup-Modul erstellen

```bash
nano /home/alex/ugly-stack/backup/modules/meincontainer.sh
```

```bash
#!/bin/bash
# Modul: meincontainer
DEST="$STAGING/meincontainer"
mkdir -p "$DEST"

# Dateien aus Container kopieren
docker cp meincontainer:/pfad/datei "$DEST/" 2>/dev/null || true

# Oder Export-Befehl nutzen
docker compose exec -T meincontainer exportbefehl > "$DEST/export.json"

echo "meincontainer: Backup abgeschlossen"
```

```bash
chmod +x /home/alex/ugly-stack/backup/modules/meincontainer.sh
```

## Schritt 2 — Restore-Modul erstellen

```bash
nano /home/alex/ugly-stack/backup/restore/modules/meincontainer.sh
```

```bash
#!/bin/bash
# Restore: meincontainer
SRC="$STAGING/meincontainer"
[ ! -d "$SRC" ] && echo "Kein Backup gefunden" && exit 1
docker cp "$SRC/." meincontainer:/pfad/ 2>/dev/null || true
echo "meincontainer: Restore abgeschlossen"
```

```bash
chmod +x /home/alex/ugly-stack/backup/restore/modules/meincontainer.sh
```

## Schritt 3 — Testen

```bash
# Backup testen
STAGING=/tmp/test-staging bash /home/alex/ugly-stack/backup/modules/meincontainer.sh

# Restore testen
/home/alex/ugly-stack/backup/restore/restore-master.sh meincontainer
```

Das Master-Script erkennt neue Module automatisch.
