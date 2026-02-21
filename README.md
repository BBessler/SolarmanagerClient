# Solarmanager - Installation

Energiemanagementsystem zur intelligenten Steuerung von PV-Anlagen, Wallboxen, Batteriespeichern und Fahrzeugladung.

## Voraussetzungen

- Raspberry Pi (empfohlen: Pi 4 oder neuer) mit Raspberry Pi OS (Debian-basiert)
- Internetverbindung
- SSH-Zugang zum Pi

## Installation

### 1. Setup-Script herunterladen und ausführen

Per SSH auf dem Raspberry Pi einloggen und folgende Befehle ausführen:

```bash
wget https://raw.githubusercontent.com/BBessler/SolarmanagerClient/main/install/setup_solarmanager.sh
chmod +x setup_solarmanager.sh
sudo ./setup_solarmanager.sh
```

Das Script installiert und konfiguriert automatisch:
- Apache Webserver mit PHP
- MariaDB Datenbank
- phpMyAdmin
- .NET Runtime
- Python-Abhängigkeiten (Hyundai/BMW API)
- Firewall (UFW)
- Solarmanager Backend & Frontend (neuestes Release)
- Systemd-Service für den automatischen Start

### 2. SSL aktivieren (optional)

HTTPS mit Self-Signed-Zertifikat einrichten:

```bash
wget https://raw.githubusercontent.com/BBessler/SolarmanagerClient/main/install/setup_ssl.sh
chmod +x setup_ssl.sh
sudo ./setup_ssl.sh
```

Nach der SSL-Einrichtung:
- Frontend: `https://solarmanager.local`
- Backend-API: `https://solarmanager.local:453`

> **Hinweis:** Da ein Self-Signed-Zertifikat verwendet wird, muss die Sicherheitswarnung im Browser einmalig bestätigt werden.

## Zugriff nach der Installation

| Dienst | URL |
|--------|-----|
| Frontend | `http://solarmanager.local` |
| Backend-API | `http://solarmanager.local:90` |
| phpMyAdmin | `http://solarmanager.local/phpmyadmin` |

## Nützliche Befehle

```bash
# Backend neu starten
sudo systemctl restart solarmanager.service

# Backend-Status prüfen
sudo systemctl status solarmanager.service

# Backend-Logs anzeigen
sudo journalctl -u solarmanager.service -f
```

## Update

Um auf die neueste Version zu aktualisieren, das Setup-Script erneut ausführen. Bestehende Konfigurationen und die Datenbank bleiben erhalten.
