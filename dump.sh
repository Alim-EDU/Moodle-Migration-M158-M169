#!/bin/bash 
# Datenbankzugangsdaten 
MYSQL_USER="debian-sys-maint" 
MYSQL_PASSWORD="vaIdfgRPSXzKbPPd" 
MYSQL_DATABASE="moodle" 
# Verzeichnis, in dem die Sicherungsdatei gespeichert wird 
BACKUP_DIR="/home/vmadmin" 
# Dateinamen für die Sicherungsdatei 
BACKUP_FILENAME="$MYSQL_DATABASE-$(date +%Y-%m-%d_%H-%M-%S).sql" 
# MySQL-Dump-Befehl 
mysqldump -u $MYSQL_USER -p$MYSQL_PASSWORD $MYSQL_DATABASE > $BACKUP_DIR/$BACKUP_FILENAME 
# Erfolgsmeldung 
echo "MySQL-Dump erfolgreich erstellt: $BACKUP_FILENAME"
