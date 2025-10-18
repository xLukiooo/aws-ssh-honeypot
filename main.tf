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
# Security Group - Firewall dla honeypota
# Port 22 otwarty jako pułapka, ruch wychodzący ograniczony
# ===================================================================
resource "aws_security_group" "honeypot_sg" {
  name        = "honeypot-sg"
  description = "Reguły firewalla dla projektu Honeypot BSK2"

  # Port 22 - SSH honeypot (pułapka)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Honeypot SSH (Cowrie)"
  }

  # Port 22222 - SSH administracyjny (tylko z Twojego IP)
  ingress {
    from_port   = 22222
    to_port     = 22222
    protocol    = "tcp"
    cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]
    description = "Zarzadzanie serwerem (SSH)"
  }

  # Ruch wychodzący - tylko niezbędne porty (HTTP, HTTPS, DNS)
  # Port 25 (SMTP) celowo pominięty - blokada wysyłania emaili
  
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP dla aktualizacji"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS dla Docker i aktualizacji"
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "DNS"
  }

  tags = {
    Name = "honeypot-sg-secure"
  }
}


# ===================================================================
# CloudWatch Log Group - przechowywanie logów przez 30 dni
# ===================================================================
resource "aws_cloudwatch_log_group" "honeypot_logs" {
  name              = "/aws/ec2/honeypot-bsk2"
  retention_in_days = 30

  tags = {
    Name        = "Honeypot-Logs"
    Environment = "Security-Research"
  }
}


# ===================================================================
# IAM Role - pozwala instancji wysyłać logi do CloudWatch
# ===================================================================
resource "aws_iam_role" "honeypot_cloudwatch_role" {
  name = "honeypot-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "Honeypot-CloudWatch-Role"
  }
}

resource "aws_iam_role_policy_attachment" "cloudwatch_logs_policy" {
  role       = aws_iam_role.honeypot_cloudwatch_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "honeypot_profile" {
  name = "honeypot-instance-profile"
  role = aws_iam_role.honeypot_cloudwatch_role.name
}


# ===================================================================
# EC2 Instance - główny serwer honeypota
# t2.micro (Free Tier), dysk 30GB zaszyfrowany, Ubuntu 22.04 LTS
# ===================================================================
resource "aws_instance" "honeypot_instance" {
  ami                         = "ami-0360c520857e3138f"
  instance_type               = "t2.micro"
  key_name                    = "projekt-bsk2-key"
  vpc_security_group_ids      = [aws_security_group.honeypot_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.honeypot_profile.name

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
  description = "Publiczny IP honeypota"
}

output "ssh_management_command" {
  value       = "ssh -i projekt-bsk2-key.pem -p 22222 ubuntu@${aws_instance.honeypot_instance.public_ip}"
  description = "Komenda SSH do zarządzania"
}

output "grafana_tunnel_command" {
  value       = "ssh -i projekt-bsk2-key.pem -L 3000:localhost:3000 -p 22222 ubuntu@${aws_instance.honeypot_instance.public_ip}"
  description = "Tunel SSH do Grafany"
}

output "tcpdump_download_command" {
  value       = "scp -i projekt-bsk2-key.pem -P 22222 ubuntu@${aws_instance.honeypot_instance.public_ip}:/opt/honeypot/pcap_data/capture*.pcap ."
  description = "Pobranie plików PCAP"
}

output "honeypot_ssh_test_command" {
  value       = "ssh root@${aws_instance.honeypot_instance.public_ip}"
  description = "Test honeypota jako atakujący"
}

output "cloudwatch_log_group" {
  value       = aws_cloudwatch_log_group.honeypot_logs.name
  description = "Nazwa grupy logów CloudWatch"
}
