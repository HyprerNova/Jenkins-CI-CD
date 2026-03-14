terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"   # or latest stable in 2026
    }
  }
}

provider "aws" {
  region = var.region
}

# ────────────────────────────────────────────────────────────────────────────────
# ECR Repositories (create fresh ones – better than reusing manual)
# ────────────────────────────────────────────────────────────────────────────────
resource "aws_ecr_repository" "frontend" {
  name                 = "${var.project_name}-frontend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true   # easy destroy

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}-backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# ────────────────────────────────────────────────────────────────────────────────
# IAM Role + Instance Profile for all EC2 (Jenkins + ASG instances)
# ────────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}


resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# ────────────────────────────────────────────────────────────────────────────────
# Security Groups (basic – restrict in real world!)
# ────────────────────────────────────────────────────────────────────────────────
resource "aws_security_group" "jenkins_sg" {
  name        = "${var.project_name}-jenkins-sg"
  description = "Jenkins + SSH"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # restrict to your IP for production demo
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app_sg" {
  name        = "${var.project_name}-app-sg"
  description = "Frontend/Backend + ALB"

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]   # only from ALB
  }

  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "alb_sg" {
  name        = "${var.project_name}-alb-sg"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ────────────────────────────────────────────────────────────────────────────────
# Jenkins EC2 (t4g.medium)
# ────────────────────────────────────────────────────────────────────────────────
resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.ubuntu_2204_arm64.id
  instance_type          = "t4g.medium"
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.jenkins_sg.id]
  associate_public_ip_address = true

  tags = {
    Name = "${var.project_name}-jenkins"
  }
}

# ────────────────────────────────────────────────────────────────────────────────
# Launch Templates + ASGs
# ────────────────────────────────────────────────────────────────────────────────
resource "aws_launch_template" "frontend" {
  name_prefix   = "frontend-"
  image_id      = data.aws_ami.ubuntu_2204_arm64.id
  instance_type = "t4g.small"
  iam_instance_profile { name = aws_iam_instance_profile.ec2_profile.name }

  vpc_security_group_ids = [aws_security_group.app_sg.id]
}

resource "aws_autoscaling_group" "frontend" {
  name                = "${var.project_name}-frontend-asg"
  min_size            = 0
  max_size            = 2
  desired_capacity    = 0   # start stopped → zero cost when idle
  vpc_zone_identifier = slice(data.aws_subnets.default.ids, 0, 2)  # use up to 2 subnets

  launch_template {
    id      = aws_launch_template.frontend.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-frontend"
    propagate_at_launch = true
  }
}

resource "aws_launch_template" "backend" {
  name_prefix   = "backend-"
  image_id      = data.aws_ami.ubuntu_2204_arm64.id
  instance_type = "t4g.medium"
  iam_instance_profile { name = aws_iam_instance_profile.ec2_profile.name }

  vpc_security_group_ids = [aws_security_group.app_sg.id]
}

resource "aws_autoscaling_group" "backend" {
  name                = "${var.project_name}-backend-asg"
  min_size            = 0
  max_size            = 2
  desired_capacity    = 0
  vpc_zone_identifier = slice(data.aws_subnets.default.ids, 0, 2)

  launch_template {
    id      = aws_launch_template.backend.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-backend"
    propagate_at_launch = true
  }
}

# ────────────────────────────────────────────────────────────────────────────────
# ALB + Target Groups + Listeners
# ────────────────────────────────────────────────────────────────────────────────
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = slice(data.aws_subnets.default.ids, 0, 2)   # up to 2 subnets (distinct AZs recommended)
}

resource "aws_lb_target_group" "frontend" {
  name     = "${var.project_name}-tg-frontend"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id   # or hardcode if known
  target_type = "instance"
}

resource "aws_lb_target_group" "backend" {
  name     = "${var.project_name}-tg-backend"
  port     = 5000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  target_type = "instance"
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

resource "aws_lb_listener_rule" "api_to_backend" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}

# ────────────────────────────────────────────────────────────────────────────────
# Data sources for defaults
# ────────────────────────────────────────────────────────────────────────────────
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Latest Ubuntu 22.04 LTS ARM64 AMI in the chosen region
data "aws_ami" "ubuntu_2204_arm64" {
  most_recent = true

  owners = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}