#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# Moodle Migration Script
# 
# Dieses Skript migriert eine lokale Moodle-Installation in einen Docker-Container
# ====================================================================

# Logging-Funktion für bessere Strukturierung der Ausgaben
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_section() {
    echo "======================================================================"
    echo "= $1"
    echo "======================================================================"
}

# Funktion zum Prüfen des Container-Status
check_container_status() {
    local container_name="$1"
    local max_attempts="$2"
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        log_message "Prüfe Container-Status (Versuch $attempt/$max_attempts)"
        if docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null | grep -q "running"; then
            return 0
        fi
        sleep 10
        attempt=$((attempt+1))
    done
    return 1
}

# Apache für .htaccess konfigurieren
configure_apache() {
    log_section "Apache konfigurieren"
    log_message "Konfiguriere Apache für .htaccess-Unterstützung..."

    # Erstelle Apache-Konfiguration
    cat > moodle-apache.conf << EOF
<Directory /var/www/html>
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
EOF

    # Kopiere und aktiviere die Konfiguration
    docker cp moodle-apache.conf newmoodle_web_1:/etc/apache2/conf-available/moodle.conf
    docker exec newmoodle_web_1 a2enconf moodle
    docker exec newmoodle_web_1 service apache2 reload
    log_message "Apache-Konfiguration erfolgreich aktualisiert"
    
    # Lösche die temporäre Konfigurationsdatei
    rm -f moodle-apache.conf
}

# Hauptfunktion für die Migration
main() {
    # Docker Compose ausführen
    log_section "Docker-Container starten"
    log_message "Docker-Compose wird ausgeführt..."
    docker compose down -v
    docker compose up -d
    if [ $? -eq 0 ]; then
        log_message "Alle Docker-Container erfolgreich gestartet"
    else
        log_message "FEHLER: Docker-Container konnten nicht gestartet werden"
        exit 1
    fi

    # Warten auf Start von DB-, Web- und PMA-Container
    log_message "Warte auf Start der DB-, Web- und PMA-Container..."
    if ! check_container_status newmoodle_db_1 20 || ! check_container_status newmoodle_web_1 20 || ! check_container_status pma 20; then
        log_message "FEHLER: Einer der Container (DB, Web, PMA) konnte nicht gestartet werden"
        exit 1
    fi

    # MySQL-Dump erstellen
    log_section "Datenbank sichern"
    log_message "Erstelle MySQL-Dump der lokalen Moodle-Datenbank..."
    sudo mysqldump --password=Secret moodle > moodle_database_dump.sql
    if [ $? -eq 0 ]; then
        log_message "MySQL-Dump erfolgreich erstellt"
    else
        log_message "FEHLER: MySQL-Dump konnte nicht erstellt werden"
        exit 1
    fi

    log_message "Warte 10 Sekunden, bevor der Dump kopiert wird..."
    sleep 10

    # Dump in den MySQL-Container laden
    log_section "Datenbank migrieren"
    log_message "Kopiere Datenbank-Dump in den Container..."
    sudo docker cp moodle_database_dump.sql newmoodle_db_1:/var/lib/mysql

    log_message "Warte 5 Sekunden vor dem Import..."
    sleep 5

    # Bestehende Moodle DB wird gelöscht und wieder erstellt
    log_message "Lösche bestehende Datenbank im Container und erstelle sie neu..."
    docker exec -i newmoodle_db_1 bash -c "mysql -u root --password=Secret -e 'DROP DATABASE IF EXISTS moodle; CREATE DATABASE moodle;'"

    # In den MySQL-Container wechseln und den Dump importieren
    log_message "Importiere Datenbank-Dump in den Container..."
    docker exec -i newmoodle_db_1 mysql -u root --password=Secret moodle < ./moodle_database_dump.sql
    if [ $? -eq 0 ]; then
        log_message "Datenbank erfolgreich importiert"
    else
        log_message "FEHLER: Datenbank konnte nicht importiert werden"
        exit 1
    fi

    # Aufräumen: Lokalen Dump entfernen
    log_message "Entferne temporäre Dump-Datei..."
    rm moodle_database_dump.sql

    # Apache für .htaccess konfigurieren
    configure_apache

    # Moodle-Anwendungsdateien kopieren
    log_section "Moodle-Anwendungsdateien kopieren"

    # Quellverzeichnis für Moodle-Anwendung
    APP_SOURCE_DIR="/var/www/html"

    # Volume-Pfad für moodle_app Volume ermitteln
    log_message "Ermittle Volume-Pfad für moodle_app"
    APP_VOLUME_PATH=$(docker volume inspect --format '{{.Mountpoint}}' newmoodle_moodle_app)

    # Stelle sicher, dass das Verzeichnis existiert und leer ist
    log_message "Bereite Zielverzeichnis für Moodle-App vor"
    sudo rm -rf "$APP_VOLUME_PATH"/*
    sudo mkdir -p "$APP_VOLUME_PATH"

    # Kopiere die Moodle-Anwendungsdateien
    log_message "Kopiere Moodle-Anwendungsdateien von $APP_SOURCE_DIR nach $APP_VOLUME_PATH"
    sudo cp -a "$APP_SOURCE_DIR"/* "$APP_VOLUME_PATH"/

    # Setze die korrekten Berechtigungen
    log_message "Setze Berechtigungen für Moodle-App"
    sudo chown -R www-data:www-data "$APP_VOLUME_PATH"
    sudo chmod -R 755 "$APP_VOLUME_PATH"

    # Moodle-Daten kopieren
    log_section "Moodle-Daten kopieren"

    # Quellverzeichnis für Moodle-Daten ermitteln
    DATA_SOURCE_DIR="/var/www/moodledata"
    if [ ! -d "$DATA_SOURCE_DIR" ]; then
        DATA_SOURCE_DIR="/var/www/html/moodledata"
    fi

    # Falls kein Moodledata-Verzeichnis gefunden wurde
    if [ ! -d "$DATA_SOURCE_DIR" ]; then
        log_message "WARNUNG: Quellverzeichnis für Moodle-Daten nicht gefunden, erstelle leeres Verzeichnis"
        DATA_SOURCE_DIR="/tmp/moodledata_empty"
        mkdir -p "$DATA_SOURCE_DIR"
    fi

    # Volume-Pfad für moodle_data Volume ermitteln
    log_message "Ermittle Volume-Pfad für moodle_data"
    DATA_VOLUME_PATH=$(docker volume inspect --format '{{.Mountpoint}}' newmoodle_moodle_data)

    # Stelle sicher, dass das Verzeichnis existiert und leer ist
    log_message "Bereite Zielverzeichnis für Moodle-Daten vor"
    sudo rm -rf "$DATA_VOLUME_PATH"/*
    sudo mkdir -p "$DATA_VOLUME_PATH"

    # Kopiere die Moodle-Daten
    log_message "Kopiere Moodle-Daten von $DATA_SOURCE_DIR nach $DATA_VOLUME_PATH"
    sudo cp -a "$DATA_SOURCE_DIR"/. "$DATA_VOLUME_PATH"/

    # Setze die korrekten Berechtigungen
    log_message "Setze Berechtigungen für Moodle-Daten"
    sudo chown -R www-data:www-data "$DATA_VOLUME_PATH"
    sudo chmod -R 755 "$DATA_VOLUME_PATH"

    # Erstelle config.php im Moodle-Verzeichnis
    log_section "Moodle-Konfiguration erstellen"
    log_message "Erstelle config.php für Moodle..."

    cat > config.php << EOF
<?php  // Moodle configuration file

unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = 'mysqli';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = 'db';
\$CFG->dbname    = 'moodle';
\$CFG->dbuser    = 'moodle';
\$CFG->dbpass    = 'Secret';
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = array(
    'dbpersist' => 0,
    'dbport' => '',
    'dbsocket' => '',
    'dbcollation' => 'utf8mb4_unicode_ci',
);

\$CFG->wwwroot   = 'http://localhost';
\$CFG->dataroot  = '/var/www/moodledata';
\$CFG->admin     = 'admin';

\$CFG->directorypermissions = 0777;

require_once(__DIR__ . '/lib/setup.php');

// There is no php closing tag in this file,
// it is intentional because it prevents trailing whitespace problems!
EOF

    # Kopiere config.php in den Container
    log_message "Kopiere config.php in den Moodle-Container..."
    docker cp config.php newmoodle_web_1:/var/www/html/config.php
    docker exec newmoodle_web_1 chown www-data:www-data /var/www/html/config.php
    docker exec newmoodle_web_1 chmod 644 /var/www/html/config.php

    # Entferne lokale config.php
    rm config.php

    # Container neu starten
    log_section "Container neu starten"
    log_message "Starte Container neu, um Änderungen zu übernehmen..."
    docker compose restart
    log_message "Container wurden neu gestartet"

    log_message "Migration erfolgreich abgeschlossen"
    
    # Frage, ob das Upgrade-Skript automatisch gestartet werden soll
    log_section "Moodle-Upgrade starten"
    log_message "Die Migration wurde erfolgreich abgeschlossen."
    read -p "Möchten Sie jetzt das Moodle-Upgrade auf Version 5.2 starten? (j/n): " start_upgrade
    
    if [[ $start_upgrade == "j" || $start_upgrade == "J" ]]; then
        log_message "Starte das Moodle-Upgrade-Skript..."
        bash ./moodle_upgrade.sh
    else
        log_message "Upgrade wurde nicht gestartet. Sie können es später manuell mit 'bash moodle_upgrade.sh' ausführen."
        log_message "Öffnen Sie http://localhost in Ihrem Browser, um die Moodle-Installation zu überprüfen."
    fi
}

# Hauptprogramm ausführen
main
