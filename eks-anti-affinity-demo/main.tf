# EKS Pod Anti-Affinity Scheduling Demo
# Demonstrates how required pod anti-affinity causes scheduling failures
# when scaling beyond available nodes

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  cluster_name = "eks-anti-affinity-demo-${random_id.suffix.hex}"
  node_count   = 4 # Intentionally small - will cause scheduling issues
}

resource "random_id" "suffix" {
  byte_length = 4
}

#------------------------------------------------------------------------------
# VPC
#------------------------------------------------------------------------------

resource "aws_vpc" "demo" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.cluster_name}-vpc"
  }
}

resource "aws_internet_gateway" "demo" {
  vpc_id = aws_vpc.demo.id

  tags = {
    Name = "${local.cluster_name}-igw"
  }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.demo.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                          = "${local.cluster_name}-public-${count.index + 1}"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.demo.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.demo.id
  }

  tags = {
    Name = "${local.cluster_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

#------------------------------------------------------------------------------
# EKS Cluster
#------------------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${local.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_eks_cluster" "demo" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = "1.28"

  vpc_config {
    subnet_ids              = aws_subnet.public[*].id
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy
  ]
}

#------------------------------------------------------------------------------
# EKS Node Group - Intentionally Small (4 nodes)
#------------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "${local.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

resource "aws_eks_node_group" "demo" {
  cluster_name    = aws_eks_cluster.demo.name
  node_group_name = "${local.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id
  instance_types  = ["t3.medium"]

  # Fixed size node group - no autoscaling
  # This is the constraint that causes the anti-affinity issue
  scaling_config {
    desired_size = local.node_count
    max_size     = local.node_count # Cannot scale beyond 4 nodes
    min_size     = local.node_count
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_policy,
    aws_iam_role_policy_attachment.cni_policy,
    aws_iam_role_policy_attachment.registry_policy,
  ]

  tags = {
    Name = "${local.cluster_name}-node"
  }
}

#------------------------------------------------------------------------------
# Kubernetes Provider Configuration
#------------------------------------------------------------------------------

data "aws_eks_cluster_auth" "demo" {
  name = aws_eks_cluster.demo.name
}

provider "kubernetes" {
  host                   = aws_eks_cluster.demo.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.demo.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.demo.token
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.demo.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.demo.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.demo.token
  }
}

#------------------------------------------------------------------------------
# Metrics Server (required for HPA)
#------------------------------------------------------------------------------

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.11.0"

  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  depends_on = [aws_eks_node_group.demo]
}

#------------------------------------------------------------------------------
# Demo Application - Payment Service with Anti-Affinity
#------------------------------------------------------------------------------

resource "kubernetes_namespace" "demo" {
  metadata {
    name = "payments"
  }

  depends_on = [aws_eks_node_group.demo]
}

# The problematic deployment with REQUIRED anti-affinity
resource "kubernetes_deployment" "payments" {
  metadata {
    name      = "payments-api"
    namespace = kubernetes_namespace.demo.metadata[0].name
    labels = {
      app = "payments-api"
    }
  }

  spec {
    # Start with 2 replicas - works fine initially
    replicas = 2

    selector {
      match_labels = {
        app = "payments-api"
      }
    }

    template {
      metadata {
        labels = {
          app = "payments-api"
        }
      }

      spec {
        # THE PROBLEMATIC CONFIGURATION
        # Required anti-affinity means pods MUST be on different nodes
        # When replicas > nodes, pods will be stuck Pending
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

        container {
          name  = "payments-api"
          image = "hashicorp/http-echo:0.2.3"
          args  = ["-text=payments-api response", "-listen=:8080"]

          port {
            container_port = 8080
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }
      }
    }
  }

  depends_on = [helm_release.metrics_server]
}

resource "kubernetes_service" "payments" {
  metadata {
    name      = "payments-api"
    namespace = kubernetes_namespace.demo.metadata[0].name
  }

  spec {
    selector = {
      app = "payments-api"
    }

    port {
      port        = 80
      target_port = 8080
    }

    type = "ClusterIP"
  }
}

# HPA configured to scale up to 8 replicas
# But we only have 4 nodes, so 4 pods will be stuck Pending
resource "kubernetes_horizontal_pod_autoscaler_v2" "payments" {
  metadata {
    name      = "payments-api"
    namespace = kubernetes_namespace.demo.metadata[0].name
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "payments-api"
    }

    min_replicas = 2
    max_replicas = 8 # More than available nodes!

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 50
        }
      }
    }
  }

  depends_on = [kubernetes_deployment.payments]
}

#------------------------------------------------------------------------------
# Load Generator Pod
#------------------------------------------------------------------------------

resource "kubernetes_deployment" "load_generator" {
  metadata {
    name      = "load-generator"
    namespace = kubernetes_namespace.demo.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "load-generator"
      }
    }

    template {
      metadata {
        labels = {
          app = "load-generator"
        }
      }

      spec {
        container {
          name  = "load-generator"
          image = "busybox:1.36"

          command = ["/bin/sh", "-c", "while true; do sleep 3600; done"]

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_service.payments]
}
