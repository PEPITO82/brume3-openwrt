# Brume 3 (GL-MT5000) – eigenes OpenWrt per GitHub Actions

Baut OpenWrt für den GL.iNet GL-MT5000 aus GL.iNets Branch `mt5000`
(OpenWrt main, Kernel 6.18, Switch-Treiber als DSA) – also derselben Basis wie
der PR #24237 – plus eigener Paketliste und einem Fix für „Einstellungen
behalten“ beim Sysupgrade.

## Einmalig einrichten

1. Auf github.com ein **neues, öffentliches Repository** anlegen
   (z. B. `brume3-openwrt`). Öffentlich = Actions-Minuten kostenlos.
2. Den Inhalt dieses Ordners hochladen („Add file → Upload files“),
   inklusive des versteckten Ordners `.github/workflows/`.
   *Tipp:* Der Ordner `.github` wird beim Hochladen per Drag-and-drop manchmal
   übersprungen – dann die Datei über „Add file → Create new file“ mit dem
   Pfad `.github/workflows/build.yml` anlegen und den Inhalt einfügen.
3. Unter **Settings → Actions → General** prüfen, dass Actions erlaubt sind
   und bei „Workflow permissions“ **Read and write** gesetzt ist
   (nötig für das automatische Release).

## Bauen

**Actions → „Brume 3 OpenWrt bauen“ → Run workflow.**

- `source_ref`: Standard `mt5000` (aktueller GL.iNet-Stand). Ein Commit-Hash
  baut reproduzierbar einen bestimmten Stand.
- `all_kmods`: an = alle Kernelmodule werden mitgebaut und liegen im Release
  als `kmods-und-target-pakete.tar.gz` (für spätere Nachinstallation passend
  zum Kernel). Dauert länger.

Laufzeit: grob 2–4 Stunden beim ersten Mal, danach dank Cache schneller.
Ergebnis: ein Pre-Release unter **Releases** mit
`…gl-mt5000-squashfs-sysupgrade.bin`, Manifest und Prüfsummen.

## Pakete ändern

`config/brume3.config` bearbeiten (eine Zeile `CONFIG_PACKAGE_<name>=y` pro
Paket) und neu bauen.

## Flashen

1. Backup ziehen: LuCI → System → Sicherung → „Sicherung erstellen“
   (oder `sysupgrade -b /tmp/backup.tar.gz`) und auf den PC laden.
2. Das bisherige Image (dsouza 20260912) griffbereit halten.
3. Erstes Mal **ohne** Einstellungen flashen (`sysupgrade -n` bzw. Haken
   „Einstellungen beibehalten“ raus), dann das Backup in LuCI einspielen.
   Ab diesem Image funktioniert „Einstellungen beibehalten“ dank Fix normal.
4. Nicht vor einem Arbeitstag.

**Notfall:** Reset-Taste beim Einschalten ~5 s halten → U-Boot-Failsafe unter
http://192.168.1.1 (PC direkt an einen LAN-Port, feste IP 192.168.1.2) →
Image hochladen.

## Nachinstallation einzelner kmods

Pakete aus `kmods-und-target-pakete.tar.gz` auf den Router kopieren und mit
`apk add --allow-untrusted /tmp/<paket>.apk` installieren (die Pakete sind mit
einem pro Build erzeugten Schlüssel signiert, daher `--allow-untrusted`).
Paketfeeds aus dem Internet passen nicht zum eigenen Kernel – kmods immer aus
dem eigenen Build nehmen.
