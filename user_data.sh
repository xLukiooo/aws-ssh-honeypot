#!/bin/bash
# Wersja 3.0 - Architektura z poprawkami stabilności i bezpieczeństwa

set -e

exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

# ===================================================================
# SEKCJA 1: ZMIENNE KONFIGURACYJNE
# ===================================================================
echo "--- [ETAP 1/8] Definiowanie zmiennych konfiguracyjnych ---"

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
echo "--- [ETAP 2/8] Aktualizacja systemu i instalacja podstawowych narzędzi ---"
apt-get update
apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl software-properties-common iptables-persistent tcpdump

echo "--- Tworzenie struktury katalogów dla konfiguracji ---"
mkdir -p $COWRIE_DIR/etc $COWRIE_DIR/var/lib/log
mkdir -p $PROMTAIL_DIR
mkdir -p $LOKI_DIR
mkdir -p $GRAFANA_DIR/provisioning/datasources $GRAFANA_DIR/data
mkdir -p $PCAP_DIR

# ===================================================================
# SEKCJA 3: INSTALACJA DOCKERA
# ===================================================================
echo "--- [ETAP 3/8] Instalacja silnika kontenerów Docker CE i Docker Compose ---"
# Poprawka 1: Nowa, zalecana metoda dodawania klucza GPG Dockera
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
echo "--- [ETAP 4/8] Generowanie plików konfiguracyjnych dla stosu Docker ---"

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
      # Poprawka 2: Precyzyjne mapowanie katalogu z logami Cowrie
      - $COWRIE_DIR/var/lib/log:/cowrie/var/lib/log
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
    # Poprawka 3: Healthcheck sprawdzający, czy baza GeoIP została pobrana
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
    # Poprawka 3: Promtail poczeka, aż usługa geoipupdate będzie "zdrowa"
    depends_on:
      geoipupdate:
        condition: service_healthy
    volumes:
      # Poprawka 2: Precyzyjne mapowanie katalogu z logami Cowrie
      - $COWRIE_DIR/var/lib/log:/var/log/cowrie:ro
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
      # Poprawka 2: Ścieżka do logów jest teraz prostsza dzięki lepszemu mapowaniu
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
# SEKCJA 5: KONFIGURACJA SIECI (PRZEKIEROWANIA)
# ===================================================================
echo "--- [ETAP 5/8] Konfiguracja sieci i zmiana portu SSH ---"
# Poprawka 5: Bezpieczna, idempotentna metoda zmiany portu SSH
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
# SEKCJA 6: KONFIGURACJA TCPDUMP JAKO USŁUGI
# ===================================================================
echo "--- [ETAP 6/8] Konfiguracja tcpdump jako usługi systemd ---"
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
# SEKCJA 7: URUCHOMIENIE STOSU I WZMACNIANIE BEZPIECZEŃSTWA
# ===================================================================
echo "--- [ETAP 7/8] Uruchamianie kontenerów Docker ---"
/usr/local/bin/docker-compose -f $HONEYPOT_DIR/docker-compose.yml up -d

# Poprawka 8: Weryfikacja, czy kontenery wstały
echo "Oczekiwanie 15 sekund na start kontenerów..."
sleep 15
docker ps | grep cowrie || { echo "KRYTYCZNY BŁĄD: Kontener Cowrie nie uruchomił się poprawnie!"; exit 1; }
echo "Kontenery Docker uruchomione poprawnie."

# ===================================================================
# SEKCJA 8: HARDENING I FINALIZACJA
# ===================================================================
echo "--- [ETAP 8/8] Wzmacnianie bezpieczeństwa: Ograniczanie ruchu wychodzącego ---"

# Poprawka 7: Blokujemy tylko ruch zewnętrzny na porcie 25, aby nie zakłócać komunikacji lokalnej.
iptables -A OUTPUT -p tcp --dport 25 ! -d 127.0.0.1 -j DROP

# Poprawka 6: Zapisujemy wszystkie reguły (NAT i OUTPUT) tylko raz, na samym końcu.
iptables-save > /etc/iptables/rules.v4
echo "Dodano regułę blokującą ruch wychodzący na porcie 25 (SMTP). Konfiguracja zakończona."

echo "--- Konfiguracja serwera Honeypot zakończona pomyślnie! ---"

