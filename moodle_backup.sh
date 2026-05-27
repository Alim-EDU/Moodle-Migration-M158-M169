#!/bin/bash 
# =================================================================
# Automatisches Moodle-Datenbank-Backup-Skript
# 
# Dieses Skript erstellt automatisch einen SQL-Dump der Moodle-Datenbank
# mit Zeitstempel im Dateinamen und speichert ihn im angegebenen Verzeichnis.
# =================================================================

# Datenbankzugangsdaten aus Umgebungsvariablen laden
if [ -z "$DOCKER_DB_PASSWORD" ]; then
    echo "FEHLER: Die Umgebungsvariable DOCKER_DB_PASSWORD ist nicht gesetzt."
    exit 1
fi
MYSQL_PASSWORD="$DOCKER_DB_PASSWORD"

# Datenbankkonfiguration
MYSQL_USER="root"
MYSQL_DATABASE="moodle"

# Verzeichnis, in dem die Sicherungsdatei gespeichert wird
BACKUP_DIR="/var/lib/mysql/backups"

# Sicherstellen, dass das Backup-Verzeichnis existiert
mkdir -p $BACKUP_DIR

# Dateinamen für die Sicherungsdatei mit Zeitstempel
BACKUP_FILENAME="$MYSQL_DATABASE-$(date +%Y-%m-%d_%H-%M-%S)-UTC.sql" 

# Protokollierung starten
echo "===== Moodle-Datenbank-Backup gestartet: $(date) ====="
echo "Datenbank: $MYSQL_DATABASE"
echo "Zieldatei: $BACKUP_DIR/$BACKUP_FILENAME"

# MySQL-Dump-Befehl ausführen
mysqldump -u $MYSQL_USER -p$MYSQL_PASSWORD $MYSQL_DATABASE > $BACKUP_DIR/$BACKUP_FILENAME 

# Status überprüfen und Ergebnis protokollieren
if [ $? -eq 0 ]; then
    echo "✓ MySQL-Dump erfolgreich erstellt: $BACKUP_FILENAME"
    echo "✓ Dateigröße: $(du -h $BACKUP_DIR/$BACKUP_FILENAME | cut -f1)"
    
    # Alte Backups bereinigen (optional: behält nur Backups der letzten 7 Tage)
    find $BACKUP_DIR -name "$MYSQL_DATABASE-*.sql" -type f -mtime +7 -delete
    echo "✓ Alte Backups wurden bereinigt"
else
    echo "✗ FEHLER: Backup konnte nicht erstellt werden"
fi

echo "===== Backup-Vorgang abgeschlossen: $(date) ====="
