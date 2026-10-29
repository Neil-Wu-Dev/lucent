# =========================
# AMI
# =========================
#
# The application EC2 instances use the latest Amazon Linux 2023 AMI in us-east-1.
# This keeps the servers simple and matches the AWS Academy-friendly Linux path.

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# =========================
# VPC
# =========================
#
# Lucent runs inside one VPC. DNS support is enabled because future services
# such as RDS endpoints, SSM endpoints, and internal AWS names depend on it.

resource "aws_vpc" "lucent_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "lucent-vpc"
  }
}

# =========================
# Public Subnets
# =========================
#
# Public subnets are reserved for Internet-facing infrastructure such as the
# future ALB and the NAT Gateway. Application EC2 instances are not placed here.

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.lucent_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = false

  tags = {
    Name = "lucent-public-a"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.lucent_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = false

  tags = {
    Name = "lucent-public-b"
  }
}

# =========================
# Private Application Subnets
# =========================
#
# These subnets hold the two private application EC2 instances. They receive
# outbound Internet access through NAT, but they do not receive direct inbound
# Internet access.

resource "aws_subnet" "app_a" {
  vpc_id                  = aws_vpc.lucent_vpc.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = false

  tags = {
    Name = "lucent-private-app-a"
  }
}

resource "aws_subnet" "app_b" {
  vpc_id                  = aws_vpc.lucent_vpc.id
  cidr_block              = "10.0.4.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = false

  tags = {
    Name = "lucent-private-app-b"
  }
}

# =========================
# Private Database Subnets
# =========================
#
# These subnets are reserved for the future PostgreSQL RDS subnet group.
# RDS is not created in this task, but the network layout is prepared now.

resource "aws_subnet" "database_a" {
  vpc_id                  = aws_vpc.lucent_vpc.id
  cidr_block              = "10.0.5.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = false

  tags = {
    Name = "lucent-private-database-a"
  }
}

resource "aws_subnet" "database_b" {
  vpc_id                  = aws_vpc.lucent_vpc.id
  cidr_block              = "10.0.6.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = false

  tags = {
    Name = "lucent-private-database-b"
  }
}

# =========================
# Internet Gateway
# =========================
#
# The Internet Gateway allows public subnets to reach the Internet. It does not
# make private EC2 instances public by itself; routing and public IPs decide that.

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lucent_vpc.id

  tags = {
    Name = "lucent-igw"
  }
}

# =========================
# Route Tables
# =========================
#
# Public subnets route directly to the Internet Gateway.
# Private application subnets route outbound traffic through NAT.
# Private database subnets intentionally have no default Internet route.

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lucent_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "lucent-public-rt"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.lucent_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "lucent-private-app-rt"
  }
}

resource "aws_route_table_association" "app_a" {
  subnet_id      = aws_subnet.app_a.id
  route_table_id = aws_route_table.private_app.id
}

resource "aws_route_table_association" "app_b" {
  subnet_id      = aws_subnet.app_b.id
  route_table_id = aws_route_table.private_app.id
}

resource "aws_route_table" "private_database" {
  vpc_id = aws_vpc.lucent_vpc.id

  tags = {
    Name = "lucent-private-database-rt"
  }
}

resource "aws_route_table_association" "database_a" {
  subnet_id      = aws_subnet.database_a.id
  route_table_id = aws_route_table.private_database.id
}

resource "aws_route_table_association" "database_b" {
  subnet_id      = aws_subnet.database_b.id
  route_table_id = aws_route_table.private_database.id
}

# =========================
# NAT Gateway
# =========================
#
# NAT lives in a public subnet and gives private application EC2 instances
# outbound Internet access for packages, dependencies, and source downloads.
# It does not allow the Internet to initiate connections into private EC2.

resource "aws_eip" "nat" {
  domain = "vpc"

  depends_on = [
    aws_internet_gateway.igw
  ]

  tags = {
    Name = "lucent-nat-eip"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id

  depends_on = [
    aws_internet_gateway.igw
  ]

  tags = {
    Name = "lucent-nat"
  }
}

# =========================
# ECR
# =========================
#
# ECR stores the Lucent Backend Docker image. The repository is created here,
# but IAM permissions are not created in Terraform because AWS Academy provides
# LabInstanceProfile / LabRole.

resource "aws_ecr_repository" "backend" {
  name                 = var.backend_ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "lucent-backend-ecr"
  }
}

# =========================
# EC2 Management
# =========================
#
# AWS Academy does not allow this lab to create IAM roles or instance profiles.
# The private EC2 instances therefore use the existing LabInstanceProfile,
# exposed through a variable so the name is explicit and easy to change later.

# =========================
# Security Groups
# =========================
#
# The ALB is Internet-facing. The EC2 instances only accept backend traffic from
# the ALB security group. The future database security group only accepts
# PostgreSQL traffic from the EC2 security group.

resource "aws_security_group" "alb" {
  name        = "lucent-alb-sg"
  description = "Allow Internet HTTP access to the Lucent Backend ALB"
  vpc_id      = aws_vpc.lucent_vpc.id

  ingress {
    from_port   = var.alb_listener_port
    to_port     = var.alb_listener_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lucent-alb-sg"
  }
}

resource "aws_security_group" "app_ec2" {
  name        = "lucent-app-ec2-sg"
  description = "Private application EC2 outbound access only"
  vpc_id      = aws_vpc.lucent_vpc.id

  ingress {
    from_port       = var.backend_container_port
    to_port         = var.backend_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lucent-app-ec2-sg"
  }
}

resource "aws_security_group" "database" {
  name        = "lucent-database-sg"
  description = "Allow PostgreSQL access from Lucent Backend EC2 only"
  vpc_id      = aws_vpc.lucent_vpc.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app_ec2.id]
  }

  tags = {
    Name = "lucent-database-sg"
  }
}

# =========================
# Application Load Balancer
# =========================
#
# The ALB is Internet-facing and placed in the two public subnets. It forwards
# HTTP traffic to private backend instances managed by the Auto Scaling Group.

resource "aws_lb" "backend" {
  name               = "lucent-backend-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id
  ]

  tags = {
    Name = "lucent-backend-alb"
  }
}

resource "aws_lb_target_group" "backend" {
  name        = "lucent-backend-tg"
  port        = var.backend_container_port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.lucent_vpc.id

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "traffic-port"
    path                = "/api/v1/notes"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "lucent-backend-tg"
  }
}

resource "aws_lb_target_group" "frontend" {
  name        = "lucent-frontend-tg"
  port        = var.frontend_nginx_port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.lucent_vpc.id

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "traffic-port"
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "lucent-frontend-tg"
  }
}

resource "aws_lb_target_group_attachment" "frontend_a" {
  target_group_arn = aws_lb_target_group.frontend.arn
  target_id        = aws_instance.frontend_a.id
  port             = var.frontend_nginx_port
}

resource "aws_lb_target_group_attachment" "frontend_b" {
  target_group_arn = aws_lb_target_group.frontend.arn
  target_id        = aws_instance.frontend_b.id
  port             = var.frontend_nginx_port
}

resource "aws_lb_listener" "backend_http" {
  load_balancer_arn = aws_lb.backend.arn
  port              = var.alb_listener_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

resource "aws_lb_listener_rule" "api_to_backend" {
  listener_arn = aws_lb_listener.backend_http.arn
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

# =========================
# Backend Auto Scaling
# =========================
#
# The launch template defines an identical, private runtime for every backend
# instance. Its startup process makes a new ASG instance independently able to
# run the current backend container and register as a healthy ALB target.

resource "aws_launch_template" "backend" {
  name_prefix            = "lucent-backend-"
  image_id               = data.aws_ami.amazon_linux.id
  instance_type          = var.backend_instance_type
  update_default_version = true

  iam_instance_profile {
    name = var.ec2_instance_profile_name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.app_ec2.id]
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euxo pipefail

    REGION="us-east-1"
    REGISTRY="${split("/", aws_ecr_repository.backend.repository_url)[0]}"
    IMAGE="${aws_ecr_repository.backend.repository_url}:latest"
    DB_URL_BASE64="${base64encode("jdbc:postgresql://${aws_db_instance.lucent.address}:${aws_db_instance.lucent.port}/${var.database_name}")}"
    DB_USERNAME_BASE64="${base64encode(var.database_username)}"
    DB_PASSWORD_BASE64="${base64encode(var.database_password)}"

    if ! command -v amazon-ssm-agent >/dev/null 2>&1; then
      dnf install -y amazon-ssm-agent
    fi
    systemctl enable --now amazon-ssm-agent

    if ! command -v docker >/dev/null 2>&1; then
      dnf install -y docker
    fi
    systemctl enable --now docker

    if ! command -v aws >/dev/null 2>&1; then
      dnf install -y awscli || dnf install -y awscli2 || dnf install -y aws-cli
    fi

    DB_URL="$$(echo "$$DB_URL_BASE64" | base64 -d)"
    DB_USERNAME="$$(echo "$$DB_USERNAME_BASE64" | base64 -d)"
    DB_PASSWORD="$$(echo "$$DB_PASSWORD_BASE64" | base64 -d)"

    # The first infrastructure deployment creates an empty ECR repository.
    # Do not fail instance initialization before Application CI/CD publishes the
    # first image; SSM is already ready for that deployment. On later scale-out,
    # the published image is present and each new instance starts itself.
    if aws ecr describe-images --region "$$REGION" --repository-name "${var.backend_ecr_repository_name}" --image-ids imageTag=latest >/dev/null 2>&1; then
      aws ecr get-login-password --region "$$REGION" | docker login --username AWS --password-stdin "$$REGISTRY"
      docker pull "$$IMAGE"
      if docker container inspect lucent-backend >/dev/null 2>&1; then
        docker rm -f lucent-backend
      fi
      docker run -d --name lucent-backend --restart unless-stopped -p ${var.backend_container_port}:${var.backend_container_port} \
        -e DB_URL="$$DB_URL" \
        -e DB_USERNAME="$$DB_USERNAME" \
        -e DB_PASSWORD="$$DB_PASSWORD" \
        "$$IMAGE"
    else
      echo "Lucent Backend image is not published yet; waiting for Application CI/CD deployment."
    fi
  EOF
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name    = "lucent-backend-asg"
      Service = "lucent-backend"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "backend" {
  name              = "lucent-backend-asg"
  min_size          = var.backend_asg_min_size
  desired_capacity  = var.backend_asg_desired_capacity
  max_size          = var.backend_asg_max_size
  health_check_type = "ELB"
  # This is intentionally longer than metric warmup. It prevents the ASG from
  # replacing fresh instances while the first Application CI/CD release is
  # building and deploying the image after infrastructure creation.
  health_check_grace_period = var.backend_asg_health_check_grace_seconds
  target_group_arns         = [aws_lb_target_group.backend.arn]
  vpc_zone_identifier       = [aws_subnet.app_a.id, aws_subnet.app_b.id]
  wait_for_capacity_timeout = "15m"
  termination_policies      = ["OldestLaunchTemplate"]

  launch_template {
    id      = aws_launch_template.backend.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      instance_warmup        = var.backend_instance_warmup_seconds
      min_healthy_percentage = 50
    }

  }

  tag {
    key                 = "Name"
    value               = "lucent-backend-asg"
    propagate_at_launch = true
  }

  tag {
    key                 = "Service"
    value               = "lucent-backend"
    propagate_at_launch = true
  }

  lifecycle {
    precondition {
      condition = (
        var.backend_asg_min_size <= var.backend_asg_desired_capacity &&
        var.backend_asg_desired_capacity <= var.backend_asg_max_size
      )
      error_message = "Backend ASG capacity must satisfy min_size <= desired_capacity <= max_size."
    }
  }
}

resource "aws_autoscaling_policy" "backend_cpu_target" {
  name                      = "lucent-backend-cpu-50"
  autoscaling_group_name    = aws_autoscaling_group.backend.name
  policy_type               = "TargetTrackingScaling"
  estimated_instance_warmup = var.backend_instance_warmup_seconds

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = var.backend_cpu_target_percent
  }
}

# =========================
# Frontend EC2 Instances
# =========================
#
# React frontend hosting moves from S3/CloudFront to two private EC2 instances
# running Nginx. The ALB sends all non-/api traffic to these instances.

resource "aws_security_group" "frontend_ec2" {
  name        = "lucent-frontend-ec2-sg"
  description = "Allow frontend traffic from ALB to private Nginx EC2 only"
  vpc_id      = aws_vpc.lucent_vpc.id

  ingress {
    from_port       = var.frontend_nginx_port
    to_port         = var.frontend_nginx_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lucent-frontend-ec2-sg"
  }
}

resource "aws_instance" "frontend_a" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.app_a.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.frontend_ec2.id]
  iam_instance_profile        = var.ec2_instance_profile_name
  user_data                   = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    if ! command -v amazon-ssm-agent >/dev/null 2>&1; then
      dnf install -y amazon-ssm-agent
    fi

    systemctl enable amazon-ssm-agent

    if ! systemctl is-active --quiet amazon-ssm-agent; then
      systemctl start amazon-ssm-agent
    fi

    if ! command -v nginx >/dev/null 2>&1; then
      dnf install -y nginx
    fi

    cat > /usr/share/nginx/html/index.html <<'HTML'
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="UTF-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>Lucent Frontend</title>
      </head>
      <body>
        <h1>Lucent Frontend EC2 is ready.</h1>
      </body>
    </html>
    HTML

    systemctl enable nginx

    if ! systemctl is-active --quiet nginx; then
      systemctl start nginx
    fi
  EOF

  tags = {
    Name = "lucent-frontend-1"
  }
}

resource "aws_instance" "frontend_b" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.app_b.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.frontend_ec2.id]
  iam_instance_profile        = var.ec2_instance_profile_name
  user_data                   = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    if ! command -v amazon-ssm-agent >/dev/null 2>&1; then
      dnf install -y amazon-ssm-agent
    fi

    systemctl enable amazon-ssm-agent

    if ! systemctl is-active --quiet amazon-ssm-agent; then
      systemctl start amazon-ssm-agent
    fi

    if ! command -v nginx >/dev/null 2>&1; then
      dnf install -y nginx
    fi

    cat > /usr/share/nginx/html/index.html <<'HTML'
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="UTF-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>Lucent Frontend</title>
      </head>
      <body>
        <h1>Lucent Frontend EC2 is ready.</h1>
      </body>
    </html>
    HTML

    systemctl enable nginx

    if ! systemctl is-active --quiet nginx; then
      systemctl start nginx
    fi
  EOF

  tags = {
    Name = "lucent-frontend-2"
  }
}
