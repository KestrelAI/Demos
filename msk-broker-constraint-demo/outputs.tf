# =============================================================================
# Outputs for Kestrel MSK Partition Hotspot Demo
# =============================================================================

output "msk_cluster_arn" {
  description = "ARN of the MSK cluster"
  value       = aws_msk_cluster.demo.arn
}

output "msk_cluster_name" {
  description = "Name of the MSK cluster"
  value       = aws_msk_cluster.demo.cluster_name
}

output "bootstrap_brokers" {
  description = "Plaintext bootstrap brokers for MSK cluster"
  value       = aws_msk_cluster.demo.bootstrap_brokers
}

output "bootstrap_brokers_tls" {
  description = "TLS bootstrap brokers for MSK cluster"
  value       = aws_msk_cluster.demo.bootstrap_brokers_tls
}

output "zookeeper_connect" {
  description = "Zookeeper connection string"
  value       = aws_msk_cluster.demo.zookeeper_connect_string
}

output "client_instance_id" {
  description = "Instance ID of the client EC2 instance"
  value       = aws_instance.client.id
}

output "client_private_ip" {
  description = "Private IP of the client instance"
  value       = aws_instance.client.private_ip
}

output "cloudwatch_log_group" {
  description = "CloudWatch Log Group for MSK logs"
  value       = aws_cloudwatch_log_group.msk_logs.name
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.msk.id
}

# Helper commands
output "ssm_connect_command" {
  description = "Command to connect to client instance via SSM"
  value       = "aws ssm start-session --target ${aws_instance.client.id}"
}

output "create_topic_command" {
  description = "Command to create the demo topic"
  value       = <<-EOT
    # Connect to client instance first, then run:
    /opt/kafka/bin/kafka-topics.sh --create \
      --topic hotspot-demo \
      --partitions 6 \
      --replication-factor 2 \
      --bootstrap-server ${aws_msk_cluster.demo.bootstrap_brokers}
  EOT
}

output "describe_topic_command" {
  description = "Command to describe topic partitions"
  value       = <<-EOT
    /opt/kafka/bin/kafka-topics.sh --describe \
      --topic hotspot-demo \
      --bootstrap-server ${aws_msk_cluster.demo.bootstrap_brokers}
  EOT
}

output "consumer_groups_command" {
  description = "Command to list consumer groups and lag"
  value       = <<-EOT
    /opt/kafka/bin/kafka-consumer-groups.sh --list \
      --bootstrap-server ${aws_msk_cluster.demo.bootstrap_brokers}
    
    # To see lag for a specific group:
    /opt/kafka/bin/kafka-consumer-groups.sh --describe \
      --group hotspot-consumer \
      --bootstrap-server ${aws_msk_cluster.demo.bootstrap_brokers}
  EOT
}
