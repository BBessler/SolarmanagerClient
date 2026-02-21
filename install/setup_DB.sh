### 45% Solardb-Datenbank erstellen und importieren (nur bei SQL-Datei und Zustimmung)
echo_step 45 "Prüfe auf vorhandene SQL-Datei und frage nach Datenbank-Wiederherstellung..."

DB_NAME="solardb"
DB_USER="root"
DB_PASS="$DB_ROOT_PASSWORD"
SQL_FILE="solardb.sql"

echo "[INFO] Erstelle Datenbank '$DB_NAME' (falls nicht vorhanden)..."
sudo mysql -u "$DB_USER" -p"$DB_PASS" -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"

if [ -f "$SQL_FILE" ]; then
  echo "[INFO] SQL-Datei gefunden: $SQL_FILE"
  read -p "Möchten Sie die Datenbank '$DB_NAME' aus '$SQL_FILE' wiederherstellen? (j/n): " antwort
  if [[ "$antwort" =~ ^[Jj]$ ]]; then

    echo "[INFO] Importiere SQL-Daten..."
    sudo mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SQL_FILE"

    if [ $? -eq 0 ]; then
      echo "[OK] Datenbank '$DB_NAME' erfolgreich importiert."
    else
      echo "[FEHLER] Fehler beim Import der SQL-Datei."
    fi
  else
    echo "[INFO] Datenbank-Wiederherstellung abgebrochen durch Benutzer."
  fi
else
  echo "[INFO] Keine SQL-Datei gefunden – Datenbank-Wiederherstellung übersprungen."
fi
