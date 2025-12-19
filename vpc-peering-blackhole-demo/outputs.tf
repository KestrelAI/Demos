# =============================================================================
# Outputs for Kestrel VPC Peering Blackhole Demo
# =============================================================================

output "server_private_ip" {
  description = "Private IP of the server in VPC B"
  value       = aws_instance.server.private_ip
}

output "client_ok_id" {
  description = "Instance ID of client-ok (in subnet A1 - has return route)"
  value       = aws_instance.client_ok.id
}

output "client_broken_id" {
  description = "Instance ID of client-broken (in subnet A2 - NO return route)"
  value       = aws_instance.client_broken.id
}

output "server_id" {
  description = "Instance ID of the server"
  value       = aws_instance.server.id
}

output "vpc_a_id" {
  description = "VPC A ID (clients)"
  value       = aws_vpc.a.id
}

output "vpc_b_id" {
  description = "VPC B ID (server)"
  value       = aws_vpc.b.id
}

output "vpc_b_route_table_id" {
  description = "VPC B route table ID (to inspect the misconfigured route)"
  value       = aws_route_table.b_rt.id
}

output "peering_connection_id" {
  description = "VPC peering connection ID"
  value       = aws_vpc_peering_connection.peer.id
}

# Demo helper outputs
output "demo_test_client_ok_command" {
  description = "Command to test from client-ok (should succeed)"
  value       = <<-EOT
    # Test from client-ok (should succeed):
    CLIENT_OK=${aws_instance.client_ok.id}
    SERVER_IP=${aws_instance.server.private_ip}
    CMD_ID=$(aws ssm send-command \
      --document-name "AWS-RunShellScript" \
      --targets "Key=instanceids,Values=$CLIENT_OK" \
      --parameters "commands=curl -m 5 -s http://$SERVER_IP:8080" \
      --query "Command.CommandId" --output text)
    sleep 3
    aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$CLIENT_OK" --query "StandardOutputContent" --output text
  EOT
}

output "demo_test_client_broken_command" {
  description = "Command to test from client-broken (should TIMEOUT)"
  value       = <<-EOT
    # Test from client-broken (should TIMEOUT):
    CLIENT_BAD=${aws_instance.client_broken.id}
    SERVER_IP=${aws_instance.server.private_ip}
    CMD_ID=$(aws ssm send-command \
      --document-name "AWS-RunShellScript" \
      --targets "Key=instanceids,Values=$CLIENT_BAD" \
      --parameters "commands=curl -m 5 -v http://$SERVER_IP:8080 || echo TIMEOUT" \
      --query "Command.CommandId" --output text)
    sleep 8
    aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$CLIENT_BAD" --query "StandardOutputContent" --output text
  EOT
}

# VPC Flow Logs outputs
output "flow_logs_vpc_a_log_group" {
  description = "CloudWatch Log Group for VPC A Flow Logs"
  value       = aws_cloudwatch_log_group.flow_logs_a.name
}

output "flow_logs_vpc_b_log_group" {
  description = "CloudWatch Log Group for VPC B Flow Logs (check for REJECT packets)"
  value       = aws_cloudwatch_log_group.flow_logs_b.name
}
