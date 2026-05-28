#!/usr/bin/env bash
# ====================================================================
# Skript zur Umstellung des lokalen Apache-Webservers (alte Moodle-Instanz)
# auf Port 8080, damit Port 80 für das neue Docker-Moodle frei wird.
# ====================================================================

set -euo pipefail

# Prüfen, ob das Skript als Root ausgeführt wird
if [ "$EUID" -ne 0 ]; then
    echo "FEHLER: Dieses Skript muss mit sudo ausgeführt werden!"
    echo "Bitte starte es so: sudo bash $0"
    exit 1
fi

echo "=== Umstellung der alten Moodle-Instanz auf Port 8080 ==="

# 1. Apache Ports-Konfiguration anpassen (/etc/apache2/ports.conf)
if [ -f /etc/apache2/ports.conf ]; then
    echo "Passe /etc/apache2/ports.conf an..."
    # 'Listen 80' durch 'Listen 8080' ersetzen
    sed -i -E 's/Listen[[:space:]]+80$/Listen 8080/' /etc/apache2/ports.conf
else
    echo "WARNUNG: /etc/apache2/ports.conf nicht gefunden!"
fi

# 2. Apache VirtualHost-Konfigurationen anpassen
echo "Passe VirtualHost-Konfigurationen in /etc/apache2/sites-available/ an..."
for site_conf in /etc/apache2/sites-enabled/*.conf /etc/apache2/sites-available/*.conf; do
    if [ -f "$site_conf" ]; then
        echo "Verarbeite $site_conf..."
        # '<VirtualHost *:80>' durch '<VirtualHost *:8080>' ersetzen
        sed -i -E 's/<VirtualHost[[:space:]]+\*:80>/<VirtualHost *:8080>/g' "$site_conf"
    fi
done

# 3. Moodle config.php der alten Instanz anpassen
OLD_CONFIG="/var/www/html/config.php"
if [ -f "$OLD_CONFIG" ]; then
    echo "Passe config.php unter $OLD_CONFIG an..."
    
    # Auslesen des aktuellen wwwroot-Wertes
    CURRENT_WWWROOT=$(grep -E "\$CFG->wwwroot[[:space:]]*=" "$OLD_CONFIG" | head -n 1 | sed -E "s/.*=[[:space:]]*['\"]([^'\"]+)['\"];.*/\1/")
    
    if [ -n "$CURRENT_WWWROOT" ]; then
        echo "Aktueller wwwroot: $CURRENT_WWWROOT"
        
        # Prüfen, ob bereits ein Port definiert ist. Wenn nicht, :8080 anhängen.
        if [[ "$CURRENT_WWWROOT" =~ :[0-9]+ ]]; then
            NEW_WWWROOT=$(echo "$CURRENT_WWWROOT" | sed -E 's/:[0-9]+/:8080/')
        else
            # Protokoll und Host trennen, um Port einzufügen
            if [[ "$CURRENT_WWWROOT" =~ (https?://[^/]+)(.*) ]]; then
                NEW_WWWROOT="${BASH_REMATCH[1]}:8080${BASH_REMATCH[2]}"
            else
                NEW_WWWROOT="${CURRENT_WWWROOT}:8080"
            fi
        fi
        
        echo "Neuer wwwroot: $NEW_WWWROOT"
        # In config.php ersetzen
        sed -i "s|\$CFG->wwwroot[[:space:]]*=[[:space:]]*['\"]$CURRENT_WWWROOT['\"];|\$CFG->wwwroot = '$NEW_WWWROOT';|g" "$OLD_CONFIG"
    else
        echo "WARNUNG: \$CFG->wwwroot konnte in $OLD_CONFIG nicht automatisch ermittelt werden!"
        echo "Bitte passen Sie den Wert in $OLD_CONFIG manuell auf http://localhost:8080 (oder Ihre IP mit Port :8080) an."
    fi
else
    echo "WARNUNG: Keine config.php unter $OLD_CONFIG gefunden!"
fi

# 4. Apache-Webserver neu starten
echo "Starte Apache-Webserver neu..."
if systemctl is-active --quiet apache2; then
    systemctl restart apache2
    echo "✓ Apache-Webserver erfolgreich neu gestartet!"
elif service apache2 status >/dev/null 2>&1; then
    service apache2 restart
    echo "✓ Apache-Webserver erfolgreich neu gestartet!"
else
    echo "WARNUNG: Apache-Dienst konnte nicht neu gestartet werden. Bitte manuell neu starten!"
fi

echo "======================================================="
echo "✓ Umstellung erfolgreich abgeschlossen!"
echo "Die alte Moodle-Instanz läuft nun auf Port 8080."
echo "Sie können nun das Migrationsskript ausführen:"
echo "  bash moodle_migration.sh"
echo "======================================================="
