# ===================================================================
# Provider Configuration
# ===================================================================
provider "aws" {
  region = var.aws_region
}


# ===================================================================
# Dynamiczne pobieranie IP administratora
# ===================================================================
data "http" "my_ip" {
  url = "https://ipv4.icanhazip.com"
}


# ===================================================================
# Oficjalny publiczny parametr AWS dla Ubuntu 22.04 LTS (x86_64)
# ===================================================================
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
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
  availability_zone       = "${var.aws_region}a"
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
# Security Group - Firewall dla Honeypota
# ===================================================================
resource "aws_security_group" "honeypot_sg" {
  name        = "honeypot-sg"
  description = "Reguly sieciowe dla srodowiska Honeypot"
  vpc_id      = aws_vpc.main.id

  # Port 22 - Pułapka SSH (Cowrie) - otwarty na cały świat
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Honeypot SSH (Cowrie) - Public trap"
  }

  # Port 22222 - Bezpieczne zarządzanie serwerem - tylko Twój adres IP
  ingress {
    from_port   = 22222
    to_port     = 22222
    protocol    = "tcp"
    cidr_blocks = ["${chomp(data.http.my_ip.response_body)}/32"]
    description = "Server management (SSH) - Administrator IP only"
  }

  # Zezwolenie na ruch wychodzący
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all egress"
  }

  tags = {
    Name = "honeypot-sg"
  }
}


# ===================================================================
# EC2 Instance - główny serwer honeypota
# ===================================================================
resource "aws_instance" "honeypot_instance" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = "t3.micro"
  key_name                    = var.key_name
  subnet_id                   = aws_subnet.public_a.id
  vpc_security_group_ids      = [aws_security_group.honeypot_sg.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = templatefile("user_data.tftpl", {
    grafana_admin_password  = var.grafana_admin_password
    geoipupdate_account_id  = var.geoipupdate_account_id
    geoipupdate_license_key = var.geoipupdate_license_key
    docker_compose_version  = var.docker_compose_version
  })

  tags = {
    Name        = "aws-ssh-honeypot"
    Purpose     = "Security Research Honeypot"
    Environment = "Isolated"
  }
}
