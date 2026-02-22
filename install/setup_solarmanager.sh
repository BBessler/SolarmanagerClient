#!/bin/bash

# Stoppe bei Fehlern
set -e

# Fortschrittsanzeige Funktion
echo_step() {
  echo -e "\n[ $1% ] $2"
}

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

echo "### Solarmanager Setup ###"
echo ""

### Alle Benutzereingaben am Anfang sammeln
IP_ADDR=$(hostname -I | awk '{print $1}')
if [ -z "$IP_ADDR" ]; then
  IP_ADDR="127.0.0.1"
fi

echo "Erkannte IP-Adresse: $IP_ADDR"
echo ""
echo "Unter welcher Adresse soll der Solarmanager erreichbar sein?"
echo "  Beispiele: solarmanager.local, 192.168.178.50, mein-solar.home"
echo ""
read -p "Hostname/IP [solarmanager.local]: " SERVER_HOST
SERVER_HOST="${SERVER_HOST:-solarmanager.local}"
echo ""
read -p "MariaDB Root-Passwort [solarmanager]: " DB_ROOT_PASSWORD
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-solarmanager}"
echo ""
echo "[INFO] Hostname:      $SERVER_HOST"
echo "[INFO] DB-Passwort:   $DB_ROOT_PASSWORD"
echo ""
echo "Starte Installation..."


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

SQL_FILE=$(mktemp)
cat > "$SQL_FILE" <<SQLEOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASSWORD';
CREATE USER IF NOT EXISTS 'pi'@'%' IDENTIFIED BY '$DB_ROOT_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'pi'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '$DB_ROOT_PASSWORD' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQLEOF

# set -e deaktivieren, da der erste Versuch fehlschlagen darf
set +e
sudo mysql < "$SQL_FILE" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  sudo mysql -u root -p"$DB_ROOT_PASSWORD" < "$SQL_FILE" > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "[FEHLER] MariaDB-Zugang fehlgeschlagen. Bitte Passwort pruefen."
    rm -f "$SQL_FILE"
    exit 1
  fi
fi
set -e
rm -f "$SQL_FILE"
echo "[OK] MariaDB User eingerichtet."

### 50% MariaDB Konfiguration
echo_step 50 "Erlaube externen Zugriff auf MariaDB..."
sudo sed -i 's/^bind-address\s*=.*/#bind-address = 127.0.0.1/' /etc/mysql/mariadb.conf.d/50-server.cnf
sudo systemctl restart mariadb

### 55% Firewall Konfiguration
echo_step 55 "Firewall konfigurieren und Ports freigeben..."
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 90/tcp
sudo ufw allow 443/tcp
sudo ufw allow 453/tcp
sudo ufw allow 3306/tcp
sudo ufw allow 5000/tcp
sudo ufw --force enable
sudo ufw reload

### 60% Apache Module aktivieren
echo_step 60 "Apache Module aktivieren..."
if ! grep -q 'Include /etc/phpmyadmin/apache.conf' /etc/apache2/apache2.conf; then
  sudo bash -c "echo 'Include /etc/phpmyadmin/apache.conf' >> /etc/apache2/apache2.conf"
fi
sudo a2enmod rewrite
sudo a2enmod ssl
sudo a2enmod headers
sudo a2enmod proxy
sudo a2enmod proxy_http

### 63% SSL-Zertifikat generieren
echo_step 63 "SSL-Zertifikat generieren..."
CERT_DIR="/etc/ssl/solarmanager"
CERT_FILE="$CERT_DIR/solarmanager.crt"
KEY_FILE="$CERT_DIR/solarmanager.key"

# Zertifikat immer neu generieren, damit der Hostname stimmt
echo "[INFO] Generiere Self-Signed-Zertifikat (10 Jahre) fuer '$SERVER_HOST'..."
sudo mkdir -p "$CERT_DIR"

# SubjectAltName je nach Eingabe (IP oder DNS)
SAN_ENTRIES="DNS:localhost,IP:$IP_ADDR"
if [[ "$SERVER_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  SAN_ENTRIES="IP:$SERVER_HOST,DNS:localhost"
else
  SAN_ENTRIES="DNS:$SERVER_HOST,DNS:localhost,IP:$IP_ADDR"
fi

sudo openssl req -x509 -nodes -days 3650 \
  -newkey rsa:2048 \
  -keyout "$KEY_FILE" \
  -out "$CERT_FILE" \
  -subj "/CN=$SERVER_HOST" \
  -addext "subjectAltName=$SAN_ENTRIES"
sudo chmod 600 "$KEY_FILE"
sudo chmod 644 "$CERT_FILE"
echo "[OK] Zertifikat generiert."

### 66% Apache VirtualHosts einrichten
echo_step 66 "Apache VirtualHosts einrichten..."

# HTTPS Frontend (Port 443)
sudo tee /etc/apache2/sites-available/solarmanager-ssl.conf > /dev/null <<EOF
<VirtualHost *:443>
    ServerName $SERVER_HOST
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile $CERT_FILE
    SSLCertificateKeyFile $KEY_FILE

    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"

    <Directory "/var/www/html">
        RewriteEngine on
        RewriteCond %{REQUEST_FILENAME} -f [OR]
        RewriteCond %{REQUEST_FILENAME} -d
        RewriteRule ^ - [L]
        RewriteRule ^ index.html [L]
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/solarmanager-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/solarmanager-ssl-access.log common
</VirtualHost>
EOF

# HTTPS Backend-API (Port 453)
sudo tee /etc/apache2/sites-available/solarmanager-api-ssl.conf > /dev/null <<EOF
<VirtualHost *:453>
    ServerName $SERVER_HOST
    ProxyPreserveHost On
    ProxyPass / http://localhost:5000/
    ProxyPassReverse / http://localhost:5000/

    SSLEngine on
    SSLCertificateFile $CERT_FILE
    SSLCertificateKeyFile $KEY_FILE

    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"

    ErrorLog \${APACHE_LOG_DIR}/solarmanager-api-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/solarmanager-api-ssl-access.log common
</VirtualHost>
EOF

# HTTP→HTTPS Redirect Frontend (Port 80 → 443)
sudo tee /etc/apache2/sites-available/solarmanager-redirect.conf > /dev/null <<EOF
<VirtualHost *:80>
    ServerName $SERVER_HOST
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{HTTP_HOST}\$1 [R=301,L]
</VirtualHost>
EOF

# HTTP→HTTPS Redirect Backend-API (Port 90 → 453)
sudo tee /etc/apache2/sites-available/solarmanager-api-redirect.conf > /dev/null <<EOF
<VirtualHost *:90>
    ServerName $SERVER_HOST
    RewriteEngine On
    RewriteCond %{HTTP_HOST} ^(.+?)(?::90)?$
    RewriteRule ^(.*)$ https://%1:453\$1 [R=301,L]
</VirtualHost>
EOF

# Ports eintragen
if ! grep -q 'Listen 443' /etc/apache2/ports.conf; then
  sudo bash -c "echo 'Listen 443' >> /etc/apache2/ports.conf"
fi
if ! grep -q 'Listen 453' /etc/apache2/ports.conf; then
  sudo bash -c "echo 'Listen 453' >> /etc/apache2/ports.conf"
fi
if ! grep -q 'Listen 90' /etc/apache2/ports.conf; then
  sudo bash -c "echo 'Listen 90' >> /etc/apache2/ports.conf"
fi

# Alte Sites deaktivieren, neue aktivieren
sudo a2dissite 000-default.conf 2>/dev/null || true
sudo a2dissite solarmanager.conf 2>/dev/null || true
sudo a2ensite solarmanager-ssl.conf
sudo a2ensite solarmanager-api-ssl.conf
sudo a2ensite solarmanager-redirect.conf
sudo a2ensite solarmanager-api-redirect.conf
sudo systemctl restart apache2

### 80% .NET Core und Python Installation
echo_step 80 "Installiere .NET Core und Python APIs..."
wget -O - https://raw.githubusercontent.com/pjgpetecodes/dotnet9pi/main/install.sh | sudo bash
install_if_missing python3 python3-pip python3-dev build-essential libffi-dev libjpeg-dev zlib1g-dev libicu-dev
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

### 84% Frontend-Konfiguration anpassen
echo_step 84 "Frontend Backend-URL konfigurieren..."
sudo tee "$WEB_DIR/config.json" > /dev/null <<EOF
{
  "API_URL": "https://$SERVER_HOST:453/",
  "APP_ENV": "production"
}
EOF
echo "[OK] Frontend config.json auf 'https://$SERVER_HOST:453/' gesetzt."

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

### 95% Apache Benutzerrechte
echo_step 95 "Apache Benutzerrechte setzen..."
sudo usermod -a -G www-data pi

### 97% Solardb-Datenbank erstellen und importieren (nur bei SQL-Datei und Zustimmung)
echo_step 99 "Prüfe auf vorhandene SQL-Datei und frage nach Datenbank-Wiederherstellung..."

DB_NAME="solardb"
DB_USER="root"
DB_PASS="$DB_ROOT_PASSWORD"
SQL_FILE="solardb.sql"

echo "[INFO] Erstelle Datenbank '$DB_NAME' (falls nicht vorhanden)..."
sudo mysql -u root -p"$DB_ROOT_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"

if [ -f "$SQL_FILE" ]; then
  echo "[INFO] SQL-Datei gefunden: $SQL_FILE"
  read -p "Möchten Sie die Datenbank '$DB_NAME' aus '$SQL_FILE' wiederherstellen? (j/n): " antwort
  if [[ "$antwort" =~ ^[Jj]$ ]]; then

    echo "[INFO] Importiere SQL-Daten..."
    sudo mysql -u root -p"$DB_ROOT_PASSWORD" "$DB_NAME" < "$SQL_FILE"

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
echo "Zugriff:"
echo "  Frontend:    https://$SERVER_HOST"
echo "  Backend-API: https://$SERVER_HOST:453"
echo "  phpMyAdmin:  https://$SERVER_HOST/phpmyadmin"
echo ""
echo "HTTP-Redirects aktiv:"
echo "  http://$SERVER_HOST      -> https://$SERVER_HOST"
echo "  http://$SERVER_HOST:90   -> https://$SERVER_HOST:453"
echo ""
echo "Hinweis: Self-Signed-Zertifikat - Sicherheitswarnung im Browser einmalig bestaetigen."
echo ""
echo "Nuetzliche Befehle:"
echo "  sudo systemctl restart solarmanager.service   # Backend neu starten"
echo "  sudo systemctl status solarmanager.service     # Status pruefen"
