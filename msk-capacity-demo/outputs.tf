output "msk_cluster_arn" {
  description = "ARN of the MSK cluster"
  value       = aws_msk_cluster.demo.arn
}

output "cluster_arn" {
  description = "ARN of the MSK cluster (alias)"
  value       = aws_msk_cluster.demo.arn
}

output "msk_cluster_name" {
  description = "Name of the MSK cluster"
  value       = aws_msk_cluster.demo.cluster_name
}

output "bootstrap_brokers" {
  description = "Plaintext bootstrap brokers"
  value       = aws_msk_cluster.demo.bootstrap_brokers
}

output "client_instance_id" {
  description = "EC2 instance ID for SSM connection"
  value       = aws_instance.client.id
}

output "number_of_brokers" {
  description = "Current number of brokers"
  value       = aws_msk_cluster.demo.number_of_broker_nodes
}

output "add_broker_command" {
  description = "AWS CLI command to add brokers (Step 1 of fix)"
  value       = "aws kafka update-broker-count --cluster-arn ${aws_msk_cluster.demo.arn} --current-version $(aws kafka describe-cluster --cluster-arn ${aws_msk_cluster.demo.arn} --query 'ClusterInfo.CurrentVersion' --output text) --target-number-of-broker-nodes 4"
}

output "partition_reassignment_info" {
  description = "Information for partition reassignment (Step 2 of fix)"
  value = {
    instance_id       = aws_instance.client.id
    bootstrap_servers = aws_msk_cluster.demo.bootstrap_brokers
    topic             = "stress-test"
    new_broker_list   = "1,2,3,4"
    commands = {
      generate = "/opt/kafka/bin/kafka-reassign-partitions.sh --bootstrap-server ${aws_msk_cluster.demo.bootstrap_brokers} --topics-to-move-json-file /tmp/topics.json --broker-list 1,2,3,4 --generate"
      execute  = "/opt/kafka/bin/kafka-reassign-partitions.sh --bootstrap-server ${aws_msk_cluster.demo.bootstrap_brokers} --reassignment-json-file /tmp/reassignment.json --execute"
      verify   = "/opt/kafka/bin/kafka-reassign-partitions.sh --bootstrap-server ${aws_msk_cluster.demo.bootstrap_brokers} --reassignment-json-file /tmp/reassignment.json --verify"
    }
  }
}


