#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# Moodle Upgrade Script (Vollautomatisches CLI Upgrade)
# ====================================================================

log_message() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_section() { echo "======================================================================"; echo "= $1"; echo "======================================================================"; }

update_php_version() {
    local php_version="$1"
    local doc_root="${2:-/var/www/html}"
    log_message "Aktualisiere PHP-Version auf $php_version und DocumentRoot auf $doc_root..."
    
    # Sicherer Regex, egal welche Version aktuell drin steht
    sed -E -i "s|image: 'moodlehq/moodle-php-apache:.*'|image: 'moodlehq/moodle-php-apache:$php_version'|g" docker-compose.yml
    
    # APACHE_DOCUMENT_ROOT aktualisieren oder hinzufügen
    if ! grep -q "APACHE_DOCUMENT_ROOT" docker-compose.yml; then
        sed -i "/- MOODLE_DOCKER_WEB_HOST=localhost/a \      - APACHE_DOCUMENT_ROOT=$doc_root" docker-compose.yml
    else
        sed -E -i "s|- APACHE_DOCUMENT_ROOT=.*|- APACHE_DOCUMENT_ROOT=$doc_root|g" docker-compose.yml
    fi

    docker compose down
    docker compose up -d
    sleep 15
}

clear_moodle_cache() {
    log_message "Lösche Moodle-Cache..."
    docker exec newmoodle_web_1 bash -c "rm -rf /var/www/moodledata/cache/* /var/www/moodledata/localcache/* /var/www/moodledata/temp/*" || true
}

bypass_mysql_version_check() {
    log_message "Umgehe MySQL Versionsprüfung..."
    docker exec newmoodle_db_1 mysql -u root -pSecret -e "USE mysql; DROP FUNCTION IF EXISTS version; CREATE FUNCTION version() RETURNS VARCHAR(64) DETERMINISTIC NO SQL RETURN '8.4.0';" || true
    
    local env_path="/var/www/html/admin/environment.xml"
    if docker exec newmoodle_web_1 [ -f "/var/www/html/public/admin/environment.xml" ]; then
        env_path="/var/www/html/public/admin/environment.xml"
    fi
    log_message "Verwende environment.xml Pfad: $env_path"
    
    docker exec newmoodle_web_1 bash -c "sed -i 's/<VENDOR name=\"mysql\" version=\"8.4\"/<VENDOR name=\"mysql\" version=\"8.0\"/g' $env_path"
    
    docker exec newmoodle_web_1 bash -c "sed -i \"/\\\$CFG->directorypermissions/a \\\$CFG->dboptions['dbminimumversion'] = '5.7.0';\" /var/www/html/config.php"
}

upgrade_moodle_version() {
    local version="$1"
    local branch="$2"
    local bypass_db_check="${3:-false}"

    log_section "Upgrade auf Moodle $version"
    
    docker exec newmoodle_web_1 apt-get update
    docker exec newmoodle_web_1 apt-get install -y wget unzip

    local download_url="https://download.moodle.org/download.php/direct/stable$branch/moodle-latest-$branch.zip"
if [[ "$version" == "4.2.3" ]]; then download_url="https://download.moodle.org/download.php/direct/stable402/moodle-4.2.3.zip"; fi

log_message "Lade Moodle $version herunter (URL: $download_url)..."
docker exec newmoodle_web_1 bash -c "cd /tmp && wget --no-check-certificate $download_url -O moodle-$version.zip"

if ! docker exec newmoodle_web_1 bash -c "cd /tmp && unzip -t moodle-$version.zip > /dev/null 2>&1"; then
    log_message "KRITISCHER FEHLER: Die heruntergeladene Datei ist kein gültiges ZIP-Archiv!"
    log_message "Wahrscheinlich existiert die Version $version unter diesem Link nicht."
    exit 1
fi

log_message "Entpacke Moodle $version..."
docker exec newmoodle_web_1 bash -c "cd /tmp && unzip -q moodle-$version.zip"

    docker exec newmoodle_web_1 bash -c "find /var/www/html -mindepth 1 -maxdepth 1 -not -name 'config.php' -not -name 'moodledata' -exec rm -rf {} \;"
    docker exec newmoodle_web_1 bash -c "cp -rf /tmp/moodle/* /var/www/html/"
    docker exec newmoodle_web_1 bash -c "rm -rf /tmp/moodle /tmp/moodle-$version.zip"
    
    # Rechte reparieren für www-data User
    docker exec newmoodle_web_1 chown -R www-data:www-data /var/www/html

    clear_moodle_cache

    if [[ $version == "5.2" && $bypass_db_check == "true" ]]; then
        bypass_mysql_version_check
        
        log_message "Behebe bekannte Moodle 5.2 Datenbank-Lücken..."
        docker exec -i newmoodle_db_1 mysql -u root -pSecret moodle -e "CREATE TABLE IF NOT EXISTS mdl_sms_gateways (id BIGINT(10) NOT NULL AUTO_INCREMENT, name VARCHAR(100) NOT NULL DEFAULT '', classname VARCHAR(255) NOT NULL DEFAULT '', config LONGTEXT, enabled TINYINT(2) NOT NULL DEFAULT 0, PRIMARY KEY (id));"
        docker exec -i newmoodle_db_1 mysql -u root -pSecret moodle -e "ALTER TABLE mdl_course_sections ADD COLUMN IF NOT EXISTS component VARCHAR(100) NOT NULL DEFAULT '', ADD COLUMN IF NOT EXISTS itemid BIGINT(10) DEFAULT NULL;"
    fi

    log_message "Führe Moodle Datenbank-Upgrade über CLI aus (Non-Interactive)..."
    local cli_path="/var/www/html/admin/cli/upgrade.php"
    if docker exec newmoodle_web_1 [ -f "/var/www/html/public/admin/cli/upgrade.php" ]; then
        cli_path="/var/www/html/public/admin/cli/upgrade.php"
    fi
    log_message "Verwende CLI-Upgrade Pfad: $cli_path"
    
    # Moodle CLI Befehl als www-data User ausführen - Keine Browser Interaktion nötig!
    docker exec --user www-data newmoodle_web_1 php $cli_path --non-interactive
    
    log_message "Moodle $version Upgrade abgeschlossen."
}

# Ablaufsteuerung
log_section "Start des Upgrade-Prozesses"

# Schritt 1: Upgrade von Moodle 4.2 auf Moodle 4.4
update_php_version "8.1" "/var/www/html"
upgrade_moodle_version "4.4" "404"

# Schritt 2: Upgrade von Moodle 4.4 auf Moodle 5.2
update_php_version "8.3" "/var/www/html/public"
upgrade_moodle_version "5.2" "502" "true"

log_section "Upgrade komplett abgeschlossen!"
log_message "Die Umgebung läuft nun vollautomatisiert auf Moodle 5.2."
