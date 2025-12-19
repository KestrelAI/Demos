# =============================================================================
# Kestrel VPC Peering Blackhole Demo
# =============================================================================
# This Terraform creates a VPC peering "one-way route" blackhole incident:
# - Forward path exists (A → B)
# - Return path is INTENTIONALLY MISCONFIGURED (B → only partial A)
#
# Result: Client-OK works, Client-BROKEN times out (classic "flaky network")
# =============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "azs" {
  state = "available"
}

locals {
  az1 = data.aws_availability_zones.azs.names[0]
  az2 = data.aws_availability_zones.azs.names[1]
}

# =============================================================================
# VPC A (Clients)
# =============================================================================

resource "aws_vpc" "a" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "demo-vpc-a" }
}

resource "aws_internet_gateway" "a" {
  vpc_id = aws_vpc.a.id
  tags   = { Name = "demo-igw-a" }
}

resource "aws_subnet" "a1" {
  vpc_id                  = aws_vpc.a.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = local.az1
  map_public_ip_on_launch = true
  tags                    = { Name = "demo-a-subnet-1" }
}

resource "aws_subnet" "a2" {
  vpc_id                  = aws_vpc.a.id
  cidr_block              = "10.10.2.0/24"
  availability_zone       = local.az2
  map_public_ip_on_launch = true
  tags                    = { Name = "demo-a-subnet-2" }
}

resource "aws_route_table" "a_rt" {
  vpc_id = aws_vpc.a.id
  tags   = { Name = "demo-a-rt" }
}

resource "aws_route" "a_default_igw" {
  route_table_id         = aws_route_table.a_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.a.id
}

resource "aws_route_table_association" "a1_assoc" {
  subnet_id      = aws_subnet.a1.id
  route_table_id = aws_route_table.a_rt.id
}

resource "aws_route_table_association" "a2_assoc" {
  subnet_id      = aws_subnet.a2.id
  route_table_id = aws_route_table.a_rt.id
}

# =============================================================================
# VPC B (Server)
# =============================================================================

resource "aws_vpc" "b" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "demo-vpc-b" }
}

resource "aws_internet_gateway" "b" {
  vpc_id = aws_vpc.b.id
  tags   = { Name = "demo-igw-b" }
}

resource "aws_subnet" "b1" {
  vpc_id                  = aws_vpc.b.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = local.az1
  map_public_ip_on_launch = true
  tags                    = { Name = "demo-b-subnet-1" }
}

resource "aws_route_table" "b_rt" {
  vpc_id = aws_vpc.b.id
  tags   = { Name = "demo-b-rt" }
}

resource "aws_route" "b_default_igw" {
  route_table_id         = aws_route_table.b_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.b.id
}

resource "aws_route_table_association" "b1_assoc" {
  subnet_id      = aws_subnet.b1.id
  route_table_id = aws_route_table.b_rt.id
}

# =============================================================================
# VPC Peering Connection
# =============================================================================

resource "aws_vpc_peering_connection" "peer" {
  vpc_id      = aws_vpc.a.id
  peer_vpc_id = aws_vpc.b.id
  auto_accept = true
  tags        = { Name = "demo-a-b-peering" }
}

# A -> B route (CORRECT - full VPC B CIDR)
resource "aws_route" "a_to_b" {
  route_table_id            = aws_route_table.a_rt.id
  destination_cidr_block    = aws_vpc.b.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.peer.id
}

# =============================================================================
# B -> A routes (INTENTIONALLY MISCONFIGURED!)
# =============================================================================
# Only route back to A subnet 10.10.1.0/24 (a1), MISSING 10.10.2.0/24 (a2)
# This creates a "blackhole" for return traffic from the server to client-broken

resource "aws_route" "b_to_a_only_a1" {
  route_table_id            = aws_route_table.b_rt.id
  destination_cidr_block    = "10.10.1.0/24" # Only subnet A1!
  vpc_peering_connection_id = aws_vpc_peering_connection.peer.id
}

# =============================================================================
# Security Groups
# =============================================================================

resource "aws_security_group" "clients_sg" {
  name        = "demo-clients-sg"
  description = "Clients can egress anywhere"
  vpc_id      = aws_vpc.a.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "demo-clients-sg" }
}

resource "aws_security_group" "server_sg" {
  name        = "demo-server-sg"
  description = "Allow HTTP from VPC A"
  vpc_id      = aws_vpc.b.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.a.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "demo-server-sg" }
}

# =============================================================================
# IAM Role for SSM (no SSH needed)
# =============================================================================

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 3
}

resource "aws_iam_role" "ssm_role" {
  name               = "demo-ssm-role-${random_id.suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "demo-ssm-profile-${random_id.suffix.hex}"
  role = aws_iam_role.ssm_role.name
}

# =============================================================================
# EC2 Instances
# =============================================================================

data "aws_ami" "al2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "server" {
  ami                    = data.aws_ami.al2.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.b1.id
  vpc_security_group_ids = [aws_security_group.server_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  user_data = <<-EOF
              #!/bin/bash
              yum -y install python3
              cd /tmp
              echo "hello from VPC B server" > index.html
              nohup python3 -m http.server 8080 --bind 0.0.0.0 &
              EOF

  tags = { Name = "demo-vpc-b-server" }
}

resource "aws_instance" "client_ok" {
  ami                    = data.aws_ami.al2.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.a1.id
  vpc_security_group_ids = [aws_security_group.clients_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  tags = { Name = "demo-client-ok-a1" }
}

resource "aws_instance" "client_broken" {
  ami                    = data.aws_ami.al2.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.a2.id
  vpc_security_group_ids = [aws_security_group.clients_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  tags = { Name = "demo-client-broken-a2" }
}

# =============================================================================
# VPC Flow Logs - For detecting REJECT packets (blackhole detection)
# =============================================================================
# VPC Flow Logs capture network traffic metadata including REJECT actions.
# When the server tries to respond to client-broken but has no return route,
# the traffic may be logged as REJECT if it hits a security boundary.

# IAM Role for VPC Flow Logs to write to CloudWatch
resource "aws_iam_role" "flow_logs_role" {
  name = "demo-flow-logs-role-${random_id.suffix.hex}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs_policy" {
  name = "demo-flow-logs-policy"
  role = aws_iam_role.flow_logs_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

# CloudWatch Log Group for VPC A Flow Logs
resource "aws_cloudwatch_log_group" "flow_logs_a" {
  name              = "/aws/vpc/flowlogs/demo-vpc-a-${random_id.suffix.hex}"
  retention_in_days = 1 # Short retention for demo
  tags              = { Name = "demo-vpc-a-flow-logs" }
}

# CloudWatch Log Group for VPC B Flow Logs  
resource "aws_cloudwatch_log_group" "flow_logs_b" {
  name              = "/aws/vpc/flowlogs/demo-vpc-b-${random_id.suffix.hex}"
  retention_in_days = 1 # Short retention for demo
  tags              = { Name = "demo-vpc-b-flow-logs" }
}

# VPC Flow Logs for VPC A (clients)
resource "aws_flow_log" "vpc_a" {
  vpc_id                   = aws_vpc.a.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs_a.arn
  iam_role_arn             = aws_iam_role.flow_logs_role.arn
  max_aggregation_interval = 60 # 1 minute aggregation for faster detection

  tags = { Name = "demo-vpc-a-flow-log" }
}

# VPC Flow Logs for VPC B (server) - CRITICAL for detecting blackhole
# When the server responds to client-broken, the lack of return route
# may generate REJECT entries in the flow logs
resource "aws_flow_log" "vpc_b" {
  vpc_id                   = aws_vpc.b.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs_b.arn
  iam_role_arn             = aws_iam_role.flow_logs_role.arn
  max_aggregation_interval = 60 # 1 minute aggregation for faster detection

  tags = { Name = "demo-vpc-b-flow-log" }
}
