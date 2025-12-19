# =============================================================================
# Variables for Kestrel VPC Peering Blackhole Demo
# =============================================================================

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-west-1"
}
