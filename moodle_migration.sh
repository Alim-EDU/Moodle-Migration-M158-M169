#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# Moodle Migration Script (Vollautomatisch)
# ====================================================================

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_section() {
    echo "======================================================================"
    echo "= $1"
    echo "======================================================================"
}

configure_apache() {
    log_section "Apache konfigurieren"
    cat > moodle-apache.conf << EOF
<Directory /var/www/html>
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
EOF
    docker cp moodle-apache.conf newmoodle_web_1:/etc/apache2/conf-available/moodle.conf
    docker exec newmoodle_web_1 a2enconf moodle
    docker exec newmoodle_web_1 service apache2 reload
    rm -f moodle-apache.conf
}

main() {
    log_section "Docker-Container starten"
    docker compose down -v
    docker compose up -d

    log_message "Warte auf Datenbank-Bereitschaft (Healthcheck)..."
    sleep 15

    log_section "Datenbank sichern (Lokaler Dump)"
    sudo mysqldump -u debian-sys-maint -h 127.0.0.1 --password=vaIdfgRPSXzKbPPd moodle > moodle_database_dump.sql

    log_section "Datenbank migrieren"
    docker cp moodle_database_dump.sql newmoodle_db_1:/var/lib/mysql/
    docker exec -i newmoodle_db_1 mysql -u root -pSecret -e "DROP DATABASE IF EXISTS moodle; CREATE DATABASE moodle;"
    docker exec -i newmoodle_db_1 mysql -u root -pSecret moodle < moodle_database_dump.sql
    rm moodle_database_dump.sql

    configure_apache

    log_section "Moodle-Dateien kopieren"
    APP_VOLUME_PATH=$(docker volume inspect --format '{{.Mountpoint}}' newmoodle_moodle_app)
    sudo rm -rf "$APP_VOLUME_PATH"/*
    sudo cp -a /var/www/html/* "$APP_VOLUME_PATH"/
    sudo chown -R www-data:www-data "$APP_VOLUME_PATH"
    sudo chmod -R 755 "$APP_VOLUME_PATH"

    DATA_SOURCE_DIR="/var/www/moodledata"
    if [ ! -d "$DATA_SOURCE_DIR" ]; then DATA_SOURCE_DIR="/var/www/html/moodledata"; fi
    if [ ! -d "$DATA_SOURCE_DIR" ]; then mkdir -p /tmp/moodledata_empty; DATA_SOURCE_DIR="/tmp/moodledata_empty"; fi

    DATA_VOLUME_PATH=$(docker volume inspect --format '{{.Mountpoint}}' newmoodle_moodle_data)
    sudo rm -rf "$DATA_VOLUME_PATH"/*
    sudo cp -a "$DATA_SOURCE_DIR"/. "$DATA_VOLUME_PATH"/
    sudo chown -R www-data:www-data "$DATA_VOLUME_PATH"
    sudo chmod -R 755 "$DATA_VOLUME_PATH"

    log_section "config.php erstellen"
    cat > config.php << 'EOF'
<?php  // Moodle configuration file
unset($CFG);
global $CFG;
$CFG = new stdClass();
$CFG->dbtype    = 'mysqli';
$CFG->dblibrary = 'native';
$CFG->dbhost    = 'db';
$CFG->dbname    = 'moodle';
$CFG->dbuser    = 'moodle';
$CFG->dbpass    = 'Secret';
$CFG->prefix    = 'mdl_';
$CFG->dboptions = array('dbpersist' => 0, 'dbport' => '', 'dbsocket' => '', 'dbcollation' => 'utf8mb4_unicode_ci');
$CFG->wwwroot   = 'http://localhost';
$CFG->dataroot  = '/var/www/moodledata';
$CFG->admin     = 'admin';
$CFG->directorypermissions = 0777;
require_once(__DIR__ . '/lib/setup.php');
EOF
    docker cp config.php newmoodle_web_1:/var/www/html/config.php
    docker exec newmoodle_web_1 chown www-data:www-data /var/www/html/config.php
    rm config.php

    docker compose restart
    log_message "Migration abgeschlossen. Starte automatisches Upgrade..."
    
    # Vollautomatischer Aufruf des Upgrade-Skripts
    bash ./moodle_upgrade.sh
}

main
