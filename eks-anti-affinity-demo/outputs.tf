output "region" {
  description = "AWS region"
  value       = var.region
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.demo.name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = aws_eks_cluster.demo.endpoint
}

output "node_count" {
  description = "Number of nodes in the cluster (fixed)"
  value       = local.node_count
}

output "kubeconfig_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.demo.name}"
}

output "check_pods_command" {
  description = "Command to check pod status"
  value       = "kubectl get pods -n payments -o wide"
}

output "check_pending_events" {
  description = "Command to see why pods are pending"
  value       = "kubectl get events -n payments --field-selector reason=FailedScheduling"
}

output "trigger_scale_up" {
  description = "Command to manually scale and trigger the issue"
  value       = "kubectl scale deployment payments-api -n payments --replicas=8"
}

output "watch_hpa" {
  description = "Command to watch HPA scaling"
  value       = "kubectl get hpa -n payments -w"
}

#------------------------------------------------------------------------------
# Fix Commands
#------------------------------------------------------------------------------

output "fix_description" {
  description = "Explanation of the fix"
  value       = <<-EOT

    THE PROBLEM:
    The payments-api deployment has 'requiredDuringSchedulingIgnoredDuringExecution'
    pod anti-affinity, which means each pod MUST run on a different node.

    With only ${local.node_count} nodes and HPA configured to scale up to 8 replicas,
    pods beyond ${local.node_count} will be stuck in Pending state forever.

    THE FIX:
    Change from 'required' to 'preferred' anti-affinity. This allows Kubernetes
    to schedule pods on the same node if necessary, while still preferring spread.

  EOT
}

output "fix_kubectl_patch" {
  description = "kubectl command to fix the anti-affinity issue"
  value       = <<-EOT
    kubectl patch deployment payments-api -n payments --type='json' -p='[
      {
        "op": "remove",
        "path": "/spec/template/spec/affinity/podAntiAffinity/requiredDuringSchedulingIgnoredDuringExecution"
      },
      {
        "op": "add",
        "path": "/spec/template/spec/affinity/podAntiAffinity/preferredDuringSchedulingIgnoredDuringExecution",
        "value": [{
          "weight": 100,
          "podAffinityTerm": {
            "labelSelector": {
              "matchLabels": {
                "app": "payments-api"
              }
            },
            "topologyKey": "kubernetes.io/hostname"
          }
        }]
      }
    ]'
  EOT
}

output "fix_terraform" {
  description = "Terraform fix - change the affinity block"
  value       = <<-EOT
    # Before (causes scheduling deadlock):
    affinity {
      pod_anti_affinity {
        required_during_scheduling_ignored_during_execution {
          label_selector {
            match_labels = {
              app = "payments-api"
            }
          }
          topology_key = "kubernetes.io/hostname"
        }
      }
    }

    # After (flexible scheduling):
    affinity {
      pod_anti_affinity {
        preferred_during_scheduling_ignored_during_execution {
          weight = 100
          pod_affinity_term {
            label_selector {
              match_labels = {
                app = "payments-api"
              }
            }
            topology_key = "kubernetes.io/hostname"
          }
        }
      }
    }
  EOT
}

output "alternative_fix_add_nodes" {
  description = "Alternative fix - increase node count"
  value       = <<-EOT
    # If you need strict anti-affinity, add more nodes instead:

    # Terraform:
    scaling_config {
      desired_size = 8   # Match HPA max_replicas
      max_size     = 8
      min_size     = 4
    }

    # AWS CLI:
    aws eks update-nodegroup-config \
      --cluster-name ${aws_eks_cluster.demo.name} \
      --nodegroup-name ${aws_eks_node_group.demo.node_group_name} \
      --scaling-config minSize=4,maxSize=8,desiredSize=8
  EOT
}
