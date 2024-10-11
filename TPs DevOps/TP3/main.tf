	
provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
  type    = string
}
data "aws_availability_zones" "available" {}
variable "vpc_cidr" {
  default = "10.0.0.0/16"
  type    = string
}
variable "public_subnet_cidrs" {
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}
variable "private_subnet_cidrs" {
  default = ["10.0.3.0/24", "10.0.4.0/24"]
}
variable "instance_type" {
  default = "t2.micro"
  type    = string
}
variable "desired_capacity" {
  default = 1
  type    = number
}
variable "min_size" {
  default = 1
  type    = number
}
variable "max_size" {
  default = 2
  type    = number
}

variable "personal_ip_address" {
  type = string
}
data "http" "current_ip" {
  url = "https://checkip.amazonaws.com"
}
locals {
  your_ip_addresses = distinct([var.personal_ip_address, chomp(data.http.current_ip.response_body)])


availability_zones = data.aws_availability_zones.available.names
}

resource "aws_vpc" "tp_devops_vpc" {
  cidr_block = var.vpc_cidr
  tags = {
    Name = "TP1_DevOps_Groupe_2"
  }
}


resource "aws_subnet" "public_subnets" {
  count = length(var.public_subnet_cidrs)
  vpc_id = aws_vpc.tp_devops_vpc.id
  cidr_block = var.public_subnet_cidrs[count.index]
  availability_zone = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = true
  tags = {
    Name = "TP3-Subnet-WebPublic-${count.index}"
  }
}


resource "aws_subnet" "private_subnets" {
  count = length(var.private_subnet_cidrs)
  vpc_id = aws_vpc.tp_devops_vpc.id
  cidr_block = var.private_subnet_cidrs[count.index]
  availability_zone = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = false
  tags = {
    Name = "TP3-Subnet-web_private-${count.index}"
  }
}

resource "aws_internet_gateway" "tp_devops_igw" {
  vpc_id = aws_vpc.tp_devops_vpc.id
  tags = {
    Name = "TP_DevOps"
  }
}

resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.tp_devops_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.tp_devops_igw.id
  }

  tags = {
    Name = "TP1_DevOps_Groupe2_Public"
  }
}


resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.tp_devops_vpc.id

  tags = {
    Name = "TP1_DevOps_Groupe2_Private"
  }
}
resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public_subnets)

  subnet_id     = aws_subnet.public_subnets[count.index].id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private_subnets)

  subnet_id     = aws_subnet.private_subnets[count.index].id
  route_table_id = aws_route_table.private_route_table.id
}

resource "aws_security_group" "public" {
  name_prefix = "public-"
  vpc_id      = aws_vpc.tp_devops_vpc.id

  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.private.id]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [for ip in local.your_ip_addresses : "${ip}/32"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [for ip in local.your_ip_addresses : "${ip}/32"]
  }

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

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.public_subnet_cidrs
  }

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

resource "aws_autoscaling_group" "webautoscaling" {
  desired_capacity   = var.desired_capacity
  min_size           = var.min_size
  max_size           = var.max_size
  launch_configuration = aws_launch_configuration.weblaunchconfig.id
  vpc_zone_identifier = [for subnet in aws_subnet.private_subnets : subnet.id]
  target_group_arns    = [aws_lb_target_group.webloadbalancer.arn]

  tag {
    key                 = "Name"
    value               = "WebServer"
    propagate_at_launch = true
  }
}

resource "aws_cloudwatch_metric_alarm" "scale_in_alarm" {
  alarm_name          = "scale-in-alarm"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPU_Utilization"
  namespace = "AWS/EC2"
  period = 300
  statistic = "Average"
  threshold = 30
  alarm_description = "Scale In Alarm"
  alarm_actions = [aws_autoscaling_policy.scale_in_policy.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.webautoscaling.name
  }
}

resource "aws_cloudwatch_metric_alarm" "scale_out_alarm" {
  alarm_name          = "scale-out-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Scale Out Alarm"
  alarm_actions       = [aws_autoscaling_policy.scale_out_policy.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.webautoscaling.name
  }
}

resource "aws_autoscaling_policy" "scale_in_policy" {
  name                   = "scale-in-policy"
  scaling_adjustment     = -1
  cooldown               = 300
  adjustment_type        = "ChangeInCapacity"
  autoscaling_group_name = aws_autoscaling_group.webautoscaling.name
}
resource "aws_autoscaling_policy" "scale_out_policy" {
  name                   = "scale-out-policy"
  scaling_adjustment     = 1
  cooldown               = 300
  adjustment_type        = "ChangeInCapacity"
  autoscaling_group_name = aws_autoscaling_group.webautoscaling.name
}


data "aws_ami" "web_ami" {
  most_recent = true
  owners      = ["self"]
  name_regex  = "^WebApp"
}

output "web_ami" {
  value = {
    id   = data.aws_ami.web_ami.id
    name = data.aws_ami.web_ami.name
  }
}

resource "aws_launch_configuration" "weblaunchconfig"{
  image_id = data.aws_ami.web_ami.id
  instance_type = var.instance_type
  key_name = "vockey"
  iam_instance_profile = "LabInstanceProfile"
  security_groups = [aws_security_group.private.id]
  lifecycle {
      create_before_destroy = true
     }
}
resource "aws_lb" "webloadbalancer" {
  name               = "webloadbalancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.public.id]
  subnets            = [for subnet in aws_subnet.public_subnets : subnet.id]
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "webloadbalancer" {
  name     = "webloadbalancer"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.tp_devops_vpc.id

  health_check {
    enabled             = true
    healthy_threshold   = 3
    interval            = 15
    path                = "/"
    port                = 8080
    timeout             = 5
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.webloadbalancer.arn
  port              = "8080"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.webloadbalancer.arn
  }
}
output "name_of_dns_of_load_balancer" {
  description = "The DNS name of the Elastic Load Balancer to access to the website"
  value       = aws_lb.webloadbalancer.dns_name
}
