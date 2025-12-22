# =============================================================================
# Kestrel MSK Broker Resource Constraint Demo
# =============================================================================
# This Terraform creates an MSK cluster with undersized brokers:
# - 3-broker MSK cluster using t3.small (limited CPU/memory)
# - Topic for load testing
# - Producer EC2 instance for high-volume traffic generation
#
# The issue: t3.small brokers are undersized for production-level traffic
# Result: High CPU/memory usage, latency increases, eventually producer failures
# Fix: Upgrade broker instance type via AWS API (aws kafka update-broker-type)
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
  az3 = data.aws_availability_zones.azs.names[2]
}

resource "random_id" "suffix" {
  byte_length = 3
}

# =============================================================================
# VPC for MSK Cluster
# =============================================================================

resource "aws_vpc" "msk" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "msk-demo-vpc" }
}

resource "aws_internet_gateway" "msk" {
  vpc_id = aws_vpc.msk.id
  tags   = { Name = "msk-demo-igw" }
}

# Subnets in 3 AZs for MSK (required for multi-AZ deployment)
resource "aws_subnet" "msk_1" {
  vpc_id                  = aws_vpc.msk.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = local.az1
  map_public_ip_on_launch = true
  tags                    = { Name = "msk-demo-subnet-1" }
}

resource "aws_subnet" "msk_2" {
  vpc_id                  = aws_vpc.msk.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = local.az2
  map_public_ip_on_launch = true
  tags                    = { Name = "msk-demo-subnet-2" }
}

resource "aws_subnet" "msk_3" {
  vpc_id                  = aws_vpc.msk.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = local.az3
  map_public_ip_on_launch = true
  tags                    = { Name = "msk-demo-subnet-3" }
}

resource "aws_route_table" "msk" {
  vpc_id = aws_vpc.msk.id
  tags   = { Name = "msk-demo-rt" }
}

resource "aws_route" "msk_igw" {
  route_table_id         = aws_route_table.msk.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.msk.id
}

resource "aws_route_table_association" "msk_1" {
  subnet_id      = aws_subnet.msk_1.id
  route_table_id = aws_route_table.msk.id
}

resource "aws_route_table_association" "msk_2" {
  subnet_id      = aws_subnet.msk_2.id
  route_table_id = aws_route_table.msk.id
}

resource "aws_route_table_association" "msk_3" {
  subnet_id      = aws_subnet.msk_3.id
  route_table_id = aws_route_table.msk.id
}

# =============================================================================
# Security Groups
# =============================================================================

resource "aws_security_group" "msk" {
  name        = "msk-demo-cluster-sg"
  description = "Security group for MSK cluster"
  vpc_id      = aws_vpc.msk.id

  # Allow all traffic within the security group (broker-to-broker)
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  # Kafka plaintext
  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.msk.cidr_block]
  }

  # Kafka TLS
  ingress {
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.msk.cidr_block]
  }

  # Zookeeper
  ingress {
    from_port   = 2181
    to_port     = 2181
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.msk.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "msk-demo-cluster-sg" }
}

resource "aws_security_group" "client" {
  name        = "msk-demo-client-sg"
  description = "Security group for MSK client instance"
  vpc_id      = aws_vpc.msk.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "msk-demo-client-sg" }
}

# =============================================================================
# IAM Role for EC2 (SSM + MSK access)
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

resource "aws_iam_role" "client_role" {
  name               = "msk-demo-client-role-${random_id.suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.client_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# MSK permissions for client
resource "aws_iam_role_policy" "msk_policy" {
  name = "msk-demo-msk-policy"
  role = aws_iam_role.client_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kafka:DescribeCluster",
          "kafka:GetBootstrapBrokers",
          "kafka:ListClusters",
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:AlterCluster",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:CreateTopic",
          "kafka-cluster:DeleteTopic",
          "kafka-cluster:AlterTopic",
          "kafka-cluster:ReadData",
          "kafka-cluster:WriteData",
          "kafka-cluster:DescribeGroup",
          "kafka-cluster:AlterGroup"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "client_profile" {
  name = "msk-demo-client-profile-${random_id.suffix.hex}"
  role = aws_iam_role.client_role.name
}

# =============================================================================
# CloudWatch Log Group for MSK
# =============================================================================

resource "aws_cloudwatch_log_group" "msk_logs" {
  name              = "/aws/msk/demo-cluster-${random_id.suffix.hex}"
  retention_in_days = 1
  tags              = { Name = "msk-demo-logs" }
}

# =============================================================================
# MSK Configuration (intentionally suboptimal for demo)
# =============================================================================

resource "aws_msk_configuration" "demo" {
  name              = "msk-demo-config-${random_id.suffix.hex}"
  kafka_versions    = ["3.5.1"]
  
  server_properties = <<PROPERTIES
auto.create.topics.enable=true
default.replication.factor=2
min.insync.replicas=1
num.partitions=6
log.retention.hours=1
num.replica.fetchers=1
replica.lag.time.max.ms=10000
PROPERTIES
}

# =============================================================================
# MSK Cluster
# =============================================================================

resource "aws_msk_cluster" "demo" {
  cluster_name           = "msk-demo-${random_id.suffix.hex}"
  kafka_version          = "3.5.1"
  number_of_broker_nodes = 3

  broker_node_group_info {
    instance_type   = var.msk_instance_type
    client_subnets  = [aws_subnet.msk_1.id, aws_subnet.msk_2.id, aws_subnet.msk_3.id]
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = 100
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.demo.arn
    revision = aws_msk_configuration.demo.latest_revision
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS_PLAINTEXT"
      in_cluster    = false
    }
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk_logs.name
      }
    }
  }

  # Enhanced monitoring for detecting broker stress
  enhanced_monitoring = "PER_TOPIC_PER_BROKER"

  tags = { Name = "msk-demo-cluster" }
}

# =============================================================================
# EC2 Client Instance (Producer/Consumer)
# =============================================================================

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "client" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.msk_1.id
  vpc_security_group_ids = [aws_security_group.client.id, aws_security_group.msk.id]
  iam_instance_profile   = aws_iam_instance_profile.client_profile.name

  user_data = <<-EOF
              #!/bin/bash
              set -ex
              
              # Install dependencies
              dnf install -y python3-pip java-11-amazon-corretto-headless
              
              # Install Python Kafka library
              pip3 install confluent-kafka boto3
              
              # Download Kafka CLI tools
              cd /opt
              wget -q https://archive.apache.org/dist/kafka/3.5.1/kafka_2.13-3.5.1.tgz
              tar -xzf kafka_2.13-3.5.1.tgz
              ln -s kafka_2.13-3.5.1 kafka
              
              # Add Kafka to PATH
              echo 'export PATH=$PATH:/opt/kafka/bin' >> /etc/profile.d/kafka.sh
              
              # Create scripts directory
              mkdir -p /home/ec2-user/scripts
              chown ec2-user:ec2-user /home/ec2-user/scripts
              
              echo "Setup complete" > /tmp/setup-done
              EOF

  tags = { Name = "msk-demo-client" }

  depends_on = [aws_msk_cluster.demo]
}

# =============================================================================
# CloudWatch Alarms for MSK Metrics (for demo visibility)
# =============================================================================

# Alarm for high CPU on brokers
resource "aws_cloudwatch_metric_alarm" "broker_cpu" {
  alarm_name          = "msk-demo-broker-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CpuUser"
  namespace           = "AWS/Kafka"
  period              = 60
  statistic           = "Average"
  threshold           = 60
  alarm_description   = "Broker CPU utilization is high - potential hotspot"

  dimensions = {
    "Cluster Name" = aws_msk_cluster.demo.cluster_name
  }

  tags = { Name = "msk-demo-cpu-alarm" }
}

# Alarm for under-replicated partitions (ISR shrink)
resource "aws_cloudwatch_metric_alarm" "under_replicated" {
  alarm_name          = "msk-demo-under-replicated-partitions"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnderReplicatedPartitions"
  namespace           = "AWS/Kafka"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Partitions are under-replicated - ISR shrink detected"

  dimensions = {
    "Cluster Name" = aws_msk_cluster.demo.cluster_name
  }

  tags = { Name = "msk-demo-isr-alarm" }
}
