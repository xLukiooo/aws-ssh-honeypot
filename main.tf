# ===================================================================
# Dostawca Chmury i Region
# Definiuje, że używamy AWS jako naszej platformy chmurowej.
# Region 'us-east-1' został wybrany jako główny region dla tego projektu.
# ===================================================================
provider "aws" {
  region = "us-east-1"
}

# ===================================================================
# Dynamiczne Pobieranie Adresu IP Użytkownika
# Ten blok pobiera publiczny adres IP maszyny, z której uruchamiany jest Terraform.
# Jest to kluczowe dla automatycznego skonfigurowania reguły firewalla,
# która zezwala na dostęp do zarządzania serwerem (port 22222) tylko z Twojej sieci.
# ===================================================================
data "http" "my_ip" {
  url = "http://ipv4.icanhazip.com"
}

# ===================================================================
# Grupa Bezpieczeństwa (Wirtualny Firewall)
# Ten zasób definiuje reguły sieciowe dla naszej instancji EC2.
# Działa jak firewall, kontrolując ruch przychodzący i wychodzący.
# ===================================================================
resource "aws_security_group" "honeypot_sg" {
  name        = "honeypot-sg"
  description = "Reguły firewalla dla projektu Honeypot BSK2"

  # --- Reguły Ruchu Przychodzącego (Ingress) ---

  # Port 22 (SSH) jest celowo otwarty na cały świat (0.0.0.0/0).
  # To jest port-pułapka, na który będą kierowane ataki na SSH, przechwytywane przez Cowrie.
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Honeypot SSH (Cowrie)"
  }

  # Port 23 (Telnet) również jest otwarty na świat, działając jako pułapka dla ataków Telnet.
  ingress {
    from_port   = 23
    to_port     = 23
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Honeypot Telnet (Cowrie)"
  }

  # Port 22222 to port do zarządzania serwerem (prawdziwy serwer SSH).
  # Dostęp jest ograniczony wyłącznie do Twojego adresu IP, co chroni serwer przed nieautoryzowanym dostępem.
  ingress {
    from_port   = 22222
    to_port     = 22222
    protocol    = "tcp"
    cidr_blocks = ["${chomp(data.http.my_ip.body)}/32"]
    description = "Zarządzanie serwerem (SSH)"
  }

  # --- Reguły Ruchu Wychodzącego (Egress) ---

  # Zezwala instancji na nieograniczony dostęp do internetu.
  # Jest to wymagane, aby serwer mógł pobrać aktualizacje, obrazy Docker, bazę GeoIP itp.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Zezwolenie na cały ruch wychodzący"
  }
}

# ===================================================================
# Instancja Serwera (EC2)
# To jest główny zasób projektu - wirtualny serwer, na którym będzie działał nasz honeypot.
# ===================================================================
resource "aws_instance" "honeypot_instance" {
  ami                         = "ami-0360c520857e3138f" # Użycie konkretnego obrazu Ubuntu 22.04 LTS
  instance_type               = "t2.micro" # Mała, tania instancja, wystarczająca dla tego projektu.
  key_name                    = "projekt-bsk2-key" # Nazwa pary kluczy, którą musisz wcześniej stworzyć w konsoli AWS.
  vpc_security_group_ids      = [aws_security_group.honeypot_sg.id]
  associate_public_ip_address = true # Automatycznie przypisz publiczny adres IP.

  # Jawna konfiguracja dysku root, aby zapewnić wystarczającą ilość miejsca na logi i dane.
  root_block_device {
    volume_size = 30 # Zwiększamy domyślne 8GB do 30GB.
    volume_type = "gp3" # Nowoczesny i wydajny typ dysku SSD.
    delete_on_termination = true # Dysk zostanie usunięty wraz z instancją.
  }

  # To serce automatyzacji. Skrypt 'user_data.sh' zostanie wykonany przy pierwszym uruchomieniu instancji,
  # instalując i konfigurując cały stos oprogramowania (Docker, Cowrie, Grafana, etc.).
  user_data = file("user_data.sh")

  tags = {
    Name = "Honeypot-BSK2"
  }
}

# ===================================================================
# Wyjścia (Outputs)
# Te bloki wyświetlają przydatne informacje po zakończeniu działania Terraform.
# Dzięki nim nie musisz ręcznie szukać IP serwera czy składać komend do połączenia.
# ===================================================================

# Wyświetla publiczny adres IP serwera.
output "honeypot_public_ip" {
  value = aws_instance.honeypot_instance.public_ip
}

# Wyświetla gotową komendę do zalogowania się na serwer w celach administracyjnych.
output "ssh_management_command" {
  value = "ssh -i projekt-bsk2-key.pem -p 22222 ubuntu@${aws_instance.honeypot_instance.public_ip}"
}

# Wyświetla gotową komendę do stworzenia tunelu SSH, niezbędnego do bezpiecznego połączenia z Grafaną.
output "grafana_tunnel_command" {
  value = "ssh -i projekt-bsk2-key.pem -L 3000:localhost:3000 -p 22222 ubuntu@${aws_instance.honeypot_instance.public_ip}"
}

# Wyświetla gotową komendę do pobrania wszystkich przechwyconych plików .pcap.
output "tcpdump_download_command" {
  value = "scp -i projekt-bsk2-key.pem -P 22222 ubuntu@${aws_instance.honeypot_instance.public_ip}:/opt/honeypot/pcap_data/capture*.pcap ."
}

# Wyświetla przykładową komendę, jakiej użyłby atakujący, aby połączyć się z honeypotem.
output "honeypot_ssh_test_command" {
  description = "Komenda do przetestowania połączenia z honeypotem Cowrie (jako atakujący)"
  value       = "ssh root@${aws_instance.honeypot_instance.public_ip}"
}
