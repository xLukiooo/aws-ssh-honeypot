#!/bin/bash
# Wersja 4.0 - Finalna wersja z hardeningiem i poprawną obsługą konfiguracji Cowrie

set -e

exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

# ===================================================================
# SEKCJA 1: ZMIENNE KONFIGURACYJNE
# ===================================================================
echo "--- [ETAP 1/9] Definiowanie zmiennych konfiguracyjnych ---"

# === Zmienne Użytkownika ===
GRAFANA_ADMIN_PASSWORD="SuperTajneHaslo123!"
GEOIPUPDATE_ACCOUNT_ID="TWOJE_ID_KONTA_MAXMIND"
GEOIPUPDATE_LICENSE_KEY="TWOJ_KLUCZ_LICENCYJNY_MAXMIND"

# === Wersje Oprogramowania ===
DOCKER_COMPOSE_VERSION="v2.23.0"
COWRIE_IMAGE="cowrie/cowrie:latest"
LOKI_IMAGE="grafana/loki:2.9.2"
PROMTAIL_IMAGE="grafana/promtail:2.9.2"
GRAFANA_IMAGE="grafana/grafana:10.1.5"
GEOIPUPDATE_IMAGE="ghcr.io/maxmind/geoipupdate:latest"

# === Ścieżki ===
HONEYPOT_DIR="/opt/honeypot"
COWRIE_DIR="$HONEYPOT_DIR/cowrie"
PROMTAIL_DIR="$HONEYPOT_DIR/promtail"
LOKI_DIR="$HONEYPOT_DIR/loki"
GRAFANA_DIR="$HONEYPOT_DIR/grafana"
PCAP_DIR="$HONEYPOT_DIR/pcap_data"

# ===================================================================
# SEKCJA 2: PRZYGOTOWANIE SYSTEMU
# ===================================================================
echo "--- [ETAP 2/9] Aktualizacja systemu i instalacja podstawowych narzędzi ---"
apt-get update
apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl software-properties-common iptables-persistent tcpdump

echo "--- Tworzenie struktury katalogów dla konfiguracji ---"
mkdir -p $COWRIE_DIR/etc $COWRIE_DIR/var/lib
mkdir -p $PROMTAIL_DIR
mkdir -p $LOKI_DIR
mkdir -p $GRAFANA_DIR/provisioning/datasources $GRAFANA_DIR/data
mkdir -p $PCAP_DIR

# ===================================================================
# SEKCJA 3: INSTALACJA DOCKERA
# ===================================================================
echo "--- [ETAP 3/9] Instalacja silnika kontenerów Docker CE i Docker Compose ---"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io

curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
echo "Zainstalowano Docker i Docker Compose"

# ===================================================================
# SEKCJA 4: GENEROWANIE PLIKÓW KONFIGURACYJNYCH
# ===================================================================
echo "--- [ETAP 4/9] Generowanie plików konfiguracyjnych dla stosu Docker ---"

cat <<EOF > $HONEYPOT_DIR/docker-compose.yml
version: '3.7'

volumes:
  geoip_data:

services:
  cowrie:
    image: ${COWRIE_IMAGE}
    container_name: cowrie
    volumes:
      - $COWRIE_DIR/etc:/cowrie/etc
      - $COWRIE_DIR/var/lib:/cowrie/var/lib
    ports:
      - "2222:2222"
      - "2223:2223"
    restart: unless-stopped

  geoipupdate:
    image: ${GEOIPUPDATE_IMAGE}
    container_name: geoipupdate
    restart: always
    environment:
      - GEOIPUPDATE_ACCOUNT_ID=${GEOIPUPDATE_ACCOUNT_ID}
      - GEOIPUPDATE_LICENSE_KEY=${GEOIPUPDATE_LICENSE_KEY}
      - 'GEOIPUPDATE_EDITION_IDS=GeoLite2-City'
      - GEOIPUPDATE_FREQUENCY=72
    volumes:
      - geoip_data:/usr/share/GeoIP
    healthcheck:
      test: ["CMD", "test", "-f", "/usr/share/GeoIP/GeoLite2-City.mmdb"]
      interval: 30s
      timeout: 10s
      retries: 5

  loki:
    image: ${LOKI_IMAGE}
    container_name: loki
    volumes:
      - $LOKI_DIR:/etc/loki
    command: -config.file=/etc/loki/loki-config.yml
    ports:
      - "3100:3100"
    restart: unless-stopped

  promtail:
    image: ${PROMTAIL_IMAGE}
    container_name: promtail
    depends_on:
      geoipupdate:
        condition: service_healthy
    volumes:
      - $COWRIE_DIR/var/lib/cowrie/log:/var/log/cowrie:ro
      - $PROMTAIL_DIR/promtail.yml:/etc/promtail/promtail.yml:ro
      - geoip_data:/usr/share/GeoIP:ro
    command: -config.file=/etc/promtail/promtail.yml
    restart: unless-stopped

  grafana:
    image: ${GRAFANA_IMAGE}
    container_name: grafana
    volumes:
      - $GRAFANA_DIR/data:/var/lib/grafana
      - $GRAFANA_DIR/provisioning:/etc/grafana/provisioning
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
    ports:
      - "3000:3000"
    restart: unless-stopped
EOF

# ... (reszta plików konfiguracyjnych bez zmian)

cat <<EOF > $LOKI_DIR/loki-config.yml
auth_enabled: false
server:
  http_listen_port: 3100
ingester:
  lifecycler:
    address: 127.0.0.1
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
    final_sleep: 0s
  chunk_idle_period: 5m
  chunk_retain_period: 1m
schema_config:
  configs:
    - from: 2020-05-15
      store: boltdb
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 168h
storage_config:
  boltdb:
    directory: /tmp/loki/index
  filesystem:
    directory: /tmp/loki/chunks
EOF

cat <<EOF > $PROMTAIL_DIR/promtail.yml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
- job_name: cowrie
  static_configs:
  - targets:
      - localhost
    labels:
      job: cowrie
      __path__: /var/log/cowrie/cowrie.json*
  pipeline_stages:
  - json:
      expressions:
        timestamp: timestamp
        src_ip: src_ip
  - timestamp:
      source: timestamp
      format: RFC3339Nano
  - geoip:
      db: /usr/share/GeoIP/GeoLite2-City.mmdb
      source: src_ip
EOF

cat <<EOF > $GRAFANA_DIR/provisioning/datasources/loki.yml
apiVersion: 1
datasources:
- name: Loki
  type: loki
  access: proxy
  url: http://loki:3100
  isDefault: true
  jsonData:
    maxLines: 1000
EOF
echo "Pliki konfiguracyjne wygenerowane."

# ===================================================================
# SEKCJA 5: KONFIGURACJA I HARDENING COWRIE
# ===================================================================
echo "--- [ETAP 5/9] Konfiguracja limitów i czyszczenia plików Cowrie ---"

# Krok 1: Uruchom na chwilę Cowrie, aby wygenerowało domyślny plik konfiguracyjny
echo "Uruchamianie Cowrie w celu wygenerowania pliku konfiguracyjnego..."
/usr/local/bin/docker-compose -f $HONEYPOT_DIR/docker-compose.yml up -d cowrie
sleep 15 # Daj czas kontenerowi na stworzenie plików

# Krok 2: Edytuj plik konfiguracyjny, dodając limit rozmiaru pobieranych plików
COWRIE_CONFIG_FILE="$COWRIE_DIR/etc/cowrie.cfg"
if [ -f "$COWRIE_CONFIG_FILE" ]; then
    echo "Edytowanie pliku $COWRIE_CONFIG_FILE..."
    if grep -q "^[downloads]" "$COWRIE_CONFIG_FILE"; then
        sed -i '/^[downloads]/,/^[s]/ s/^download_max_size\s*=.*/download_max_size = 5242880/' "$COWRIE_CONFIG_FILE"
    else
        echo -e "\n[downloads]\ndownload_max_size = 5242880" >> "$COWRIE_CONFIG_FILE"
    fi
else
    echo "KRYTYCZNY BŁĄD: Plik konfiguracyjny Cowrie nie został znaleziony!"
    exit 1
fi

# Krok 3: Zatrzymaj tymczasowy kontener Cowrie
/usr/local/bin/docker-compose -f $HONEYPOT_DIR/docker-compose.yml stop cowrie

# Krok 4: Stwórz skrypt do czyszczenia katalogu z pobranym malware
DOWNLOAD_DIR="$COWRIE_DIR/var/lib/cowrie/downloads"
CLEAN_SCRIPT="/usr/local/bin/cowrie_download_cleanup.sh"
cat << EOF > "$CLEAN_SCRIPT"
#!/bin/bash
DOWNLOAD_DIR="$DOWNLOAD_DIR"
MAX_FILES=100

if [ -d "\$DOWNLOAD_DIR" ]; then
  find "\$DOWNLOAD_DIR" -type f -size +10M -delete
  TOTAL=\$(ls -1t "\$DOWNLOAD_DIR" | wc -l)
  if [ "\$TOTAL" -gt "\$MAX_FILES" ]; then
    DELETE=\$(ls -1t "\$DOWNLOAD_DIR" | tail -n +\$((MAX_FILES+1)))
    for f in \$DELETE; do
      rm -f "\$DOWNLOAD_DIR/\$f"
    done
  fi
fi
EOF
chmod +x "$CLEAN_SCRIPT"

# Krok 5: Dodaj zadanie do crona, aby skrypt uruchamiał się co godzinę
echo "0 * * * * root $CLEAN_SCRIPT" >> /etc/crontab

echo "Limity na rozmiar/ilość pobranych plików malware na Cowrie WŁĄCZONE."

# ===================================================================
# SEKCJA 6: KONFIGURACJA SIECI (PRZEKIEROWANIA)
# ===================================================================
echo "--- [ETAP 6/9] Konfiguracja sieci i zmiana portu SSH ---"
sed -i '/^#*Port /d' /etc/ssh/sshd_config
echo "Port 22222" >> /etc/ssh/sshd_config
systemctl restart sshd || { echo "KRYTYCZNY BŁĄD: Nie udało się zrestartować usługi SSHD po zmianie portu!"; exit 1; }
echo "Port systemowy SSH zmieniony na 22222."

sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

iptables -t nat -A PREROUTING -p tcp --dport 22 -j REDIRECT --to-port 2222
iptables -t nat -A PREROUTING -p tcp --dport 23 -j REDIRECT --to-port 2223
echo "Reguły NAT dla iptables zostały dodane."

# ===================================================================
# SEKCJA 7: KONFIGURACJA TCPDUMP JAKO USŁUGI
# ===================================================================
echo "--- [ETAP 7/9] Konfiguracja tcpdump jako usługi systemd ---"
cat <<EOF > /etc/systemd/system/tcpdump-honeypot.service
[Unit]
Description=TCPDump Honeypot Packet Capture
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/tcpdump -i any -w $PCAP_DIR/capture_%%Y-%%m-%%d_%%H-%%M-%%S.pcap -G 3600 -C 100 -Z root 'port 22 or port 23'
Restart=always
RestartSec=5
CPUQuota=50%
MemoryMax=500M

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now tcpdump-honeypot.service
echo "Usługa tcpdump skonfigurowana i uruchomiona."

# ===================================================================
# SEKCJA 8: URUCHOMIENIE FINALNEGO STOSU
# ===================================================================
echo "--- [ETAP 8/9] Uruchamianie finalnego stosu kontenerów Docker ---"
/usr/local/bin/docker-compose -f $HONEYPOT_DIR/docker-compose.yml up -d

echo "Oczekiwanie 15 sekund na start kontenerów..."
sleep 15
docker ps | grep cowrie || { echo "KRYTYCZNY BŁĄD: Kontener Cowrie nie uruchomił się poprawnie!"; exit 1; }
echo "Kontenery Docker uruchomione poprawnie."

# ===================================================================
# SEKCJA 9: HARDENING I FINALIZACJA
# ===================================================================
echo "--- [ETAP 9/9] Wzmacnianie bezpieczeństwa i finalizacja konfiguracji ---"

iptables -A OUTPUT -p tcp --dport 25 ! -d 127.0.0.1 -j DROP

iptables-save > /etc/iptables/rules.v4
echo "Dodano regułę blokującą ruch wychodzący na porcie 25 (SMTP)."

echo "--- Konfiguracja serwera Honeypot zakończona pomyślnie! ---"

