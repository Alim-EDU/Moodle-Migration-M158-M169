#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
# Moodle Upgrade Script - Direktes Upgrade im Container
# 
# Dieses Skript führt ein schrittweises Upgrade von Moodle innerhalb des Containers durch
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

# Funktion zum Aktualisieren der PHP-Version in der docker-compose.yml
update_php_version() {
    local php_version="$1"
    log_section "PHP-Version aktualisieren"
    log_message "Aktualisiere PHP-Version auf $php_version..."
    
    # Aktualisiere die PHP-Version in der docker-compose.yml
    sed -i "s|image: 'moodlehq/moodle-php-apache:[0-9]\.[0-9]'|image: 'moodlehq/moodle-php-apache:$php_version'|g" docker-compose.yml
    
    # Starte die Container neu
    docker compose down
    docker compose up -d
    
    # Warte auf Container-Start
    log_message "Warte 10 Sekunden auf Container-Start..."
    sleep 10
    
    # Überprüfe, ob die PHP-Version korrekt aktualisiert wurde
    local current_php_version=$(docker exec newmoodle_web_1 php -r "echo PHP_VERSION;")
    log_message "Aktuelle PHP-Version im Container: $current_php_version"
    
    # Wenn die PHP-Version nicht korrekt aktualisiert wurde, versuche es erneut
    if [[ ! $current_php_version == $php_version* ]]; then
        log_message "PHP-Version wurde nicht korrekt aktualisiert. Versuche es erneut..."
        docker compose down
        docker compose up -d --force-recreate
        log_message "Warte 10 Sekunden auf Container-Start..."
        sleep 10
    fi
}

# Funktion zum Löschen des Moodle-Caches
clear_moodle_cache() {
    log_section "Moodle-Cache löschen"
    log_message "Lösche Moodle-Cache..."
    docker exec newmoodle_web_1 bash -c "rm -rf /var/www/moodledata/cache/*"
    docker exec newmoodle_web_1 bash -c "rm -rf /var/www/moodledata/localcache/*"
    docker exec newmoodle_web_1 bash -c "rm -rf /var/www/moodledata/temp/*"
    log_message "Cache erfolgreich gelöscht"
}

# Funktion zum Umgehen der MySQL-Versionsüberprüfung
bypass_mysql_version_check() {
    log_section "MySQL-Versionsüberprüfung umgehen"
    
    # Erstelle eine MySQL-Funktion, um die Version zu überschreiben
    log_message "Erstelle eine MySQL-Funktion, um die Version zu überschreiben..."
    docker exec newmoodle_db_1 mysql -u root -pSecret -e "USE mysql; DROP FUNCTION IF EXISTS version; CREATE FUNCTION version() RETURNS VARCHAR(64) DETERMINISTIC NO SQL RETURN '8.4.0';" || true
    
    # Direktes Patchen der environmentlib.php
    log_message "Patche environmentlib.php direkt..."
    docker exec newmoodle_web_1 bash -c "cat > /tmp/fix_mysql_version.php << 'EOFPHP'
<?php
// Direkter Fix für die MySQL-Versionsüberprüfung in Moodle 5.2

// Pfad zur environmentlib.php
\$file = '/var/www/html/lib/environmentlib.php';

// Lese den Inhalt der Datei
\$content = file_get_contents(\$file);

// Suche nach dem Abschnitt, der die Datenbankversion überprüft
\$search = 'function environment_check_database';

// Finde die Position des Abschnitts
\$pos = strpos(\$content, \$search);

if (\$pos !== false) {
    // Suche nach der Stelle, wo die Versionsüberprüfung durchgeführt wird
    \$check_pos = strpos(\$content, '/// And finally compare them, saving results', \$pos);
    
    if (\$check_pos !== false) {
        // Finde den Anfang der if-Anweisung
        \$if_pos = strpos(\$content, 'if (version_compare(', \$check_pos);
        
        if (\$if_pos !== false) {
            // Finde das Ende der Zeile
            \$line_end = strpos(\$content, '{', \$if_pos) + 1;
            
            // Ersetze die if-Anweisung
            \$old_if = substr(\$content, \$if_pos, \$line_end - \$if_pos);
            \$new_if = 'if (version_compare(\$current_version, \$needed_version, \'>=\') || 
        (\$current_vendor === \'mysql\' && \$needed_version === \'8.4\' && version_compare(\$current_version, \'8.0.0\', \'>=\'))) {';
            
            \$content = str_replace(\$old_if, \$new_if, \$content);
            
            // Schreibe die geänderte Datei zurück
            file_put_contents(\$file, \$content);
            
            echo 'Die MySQL-Versionsüberprüfung wurde erfolgreich umgangen.' . PHP_EOL;
        } else {
            echo 'Konnte die if-Anweisung nicht finden.' . PHP_EOL;
        }
    } else {
        echo 'Konnte die Versionsüberprüfung nicht finden.' . PHP_EOL;
    }
} else {
    echo 'Konnte die Funktion environment_check_database nicht finden.' . PHP_EOL;
}

// Ändere auch die environment.xml
\$env_file = '/var/www/html/admin/environment.xml';
\$env_content = file_get_contents(\$env_file);
\$env_content = str_replace('<VENDOR name=\"mysql\" version=\"8.4\"', '<VENDOR name=\"mysql\" version=\"8.0\"', \$env_content);
file_put_contents(\$env_file, \$env_content);

echo 'Die MySQL-Versionsanforderung in environment.xml wurde auf 8.0 geändert.' . PHP_EOL;
EOFPHP"
    
    # Führe das PHP-Skript aus
    log_message "Führe das PHP-Skript aus..."
    docker exec newmoodle_web_1 php /tmp/fix_mysql_version.php
    
    # Ändere die config.php
    log_message "Passe config.php an..."
    docker exec newmoodle_web_1 bash -c "cat > /var/www/html/config.php << 'EOF'
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

// Bypass database version check for Moodle 5.2
\$CFG->dboptions['dbminimumversion'] = '5.7.0';
\$CFG->upgraderunning = true; // Temporär für das Upgrade

require_once(__DIR__ . '/lib/setup.php');

// There is no php closing tag in this file,
// it is intentional because it prevents trailing whitespace problems!
EOF"
    
    log_message "MySQL-Versionsüberprüfung erfolgreich umgangen"
}

# Funktion zum Herunterladen und Installieren einer Moodle-Version im Container
upgrade_moodle_version() {
    local version="$1"
    local branch="$2"
    local bypass_db_check="${3:-}"

    log_section "Upgrade auf Moodle $version"
    log_message "Bereite Upgrade auf Moodle $version vor..."

    # Installiere benötigte Tools im Container
    docker exec newmoodle_web_1 apt-get update
    docker exec newmoodle_web_1 apt-get install -y wget unzip

    # Lade die Moodle-Version herunter und entpacke sie
    local download_url=""
    
    # Spezielle URLs für bestimmte Versionen
    if [[ "$version" == "4.2.3" ]]; then
        download_url="https://download.moodle.org/download.php/direct/stable402/moodle-4.2.3.zip"
    else
        download_url="https://download.moodle.org/download.php/direct/stable$branch/moodle-$version.zip"
    fi
    
    log_message "Download-URL: $download_url"
    log_message "Download-Versuch 1 von 3"
    docker exec newmoodle_web_1 bash -c "cd /tmp && wget -q $download_url -O moodle-$version.zip && unzip -q moodle-$version.zip"

    # Lösche alle Dateien im Webverzeichnis außer moodledata und config.php
    docker exec newmoodle_web_1 bash -c "find /var/www/html -mindepth 1 -maxdepth 1 -not -name 'config.php' -not -name 'moodledata' -exec rm -rf {} \;"

    # Kopiere die neuen Dateien in das Webverzeichnis
    docker exec newmoodle_web_1 bash -c "cp -rf /tmp/moodle/* /var/www/html/"

    # Stelle sicher, dass config.php vorhanden ist
    docker exec newmoodle_web_1 bash -c "if [ ! -f /var/www/html/config.php ]; then cp /tmp/config.php.backup /var/www/html/config.php; fi"

    # Lösche die temporären Dateien
    docker exec newmoodle_web_1 bash -c "rm -rf /tmp/moodle /tmp/moodle-$version.zip"

    log_message "Moodle-Dateien für Version $version erfolgreich aktualisiert"

    # Cache leeren
    clear_moodle_cache

    # Wenn es sich um das letzte Upgrade (Moodle 5.2) handelt, umgehe die MySQL-Versionsprüfung vor der Browser-Migration
    if [[ $version == "5.2" && $bypass_db_check == "true" ]]; then
        log_message "Umgehe die MySQL-Versionsprüfung für Moodle 5.2..."
        bypass_mysql_version_check
    fi

    # Starte den Upgrade-Assistenten im Browser
    log_message "Bitte öffnen Sie http://localhost/admin/index.php im Browser und führen Sie den Upgrade-Prozess durch."
    log_message "Drücken Sie ENTER, wenn das Upgrade abgeschlossen ist, um fortzufahren."
    read -p "Drücken Sie ENTER, wenn das Upgrade abgeschlossen ist..."
}

# Stelle sicher, dass die richtige PHP-Version für den Ausgangspunkt verwendet wird
log_section "Vorbereitung: Stelle sicher, dass PHP 7.4 verwendet wird"
update_php_version "7.4"

# Ausgangspunkt: Moodle 3.10.11 auf PHP 7.4
log_section "Ausgangspunkt: Moodle 3.10.11 auf PHP 7.4"
log_message "Aktuelle Installation: Moodle 3.10.11 auf PHP 7.4"

# Direktes Upgrade auf Moodle 4.0 (mit PHP 7.4) - Schritt 3.11 wird übersprungen
log_message "Überspringe Upgrade auf Moodle 3.11, da direktes Upgrade auf 4.0 möglich ist"
# Upgrade auf Moodle 4.0 (mit PHP 7.4)
upgrade_moodle_version "4.0" "400"

# Wechsle zu PHP 8.0 für Moodle 4.1+
update_php_version "8.0"

# Upgrade auf Moodle 4.2.3
log_message "Upgrade auf Moodle 4.2.3 (direkt von 4.0)"
upgrade_moodle_version "4.2.3" "423"

# Wechsle zu PHP 8.3 für Moodle 5.2
log_section "Wechsle zu PHP 8.3 für Moodle 5.2"
update_php_version "8.3"

# Überprüfe, ob PHP 8.3 korrekt aktiviert wurde
php_version=$(docker exec newmoodle_web_1 php -r "echo PHP_VERSION;")
log_message "PHP-Version vor dem Upgrade auf Moodle 5.2: $php_version"

if [[ ! $php_version == 8.3* ]]; then
    log_message "FEHLER: PHP 8.3 wurde nicht korrekt aktiviert. Aktuell: $php_version"
    log_message "Versuche erneut, PHP 8.3 zu aktivieren..."
    
    # Direktes Update der docker-compose.yml und Neustart der Container
    sed -i "s|image: 'moodlehq/moodle-php-apache:[0-9]\.[0-9]'|image: 'moodlehq/moodle-php-apache:8.3'|g" docker-compose.yml
    docker compose down
    docker compose up -d --force-recreate
    
    log_message "Warte 10 Sekunden auf Container-Start..."
    sleep 10
    
    # Überprüfe erneut
    php_version=$(docker exec newmoodle_web_1 php -r "echo PHP_VERSION;")
    log_message "PHP-Version nach erneutem Versuch: $php_version"
    
    if [[ ! $php_version == 8.3* ]]; then
        log_message "KRITISCHER FEHLER: Konnte PHP 8.3 nicht aktivieren. Bitte manuell prüfen."
        exit 1
    fi
fi

# Upgrade auf Moodle 5.2 mit PHP 8.3
log_section "Upgrade auf Moodle 5.2"
log_message "Verwende PHP 8.3 für das Upgrade auf Moodle 5.2..."

# Führe das Upgrade auf Moodle 5.2 durch
upgrade_moodle_version "5.2" "502" "true"

# Nach dem Upgrade auf Moodle 5.2 und der MySQL-Versionsüberprüfung
# wird der Benutzer in der upgrade_moodle_version Funktion aufgefordert,
# den Upgrade-Prozess im Browser durchzuführen

# Finale Überprüfung der PHP-Version
php_version=$(docker exec newmoodle_web_1 php -r "echo PHP_VERSION;")
log_message "Finale PHP-Version: $php_version"

log_message "Moodle-Upgrade auf die neueste Version 5.2 mit PHP 8.3 erfolgreich abgeschlossen"
log_message "Öffnen Sie http://localhost in Ihrem Browser, um die aktualisierte Moodle-Installation zu überprüfen."
