#!/usr/bin/env bash
# Vorbereitung des Quellbaums (Arbeitsverzeichnis = OpenWrt-Wurzel).
# Quelle ist GL.iNets Branch "mt5000" – der Geräte-Support ist dort schon drin.
set -eu

PLATFORM_SH=target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh

# --- 1. Prüfen, ob der Geräte-Support vorhanden ist ------------------------
grep -q 'define Device/glinet_gl-mt5000' target/linux/mediatek/image/filogic.mk \
  || { echo "FEHLER: Geräterezept glinet_gl-mt5000 fehlt"; exit 1; }
test -f target/linux/mediatek/dts/mt7987a-gl-mt5000.dts \
  || { echo "FEHLER: DTS fehlt"; exit 1; }
echo ">> Geräte-Support vorhanden"

# --- 2. Fix: "Einstellungen behalten" beim Sysupgrade ----------------------
# Im PR steht das Gerät nur in platform_do_upgrade(), nicht in
# platform_copy_config(). Folge: Sysupgrade mit "keep settings" verwirft die
# Konfiguration stillschweigend. Wir tragen es in beiden Listen ein.
if awk '/^platform_copy_config\(\)/,/^}/' "$PLATFORM_SH" | grep -q 'glinet,gl-mt5000'; then
  echo ">> copy_config-Fix nicht nötig (bereits enthalten)"
else
  awk '
    /^platform_copy_config\(\)/ { in_cc = 1 }
    in_cc && /^\tglinet,gl-mt6000\|\\$/ && !done { print "\tglinet,gl-mt5000|\\"; done = 1 }
    in_cc && /^}/ { in_cc = 0 }
    { print }
  ' "$PLATFORM_SH" > "$PLATFORM_SH.new" && mv "$PLATFORM_SH.new" "$PLATFORM_SH"
  awk '/^platform_copy_config\(\)/,/^}/' "$PLATFORM_SH" | grep -q 'glinet,gl-mt5000' \
    || { echo "FEHLER: copy_config-Fix ließ sich nicht anwenden"; exit 1; }
  sh -n "$PLATFORM_SH" || { echo "FEHLER: platform.sh hat Syntaxfehler"; exit 1; }
  echo ">> copy_config-Fix angewendet"
fi
