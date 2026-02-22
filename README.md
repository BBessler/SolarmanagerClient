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
- Apache Webserver mit PHP und SSL (Self-Signed-Zertifikat)
- MariaDB Datenbank
- phpMyAdmin
- .NET Runtime
- Python-Abhängigkeiten (Hyundai/BMW API)
- Firewall (UFW)
- Solarmanager Backend & Frontend (neuestes Release)
- Systemd-Service für den automatischen Start
- HTTP → HTTPS Redirects

### 2. Datenbank einrichten (optional)

Falls eine bestehende Datenbank-Sicherung (`solardb.sql`) importiert werden soll:

```bash
wget https://raw.githubusercontent.com/BBessler/SolarmanagerClient/main/install/setup_DB.sh
chmod +x setup_DB.sh
sudo ./setup_DB.sh
```

## Zugriff nach der Installation

| Dienst | URL |
|--------|-----|
| Frontend | `https://solarmanager.local` |
| Backend-API | `https://solarmanager.local:453` |
| phpMyAdmin | `https://solarmanager.local/phpmyadmin` |

> **Hinweis:** Da ein Self-Signed-Zertifikat verwendet wird, zeigt der Browser beim ersten Zugriff eine Sicherheitswarnung an. Diese muss einmalig bestätigt werden:
> - **Chrome/Edge:** „Erweitert" → „Weiter zu … (unsicher)"
> - **Firefox:** „Erweitert…" → „Risiko akzeptieren und fortfahren"
> - **Safari:** „Details einblenden" → „Diese Website besuchen"
>
> Die Warnung erscheint sowohl für das Frontend (Port 443) als auch für die Backend-API (Port 453) – beide müssen einmalig bestätigt werden.

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

Um Backend und Frontend auf die neueste Version zu aktualisieren:

```bash
wget -O update_solarmanager.sh https://raw.githubusercontent.com/BBessler/SolarmanagerClient/main/install/update_solarmanager.sh
chmod +x update_solarmanager.sh
sudo ./update_solarmanager.sh
```

Das Update-Script:
- Lädt die neuesten Releases herunter
- Sichert und stellt die Frontend-Konfiguration (`config.json`) automatisch wieder her
- Startet das Backend neu
