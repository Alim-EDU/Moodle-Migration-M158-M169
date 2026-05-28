# Moodle 5.0 Migration und Upgrade

Dieses Repository enthält Skripte zur Migration einer bestehenden Moodle-Installation in einen Docker-Container und zum Upgrade auf Moodle 5.0.

## Funktionen

- **Migration**: Migriert eine bestehende Moodle-Installation in einen Docker-Container
- **Upgrade**: Führt ein schrittweises Upgrade von Moodle 3.10 auf Moodle 5.0 durch
- **MySQL-Versionskompatibilität**: Umgeht die MySQL-Versionsüberprüfung, um Moodle 5.0 mit MySQL 8.0 zu betreiben

## Voraussetzungen

- Docker und Docker Compose
- Eine bestehende Moodle-Installation (für die Migration)
- Ausreichend Speicherplatz für die Docker-Container und Volumes

## Anleitung zur Migration

1. Klone dieses Repository:
   ```bash
   git clone https://github.com/levinfritz/Realisierung_M169.git
   cd Realisierung_M169
   ```

2. Erstelle eine `.env`-Datei mit den folgenden Inhalten (passe die Werte an):
   ```
   MYSQL_ROOT_PASSWORD=Secret
   MYSQL_DATABASE=moodle
   MYSQL_USER=moodle
   MYSQL_PASSWORD=Secret
   ```

3. Führe zuerst das Umstellungsskript aus, um die alte Instanz auf Port 8080 zu verschieben (damit Port 80 frei wird):
   ```bash
   sudo bash reconfigure_old_moodle.sh
   ```

4. Führe das Migrationsskript aus:
   ```bash
   bash moodle_migration.sh
   ```

5. Folge den Anweisungen auf dem Bildschirm. Am Ende der Migration wirst du gefragt, ob du direkt mit dem Upgrade fortfahren möchtest.

## Manuelles Upgrade

Falls du das Upgrade später durchführen möchtest:

```bash
bash moodle_upgrade.sh
```

Das Upgrade-Skript führt folgende Schritte durch:
1. Aktualisiert die PHP-Version schrittweise (8.1 -> 8.3)
2. Führt ein optimiertes Upgrade von Moodle durch:
   * Moodle 4.2 → 4.4 (mit PHP 8.1 / DocumentRoot `/var/www/html`)
   * Moodle 4.4 → 5.2 (mit PHP 8.3 / DocumentRoot `/var/www/html/public`)
3. Passt die Apache-Konfiguration dynamisch an, um den neuen ab Moodle 5.1 geforderten `/public`-Ordner als Webroot zu nutzen.
4. Umgeht die MySQL-Versionsüberprüfung, um Moodle 5.2 mit MySQL 8.0/8.4 betreiben zu können.

## Hinweise

- Die Skripte sind für eine lokale Entwicklungsumgebung konzipiert
- Für Produktionsumgebungen sollten zusätzliche Sicherheitsmaßnahmen implementiert werden
- Erstelle immer ein Backup deiner Daten, bevor du die Migration oder das Upgrade durchführst

## Fehlerbehebung

Bei Problemen während der Migration oder des Upgrades:

1. Überprüfe die Docker-Container-Logs:
   ```bash
   docker logs newmoodle_web_1
   docker logs newmoodle_db_1
   ```

2. Stelle sicher, dass die Docker-Container laufen:
   ```bash
   docker ps
   ```

3. Überprüfe die Datenbankverbindung:
   ```bash
   docker exec -it newmoodle_db_1 mysql -u root -pSecret -e "SHOW DATABASES;"
   ```
