# =============================================================================
# Kestrel MSK Cluster Capacity Demo
# =============================================================================
# Creates an undersized 2-broker MSK cluster that can't handle high load.
# Under heavy traffic, partitions become under-replicated, triggering
# the MSKClusterCapacityInsufficient incident.
#
# Fix: aws kafka update-broker-count to add more brokers
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
  # Only use 2 AZs for 2-broker cluster
  az1 = data.aws_availability_zones.azs.names[0]
  az2 = data.aws_availability_zones.azs.names[1]
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
  tags                 = { Name = "msk-capacity-demo-vpc" }
}

resource "aws_internet_gateway" "msk" {
  vpc_id = aws_vpc.msk.id
  tags   = { Name = "msk-capacity-demo-igw" }
}

# Only 2 subnets for 2-broker cluster
resource "aws_subnet" "msk_1" {
  vpc_id                  = aws_vpc.msk.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = local.az1
  map_public_ip_on_launch = true
  tags                    = { Name = "msk-capacity-demo-subnet-1" }
}

resource "aws_subnet" "msk_2" {
  vpc_id                  = aws_vpc.msk.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = local.az2
  map_public_ip_on_launch = true
  tags                    = { Name = "msk-capacity-demo-subnet-2" }
}

resource "aws_route_table" "msk" {
  vpc_id = aws_vpc.msk.id
  tags   = { Name = "msk-capacity-demo-rt" }
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

# =============================================================================
# Security Groups
# =============================================================================

resource "aws_security_group" "msk" {
  name        = "msk-capacity-demo-cluster-sg"
  description = "Security group for MSK cluster"
  vpc_id      = aws_vpc.msk.id

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.msk.cidr_block]
  }

  ingress {
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.msk.cidr_block]
  }

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

  tags = { Name = "msk-capacity-demo-cluster-sg" }
}

resource "aws_security_group" "client" {
  name        = "msk-capacity-demo-client-sg"
  description = "Security group for MSK client instance"
  vpc_id      = aws_vpc.msk.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "msk-capacity-demo-client-sg" }
}

# =============================================================================
# IAM Role for EC2
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
  name               = "msk-capacity-demo-client-role-${random_id.suffix.hex}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.client_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "msk_policy" {
  name = "msk-capacity-demo-msk-policy"
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
          "kafka-cluster:*"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "client_profile" {
  name = "msk-capacity-demo-client-profile-${random_id.suffix.hex}"
  role = aws_iam_role.client_role.name
}

# =============================================================================
# CloudWatch Log Group
# =============================================================================

resource "aws_cloudwatch_log_group" "msk_logs" {
  name              = "/aws/msk/capacity-demo-${random_id.suffix.hex}"
  retention_in_days = 1
  tags              = { Name = "msk-capacity-demo-logs" }
}

# =============================================================================
# MSK Configuration - High replication factor to stress 2-broker cluster
# =============================================================================

resource "aws_msk_configuration" "demo" {
  name           = "msk-capacity-demo-config-${random_id.suffix.hex}"
  kafka_versions = ["3.5.1"]

  # Replication factor of 2 with only 2 brokers means EVERY partition
  # must have replicas on BOTH brokers - any broker slowdown causes
  # under-replicated partitions
  server_properties = <<PROPERTIES
auto.create.topics.enable=true
default.replication.factor=2
min.insync.replicas=2
num.partitions=12
log.retention.minutes=15
replica.lag.time.max.ms=10000
PROPERTIES
}

# =============================================================================
# MSK Cluster - Only 2 Brokers (minimum, easily overwhelmed)
# =============================================================================

resource "aws_msk_cluster" "demo" {
  cluster_name           = "msk-capacity-demo-${random_id.suffix.hex}"
  kafka_version          = "3.5.1"
  number_of_broker_nodes = 2  # Minimum - easily overwhelmed

  broker_node_group_info {
    instance_type   = "kafka.t3.small"  # Smallest instance
    client_subnets  = [aws_subnet.msk_1.id, aws_subnet.msk_2.id]
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = 150  # Increased to prevent disk full issues
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

  enhanced_monitoring = "PER_TOPIC_PER_BROKER"

  tags = { Name = "msk-capacity-demo-cluster" }
}

# =============================================================================
# EC2 Client Instance
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
  instance_type          = "c5.4xlarge"  # 16 vCPUs - sufficient for Go producer with 64 goroutines
  subnet_id              = aws_subnet.msk_1.id
  vpc_security_group_ids = [aws_security_group.client.id, aws_security_group.msk.id]
  iam_instance_profile   = aws_iam_instance_profile.client_profile.name

  # Larger root volume for Go build cache
  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              set -ex
              
              # Install Python, Java, and build tools
              dnf install -y python3-pip java-11-amazon-corretto-headless git tar gzip
              pip3 install confluent-kafka boto3
              
              # Install Go 1.21
              cd /tmp
              curl -sLO https://go.dev/dl/go1.21.5.linux-amd64.tar.gz
              rm -rf /usr/local/go
              tar -C /usr/local -xzf go1.21.5.linux-amd64.tar.gz
              echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
              echo 'export GOPATH=/home/ec2-user/go' >> /etc/profile.d/go.sh
              source /etc/profile.d/go.sh
              
              # Install Kafka CLI tools
              cd /opt
              curl -sO https://archive.apache.org/dist/kafka/3.5.1/kafka_2.13-3.5.1.tgz
              tar -xzf kafka_2.13-3.5.1.tgz
              ln -s kafka_2.13-3.5.1 kafka
              rm -f kafka_2.13-3.5.1.tgz
              echo 'export PATH=$PATH:/opt/kafka/bin' >> /etc/profile.d/kafka.sh
              
              # Create demo directory
              mkdir -p /home/ec2-user/demo
              mkdir -p /home/ec2-user/go
              chown -R ec2-user:ec2-user /home/ec2-user
              
              echo "Setup complete" > /tmp/setup-done
              EOF

  tags = { Name = "msk-capacity-demo-client" }

  depends_on = [aws_msk_cluster.demo]
}

# =============================================================================
# CloudWatch Alarm for Under-Replicated Partitions
# =============================================================================
# Note: MSK publishes UnderReplicatedPartitions per-broker, so we use metric math
# to sum across all brokers to detect cluster-wide issues.

resource "aws_cloudwatch_metric_alarm" "under_replicated" {
  alarm_name          = "msk-capacity-demo-under-replicated"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  alarm_description   = "Partitions are under-replicated - cluster needs more capacity"

  # Use metric queries to sum URPs across all brokers
  metric_query {
    id          = "urp1"
    return_data = false

    metric {
      metric_name = "UnderReplicatedPartitions"
      namespace   = "AWS/Kafka"
      period      = 60
      stat        = "Maximum"

      dimensions = {
        "Cluster Name" = aws_msk_cluster.demo.cluster_name
        "Broker ID"    = "1"
      }
    }
  }

  metric_query {
    id          = "urp2"
    return_data = false

    metric {
      metric_name = "UnderReplicatedPartitions"
      namespace   = "AWS/Kafka"
      period      = 60
      stat        = "Maximum"

      dimensions = {
        "Cluster Name" = aws_msk_cluster.demo.cluster_name
        "Broker ID"    = "2"
      }
    }
  }

  metric_query {
    id          = "total"
    expression  = "urp1+urp2"
    label       = "TotalUnderReplicatedPartitions"
    return_data = true
  }

  tags = { Name = "msk-capacity-demo-under-replicated-alarm" }
}

