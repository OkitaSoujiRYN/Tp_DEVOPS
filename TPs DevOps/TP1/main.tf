# Set the AWS provider with the desired region
provider "aws" {
  region = var.aws_region
}

# Define variables for the CIDRs of the VPC and subnets
variable "aws_region" {
  default = "us-east-1"
  type    = string
}

variable "vpc_cidr" {
  default = "172.16.0.0/16"
  type    = string
}

variable "public_subnet_cidr" {
  default = "172.16.1.0/24"
  type    = string
}

variable "private_subnet_cidr" {
  default = "172.16.2.0/24"
  type    = string
}

variable "instance_type" {
  default = "t2.micro"
  type    = string
}

########################
# Find your current IP
########################
variable "personal_ip_address" {
  type = string
}

data "http" "current_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  your_ip_addresses = distinct([var.personal_ip_address, chomp(data.http.current_ip.response_body)])
}

########################
# Network
########################

# Create the VPC
resource "aws_vpc" "tp_devops_vpc" {
  cidr_block = var.vpc_cidr
  tags = {
    Name = "TP_DevOps"
  }
}

# Create the public subnet
resource "aws_subnet" "tp_devops_public_subnet" {
  vpc_id                  = aws_vpc.tp_devops_vpc.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags = {
    Name = "TP_DevOps_Public"
  }
}

# Create the private subnet
resource "aws_subnet" "tp_devops_private_subnet" {
  vpc_id            = aws_vpc.tp_devops_vpc.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = "${var.aws_region}a"
  tags = {
    Name = "TP_DevOps_Private"
  }
}

# Create an internet gateway
resource "aws_internet_gateway" "tp_devops_igw" {
  vpc_id = aws_vpc.tp_devops_vpc.id
  tags = {
    Name = "TP_DevOps"
  }
}

# Create a route table for the public subnets
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.tp_devops_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.tp_devops_igw.id
  }

  tags = {
    Name = "TP_DevOps_Public"
  }
}

# Create a route table for the private subnets
resource "aws_default_route_table" "private_route_table" {
  default_route_table_id = aws_vpc.tp_devops_vpc.default_route_table_id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_network_interface.nat.id
    # instance_id = aws_instance.tp_devops_nat_instance.id
  }

  tags = {
    Name = "TP_DevOps_Default"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.tp_devops_public_subnet.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_security_group" "public" {
  name_prefix = "public-"
  vpc_id      = aws_vpc.tp_devops_vpc.id

  # allow all access from local network
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.private.id]
  }

  # allow SSH access from your IP
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [for ip in local.your_ip_addresses : "${ip}/32"]
  }

  # allow external access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "public"
  }
}

resource "aws_security_group" "private" {
  name_prefix = "private-"
  vpc_id      = aws_vpc.tp_devops_vpc.id

  # allow SSH access from public subnet
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.public_subnet_cidr]
  }

  # allow external access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Private"
  }
}

########################
# Instances
########################
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-*-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_network_interface" "nat" {
  subnet_id         = aws_subnet.tp_devops_public_subnet.id
  source_dest_check = false
  security_groups   = [aws_security_group.public.id]

  tags = {
    Name = "nat_instance_network_interface"
  }
}

# Create a NAT instance
resource "aws_instance" "tp_devops_nat_instance" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.instance_type
  key_name             = "vockey"
  iam_instance_profile = "LabInstanceProfile"
  network_interface {
    network_interface_id = aws_network_interface.nat.id
    device_index         = 0
  }
  tags = {
    Name = "NAT_JumpHost"
  }

  user_data                   = <<-EOT
    #!/bin/bash
    sysctl -w net.ipv4.ip_forward=1
    apt-get update -y
    debconf-set-selections <<EOF
    iptables-persistent iptables-persistent/autosave_v4 boolean true
    iptables-persistent iptables-persistent/autosave_v6 boolean true
    EOF
    apt install iptables-persistent -y
    /sbin/iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    iptables-save > /etc/iptables/rules.v4

    snap start amazon-ssm-agent

  EOT
  user_data_replace_on_change = true
}

# Create a private instance
resource "aws_instance" "tp_devops_private_instance" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = "vockey"
  iam_instance_profile   = "LabInstanceProfile"
  subnet_id              = aws_subnet.tp_devops_private_subnet.id
  vpc_security_group_ids = [aws_security_group.private.id]
  tags = {
    Name = "PrivateHost"
  }

  user_data                   = <<-EOT
    #!/bin/bash
    snap start amazon-ssm-agent
  EOT
  user_data_replace_on_change = true
}

output "nat_public_ip" {
  value = aws_instance.tp_devops_nat_instance.public_ip
}

output "nat_private_ip" {
  value = aws_instance.tp_devops_nat_instance.private_ip
}

output "private_host_ip" {
  value = aws_instance.tp_devops_private_instance.private_ip
}
