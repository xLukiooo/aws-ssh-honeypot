# ===================================================================
# Provider Configuration
# ===================================================================
provider "aws" {
  region = "us-east-1"
}


# ===================================================================
# Dynamiczne pobieranie IP administratora
# ===================================================================
data "http" "my_ip" {
  url = "https://ipv4.icanhazip.com"
}


# ===================================================================
# VPC + publiczny subnet + IGW + trasa do internetu
# ===================================================================
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "honeypot-vpc" }
}


resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "honeypot-igw" }
}


resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "honeypot-public-a" }
}


resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "honeypot-public-rt" }
}


resource "aws_route" "default_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}


resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}


# ===================================================================
# Security Group - Firewall do ręcznej konfiguracji
# ===================================================================
resource "aws_security_group" "honeypot_sg" {
  name        = "honeypot-sg"
  description = "Firewall rules for the Honeypot BSK2 project"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]
    description = "Initial SSH access (Port 22)"
  }

  ingress {
    from_port   = 22222
    to_port     = 22222
    protocol    = "tcp"
    cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]
    description = "Server management after migration (SSH)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all egress"
  }
  
  tags = {
    Name = "honeypot-sg-secure"
  }
}


# ===================================================================
# EC2 Instance - główny serwer honeypota
# t2.micro (Free Tier), dysk 30GB zaszyfrowany, Ubuntu 22.04 LTS
# ===================================================================
resource "aws_instance" "honeypot_instance" {
  ami                         = "ami-0360c520857e3138f"
  instance_type               = "t2.micro"
  key_name                    = "projekt-bsk2-key"
  # --- KLUCZOWA POPRAWKA ---
  # Jawnie przypisujemy instancję do podsieci w naszym nowym VPC
  subnet_id                   = aws_subnet.public_a.id
  vpc_security_group_ids      = [aws_security_group.honeypot_sg.id]
  associate_public_ip_address = true

  # Dysk zaszyfrowany, 30GB, gp3
  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Skrypt instalacyjny z konfiguracją honeypota
  user_data = templatefile("user_data.tftpl", {
    grafana_admin_password  = var.grafana_admin_password
    geoipupdate_account_id  = var.geoipupdate_account_id
    geoipupdate_license_key = var.geoipupdate_license_key
    docker_compose_version  = var.docker_compose_version
  })

  # Tagi dla dokumentacji i zgodności
  tags = {
    Name        = "Honeypot-BSK2"
    Purpose     = "Security Research Honeypot"
    Project     = "Cybersecurity Education"
    Environment = "Isolated"
  }
}


# ===================================================================
# Outputs - wyświetlane po terraform apply
# ===================================================================

output "honeypot_public_ip" {
  value       = aws_instance.honeypot_instance.public_ip
  description = "Public IP of the honeypot"
}

output "ssh_management_command" {
  value       = "ssh -i projekt-bsk2-key.pem -p 22222 ubuntu@${aws_instance.honeypot_instance.public_ip}"
  description = "SSH management command"
}

output "grafana_tunnel_command" {
  value       = "ssh -i projekt-bsk2-key.pem -L 3000:localhost:3000 -p 22222 ubuntu@${aws_instance.honeypot_instance.public_ip}"
  description = "SSH tunnel to Grafana"
}

output "tcpdump_download_command" {
  value       = "scp -i projekt-bsk2-key.pem -P 22222 ubuntu@${aws_instance.honeypot_instance.public_ip}:/opt/honeypot/pcap_data/capture*.pcap ."
  description = "Download PCAP files"
}

output "honeypot_ssh_test_command" {
  value       = "ssh root@${aws_instance.honeypot_instance.public_ip}"
  description = "Test honeypot as an attacker"
}
