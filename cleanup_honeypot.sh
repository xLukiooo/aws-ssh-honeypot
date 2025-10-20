#!/bin/bash

set -e
echo "=== ROZPOCZYNANIE CZYSZCZENIA ŚRODOWISKA HONEYPOT ==="

# Sprawdzenie uprawnień roota
if [ "$EUID" -ne 0 ]; then
  echo "BŁĄD: Ten skrypt musi być uruchomiony z uprawnieniami roota (użyj sudo)."
  exit 1
fi

# --- Krok 1: Zatrzymanie i usunięcie usług i kontenerów ---
echo "--- Krok 1: Zatrzymywanie usług i kontenerów Docker ---"

# Zatrzymanie serwisu tcpdump
echo "Zatrzymywanie serwisu tcpdump-honeypot..."
systemctl stop tcpdump-honeypot.service || echo "Ostrzeżenie: Nie udało się zatrzymać tcpdump-honeypot.service (może nie istnieje)."
systemctl disable tcpdump-honeypot.service || echo "Ostrzeżenie: Nie udało się wyłączyć tcpdump-honeypot.service."

# Zatrzymanie i usunięcie kontenerów Docker
if [ -f /opt/honeypot/docker-compose.yml ] && [ -f /usr/local/bin/docker-compose ]; then
  echo "Zatrzymywanie i usuwanie kontenerów z docker-compose..."
  cd /opt/honeypot && /usr/local/bin/docker-compose down --volumes --rmi all || echo "Ostrzeżenie: docker-compose down nie powiodło się. Kontynuuję."
else
  echo "Plik docker-compose.yml lub program docker-compose nie znaleziony, pomijam."
fi

# --- Krok 2: Czyszczenie reguł firewalla i konfiguracji sieci ---
echo "--- Krok 2: Czyszczenie reguł firewalla i sieci ---"

# Usunięcie reguł iptables
echo "Czyszczenie reguł iptables..."
# Usunięcie reguły z DOCKER-USER (jeśli istnieje)
iptables -D DOCKER-USER -s 172.20.0.100 ! -d 172.20.0.0/24 -j DROP 2>/dev/null || echo "Reguła dla Cowrie w DOCKER-USER nie istniała lub nie została znaleziona."
# Usunięcie reguły PREROUTING
iptables -t nat -D PREROUTING -p tcp --dport 22 -j REDIRECT --to-port 2222 2>/dev/null || echo "Reguła PREROUTING nie istniała lub nie została znaleziona."
# Zapisanie pustych reguł
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

# Przywrócenie domyślnego portu SSH
echo "Przywracanie domyślnego portu SSH (22)..."
sed -i '/^Port 22222/d' /etc/ssh/sshd_config
if ! grep -q "^Port 22" /etc/ssh/sshd_config && ! grep -q "^#Port 22" /etc/ssh/sshd_config; then
    echo "Port 22" >> /etc/ssh/sshd_config
fi
systemctl restart sshd

# Wyłączenie IP forwarding
echo "Wyłączanie IP forwarding..."
sed -i '/^net.ipv4.ip_forward=1/d' /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=0

# --- Krok 3: Odinstalowanie pakietów ---
echo "--- Krok 3: Odinstalowywanie pakietów ---"

# Odinstalowanie Dockera
if command -v docker &> /dev/null; then
    echo "Odinstalowywanie Dockera..."
    apt-get purge -y docker-ce docker-ce-cli containerd.io
    apt-get autoremove -y --purge
    rm -rf /var/lib/docker
    rm -rf /var/lib/containerd
fi

# Usunięcie klucza GPG i repozytorium Dockera
rm -f /etc/apt/keyrings/docker.gpg
rm -f /etc/apt/sources.list.d/docker.list

# Odinstalowanie pozostałych pakietów
echo "Odinstalowywanie pozostałych zależności..."
apt-get purge -y tcpdump iptables-persistent
apt-get autoremove -y

# --- Krok 4: Usuwanie plików i katalogów ---
echo "--- Krok 4: Usuwanie plików i katalogów ---"

# Usunięcie katalogu honeypota
echo "Usuwanie /opt/honeypot..."
rm -rf /opt/honeypot

# Usunięcie skryptów i usług
echo "Usuwanie plików usług i skryptów..."
rm -f /etc/systemd/system/tcpdump-honeypot.service
rm -f /usr/local/bin/cowrie_cleanup.sh
rm -f /usr/local/bin/docker-compose

# Usunięcie wpisu z crona
echo "Usuwanie zadania cron..."
sed -i '/cowrie_cleanup.sh/d' /etc/crontab

# --- Krok 5: Końcowe czyszczenie ---
echo "--- Krok 5: Końcowe czyszczenie ---"
apt-get update
systemctl daemon-reload

echo "=== CZYSZCZENIE ZAKOŃCZONE ==="
echo "UWAGA: Usługa SSH została przywrócona na port 22."
echo "Zalecane jest ponowne uruchomienie maszyny."
