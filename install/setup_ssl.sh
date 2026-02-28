#!/bin/bash

# SSL-Setup für Solarmanager
# Aktiviert HTTPS mit Self-Signed-Zertifikat für Frontend (443) und Backend-API (453)
# HTTP (80/90) wird auf HTTPS umgeleitet
# Idempotent - kann mehrfach ausgeführt werden

set -e

# Fortschrittsanzeige Funktion
echo_step() {
  echo -e "\n[ $1% ] $2"
}

### 10% Apache SSL-Module aktivieren
echo_step 10 "Apache SSL-Module aktivieren..."
sudo a2enmod ssl
sudo a2enmod headers
sudo a2enmod rewrite

### 20% IP-Adresse ermitteln
echo_step 20 "IP-Adresse ermitteln..."
IP_ADDR=$(hostname -I | awk '{print $1}')
if [ -z "$IP_ADDR" ]; then
  IP_ADDR="127.0.0.1"
  echo "[WARN] Keine Netzwerk-IP gefunden, verwende $IP_ADDR als Fallback."
else
  echo "[INFO] Erkannte IP-Adresse: $IP_ADDR"
fi

### 30% Self-Signed-Zertifikat generieren
echo_step 30 "SSL-Zertifikat prüfen/generieren..."
CERT_DIR="/etc/ssl/solarmanager"
CERT_FILE="$CERT_DIR/solarmanager.crt"
KEY_FILE="$CERT_DIR/solarmanager.key"

if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
  echo "[INFO] Zertifikat existiert bereits in $CERT_DIR - überspringe Generierung."
else
  echo "[INFO] Generiere neues Self-Signed-Zertifikat (10 Jahre)..."
  sudo mkdir -p "$CERT_DIR"
  sudo openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=solarmanager.local" \
    -addext "subjectAltName=DNS:solarmanager.local,DNS:localhost,IP:$IP_ADDR"
  sudo chmod 600 "$KEY_FILE"
  sudo chmod 644 "$CERT_FILE"
  echo "[OK] Zertifikat generiert."
fi

### 50% HTTPS VirtualHost für Frontend (Port 443)
echo_step 50 "HTTPS VirtualHost für Frontend (Port 443) einrichten..."
sudo tee /etc/apache2/sites-available/solarmanager-ssl.conf > /dev/null <<EOF
<VirtualHost *:443>
    ServerName solarmanager.local
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile $CERT_FILE
    SSLCertificateKeyFile $KEY_FILE

    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"

    <Directory "/var/www/html">
        RewriteEngine on
        # Don't rewrite files or directories
        RewriteCond %{REQUEST_FILENAME} -f [OR]
        RewriteCond %{REQUEST_FILENAME} -d
        RewriteRule ^ - [L]
        # Rewrite everything else to index.html to allow html5 state links
        RewriteRule ^ index.html [L]
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/solarmanager-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/solarmanager-ssl-access.log common
</VirtualHost>
EOF

### 60% HTTPS VirtualHost für Backend-API (Port 453)
echo_step 60 "HTTPS VirtualHost für Backend-API (Port 453) einrichten..."
sudo tee /etc/apache2/sites-available/solarmanager-api-ssl.conf > /dev/null <<EOF
<VirtualHost *:453>
    ServerName solarmanager.local
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

### 70% HTTP→HTTPS Redirects einrichten
echo_step 70 "HTTP→HTTPS Redirects einrichten..."

# Frontend Redirect (Port 80 → 443)
sudo tee /etc/apache2/sites-available/solarmanager-redirect.conf > /dev/null <<EOF
<VirtualHost *:80>
    ServerName solarmanager.local
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{HTTP_HOST}\$1 [R=301,L]
</VirtualHost>
EOF

# Backend-API Redirect (Port 90 → 453)
sudo tee /etc/apache2/sites-available/solarmanager-api-redirect.conf > /dev/null <<EOF
<VirtualHost *:90>
    ServerName solarmanager.local
    RewriteEngine On
    # HTTP_HOST kann bei Port 90 den Port enthalten (z.B. "host:90") - daher Port abschneiden
    RewriteCond %{HTTP_HOST} ^(.+?)(?::90)?$
    RewriteRule ^(.*)$ https://%1:453\$1 [R=301,L]
</VirtualHost>
EOF

### 80% Ports in ports.conf eintragen
echo_step 80 "Ports in Apache ports.conf eintragen..."
if ! grep -q 'Listen 443' /etc/apache2/ports.conf; then
  sudo bash -c "echo 'Listen 443' >> /etc/apache2/ports.conf"
  echo "[INFO] Port 443 hinzugefügt."
else
  echo "[INFO] Port 443 bereits konfiguriert."
fi

if ! grep -q 'Listen 453' /etc/apache2/ports.conf; then
  sudo bash -c "echo 'Listen 453' >> /etc/apache2/ports.conf"
  echo "[INFO] Port 453 hinzugefügt."
else
  echo "[INFO] Port 453 bereits konfiguriert."
fi

### 85% Firewall-Ports öffnen
echo_step 85 "Firewall-Ports für HTTPS öffnen..."
sudo ufw allow 443/tcp
sudo ufw allow 453/tcp
sudo ufw reload

### 90% Alte HTTP-Sites deaktivieren und neue Sites aktivieren
echo_step 90 "Apache Sites aktivieren..."

# Alte HTTP-Sites deaktivieren (Redirects ersetzen sie)
sudo a2dissite 000-default.conf 2>/dev/null || true
sudo a2dissite solarmanager.conf 2>/dev/null || true

# Neue Sites aktivieren
sudo a2ensite solarmanager-ssl.conf
sudo a2ensite solarmanager-api-ssl.conf
sudo a2ensite solarmanager-redirect.conf
sudo a2ensite solarmanager-api-redirect.conf

### 100% Apache neustarten
echo_step 100 "Apache neustarten..."
sudo systemctl restart apache2

echo ""
echo "### SSL-Setup abgeschlossen! ###"
echo ""
echo "Frontend:    https://solarmanager.local"
echo "Backend-API: https://solarmanager.local:453"
echo ""
echo "HTTP-Redirects aktiv:"
echo "  http://solarmanager.local      → https://solarmanager.local"
echo "  http://solarmanager.local:90   → https://solarmanager.local:453"
echo ""
echo "Zertifikat: $CERT_FILE"
echo ""
echo "Hinweis: Da es ein Self-Signed-Zertifikat ist, muss im Browser"
echo "         die Sicherheitswarnung einmalig bestätigt werden."
