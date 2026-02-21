#!/bin/bash

# Stoppe bei Fehlern
set -e

DB_ROOT_PASSWORD="solarmanager"

# Fortschrittsanzeige Funktion
echo_step() {
  echo -e "\n[ $1% ] $2"
}
### 10% System Update
echo_step 10 "System aktualisieren..."
sudo apt update
sudo apt upgrade -y


# Funktion zur Installation nur wenn Paket fehlt
install_if_missing() {
  for pkg in "$@"; do
    if dpkg -s "$pkg" &> /dev/null; then
      echo "[INFO] Paket '$pkg' ist bereits installiert."
    else
      echo "[INFO] Installiere fehlendes Paket '$pkg'..."
      sudo apt install -y "$pkg"
    fi
  done
}

clear

echo "Starte automatische Erweiterung der Root-Partition..."

echo "Starte Solarmanager-Setup..."


### 20% Apache, PHP, MariaDB Installation
echo_step 20 "Installiere Apache, PHP, MariaDB und notwendige Pakete..."
install_if_missing apache2 php libapache2-mod-php mariadb-server php-mysql debconf-utils ufw sshpass

### 30% phpMyAdmin Installation
echo_step 30 "Installiere und konfiguriere phpMyAdmin..."
echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | sudo debconf-set-selections
echo "phpmyadmin phpmyadmin/app-password-confirm password $DB_ROOT_PASSWORD" | sudo debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/admin-pass password $DB_ROOT_PASSWORD" | sudo debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/app-pass password $DB_ROOT_PASSWORD" | sudo debconf-set-selections
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | sudo debconf-set-selections
install_if_missing phpmyadmin

### 40% MariaDB User Setup
echo_step 40 "MariaDB Root- und pi-User einrichten..."
sudo mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASSWORD';
CREATE USER IF NOT EXISTS 'pi'@'%' IDENTIFIED BY '$DB_ROOT_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'pi'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '$DB_ROOT_PASSWORD' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

### 50% MariaDB Konfiguration
echo_step 50 "Erlaube externen Zugriff auf MariaDB..."
sudo sed -i 's/^bind-address\s*=.*/#bind-address = 127.0.0.1/' /etc/mysql/mariadb.conf.d/50-server.cnf
sudo systemctl restart mariadb

### 60% Firewall Konfiguration
echo_step 60 "Firewall konfigurieren und Ports freigeben (22, 80, 3306, 5000)..."
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 90/tcp
sudo ufw allow 3306/tcp
sudo ufw allow 5000/tcp
sudo ufw --force enable
sudo ufw reload

### 70% Apache Konfiguration
echo_step 70 "Apache Konfiguration anpassen..."
if ! grep -q 'Include /etc/phpmyadmin/apache.conf' /etc/apache2/apache2.conf; then
  sudo bash -c "echo 'Include /etc/phpmyadmin/apache.conf' >> /etc/apache2/apache2.conf"
fi
sudo a2enmod rewrite

CONF_FILE="/etc/apache2/sites-enabled/000-default.conf"
INSERTION="<Directory \"/var/www/html\">
    RewriteEngine on
    # Don't rewrite files or directories
    RewriteCond %{REQUEST_FILENAME} -f [OR]
    RewriteCond %{REQUEST_FILENAME} -d
    RewriteRule ^ - [L]
    # Rewrite everything else to index.html to allow html5 state links
    RewriteRule ^ index.html [L]
</Directory>"

# Prüfen, ob der Block bereits existiert
if grep -q "<Directory \"/var/www/html\">" "$CONF_FILE"; then
    echo "Eintrag existiert bereits in der Datei. Keine Änderungen vorgenommen."
else
    echo "Füge den Eintrag in $CONF_FILE ein..."
    echo "" >> "$CONF_FILE"
    echo "$INSERTION" >> "$CONF_FILE"
    echo "Eintrag wurde hinzugefügt."

    # Apache neu starten
    echo "Apache wird neu gestartet..."
fi
systemctl restart apache2

### 80% .NET Core und Python Installation
echo_step 80 "Installiere .NET Core und Python APIs..."
wget -O - https://raw.githubusercontent.com/pjgpetecodes/dotnet9pi/main/install.sh | sudo bash
install_if_missing python3 python3-pip
sudo pip3 install hyundai-kia-connect-api bimmer_connected --break-system-packages

### 83% GitHub Releases herunterladen
echo_step 83 "Lade Solarmanager Backend und Frontend von GitHub herunter..."

GITHUB_RELEASE_REPO="BBessler/SolarmanagerClient"
WEB_DIR="/var/www/html"

# Funktion: Neuestes Release-Asset nach Tag-Prefix herunterladen und entpacken
download_latest_release() {
  local tag_prefix="$1"
  local target_dir="$2"
  local name="$3"

  echo "[INFO] Lade neuestes $name Release..."

  # Neuestes Release mit passendem Tag-Prefix finden
  local release_info
  release_info=$(curl -sL \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$GITHUB_RELEASE_REPO/releases")

  # Erstes Release mit passendem Tag-Prefix finden
  local asset_url
  asset_url=$(echo "$release_info" | python3 -c "
import sys, json
releases = json.load(sys.stdin)
for r in releases:
    if r['tag_name'].startswith('$tag_prefix'):
        if r['assets']:
            print(r['assets'][0]['browser_download_url'])
        break
" 2>/dev/null)

  if [ -z "$asset_url" ]; then
    echo "[FEHLER] Kein Release-Asset gefunden für $name (Tag-Prefix: $tag_prefix)"
    return 1
  fi

  local tmp_file="/tmp/${name}-latest.tar.gz"

  # Asset herunterladen (public Repo, kein Token nötig)
  curl -sL "$asset_url" -o "$tmp_file"

  # Zielverzeichnis erstellen und entpacken
  sudo mkdir -p "$target_dir"
  sudo tar -xzf "$tmp_file" -C "$target_dir"
  rm -f "$tmp_file"

  echo "[OK] $name nach $target_dir entpackt."
}

# Backend herunterladen
download_latest_release "backend-" "$WEB_DIR/backend" "Backend"

# Frontend herunterladen
download_latest_release "frontend-" "$WEB_DIR" "Frontend"

### 85% Rechte setzen
echo_step 85 "Setze Rechte für /var/www/html..."
sudo chmod -R 744 /var/www/html

### 90% Erstelle Solarmanager Service
echo_step 90 "Solarmanager Service erstellen..."
sudo tee /etc/systemd/system/solarmanager.service > /dev/null <<EOF
[Unit]
Description=Solarmanager
[Service]
WorkingDirectory=/var/www/html/backend/
ExecStart=dotnet /var/www/html/backend/Solarmanager.dll
StandardOutput=inherit
StandardError=inherit
Restart=always
KillSignal=SIGINT
User=pi
TimeoutSec=1800
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_PRINT_TELEMETRY_MESSAGE=false
Environment=ASPNETCORE_URLS="http://*:5000"
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable solarmanager.service
sudo systemctl start solarmanager.service

### 95% Apache Optimierungen
echo_step 95 "Apache Optimierungen durchführen..."
sudo usermod -a -G www-data pi
sudo chown -R -f www-data:www-data /var/www/html
sudo a2enmod proxy
sudo a2enmod proxy_http
sudo systemctl restart apache2

### 98% Virtual Host Konfiguration
echo_step 98 "Virtuellen Host für Solarmanager einrichten..."
sudo tee /etc/apache2/sites-available/solarmanager.conf > /dev/null <<EOF
<VirtualHost *:90>
    ProxyPreserveHost On
    ProxyPass / http://localhost:5000/
    ProxyPassReverse / http://localhost:5000/
    ServerName www.solarmanager.com
    ServerAlias *.solarmanager.com
    ErrorLog \${APACHE_LOG_DIR}solarmanager-error.log
    CustomLog \${APACHE_LOG_DIR}solarmanager-access.log common
</VirtualHost>
EOF

sudo a2ensite solarmanager.conf
if ! grep -q 'Listen 90' /etc/apache2/ports.conf; then
  sudo bash -c "echo 'Listen 90' >> /etc/apache2/ports.conf"
fi
sudo systemctl reload apache2
sudo systemctl restart apache2

### 99% Solardb-Datenbank erstellen und importieren (nur bei SQL-Datei und Zustimmung)
echo_step 99 "Prüfe auf vorhandene SQL-Datei und frage nach Datenbank-Wiederherstellung..."

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

### 100% Abschluss
echo_step 100 "Setze abschließende Rechte und beende Setup..."
sudo chown -R www-data:www-data /var/www/html
sudo chmod -R 775 /var/www/html
WEB_DIR="/var/www/html"

USER="pi"
GROUP="pi"

sudo chown -R $USER:$GROUP $WEB_DIR

sudo find $WEB_DIR -type d -exec chmod 755 {} \;
sudo find $WEB_DIR -type f -exec chmod 644 {} \;


clear
echo "### Einrichtung abgeschlossen! ###"
echo "Backend und Frontend wurden automatisch heruntergeladen und eingerichtet."
echo ""
echo "Nützliche Befehle:"
echo "  sudo systemctl restart solarmanager.service   # Backend neu starten"
echo "  sudo systemctl status solarmanager.service     # Status prüfen"
