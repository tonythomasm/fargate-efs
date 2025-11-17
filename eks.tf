provider "aws" {
  region  = var.aws_region
  profile = "default"
}

variable "aws_region" {
  default = "us-east-1"
}
variable "cluster_name" {
  default = "test-tony-eks"
}

# VPC config (new VPC created by this template)
variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "use_fargate" {
  type        = bool
  default     = true
  description = "Set to true for Fargate-only, false to use EC2 node groups"
}

variable "node_group_desired_size" {
  type        = number
  default     = 2
  description = "Desired number of nodes in the node group (only used if use_fargate=false)"
}

variable "node_group_min_size" {
  type        = number
  default     = 1
  description = "Minimum number of nodes in the node group"
}

variable "node_group_max_size" {
  type        = number
  default     = 4
  description = "Maximum number of nodes in the node group"
}

variable "node_instance_types" {
  type        = list(string)
  default     = ["t3.medium"]
  description = "Instance types for node group"
}

# Pick the first 2 AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Create new VPC (we're not using the default VPC)
resource "aws_vpc" "eks_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

# Internet Gateway for the VPC
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.eks_vpc.id
  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

# Create 2 public subnets (one per AZ)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.eks_vpc.id
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  cidr_block              = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index + 10)
  map_public_ip_on_launch = true
  tags = {
    Name = "${var.cluster_name}-public-${count.index + 1}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

# Create 2 private subnets (one per AZ) for pods
resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = aws_vpc.eks_vpc.id
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  cidr_block              = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index + 20)
  map_public_ip_on_launch = false
  tags = {
    Name = "${var.cluster_name}-private-${count.index + 1}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

# Public route table -> IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.eks_vpc.id
  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}

resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route table (no IGW route initially)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.eks_vpc.id
  tags = {
    Name = "${var.cluster_name}-private-rt"
  }
}

resource "aws_route_table_association" "private_assoc" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Elastic IP and NAT gateway (placed in first public subnet) -> gives private subnets outbound internet
resource "aws_eip" "nat" {
  tags = {
    Name = "${var.cluster_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags = {
    Name = "${var.cluster_name}-nat"
  }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route" "private_to_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
  depends_on             = [aws_nat_gateway.nat]
}

# IAM role for EKS node group (EC2 instances)
resource "aws_iam_role" "eks_node_group" {
  count = var.use_fargate ? 0 : 1
  name  = "${var.cluster_name}-eks-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# IAM role for EKS control plane
resource "aws_iam_role" "eks_cluster" {
  name = "${var.cluster_name}-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Attach required policies to node group role - start
resource "aws_iam_role_policy_attachment" "eks_node_AmazonEKSWorkerNodePolicy" {
  count      = var.use_fargate ? 0 : 1
  role       = aws_iam_role.eks_node_group[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_node_AmazonEKS_CNI_Policy" {
  count      = var.use_fargate ? 0 : 1
  role       = aws_iam_role.eks_node_group[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_node_AmazonEC2ContainerRegistryReadOnly" {
  count      = var.use_fargate ? 0 : 1
  role       = aws_iam_role.eks_node_group[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
# Attach required policies to node group role - Done

# Attach required policies to EKS cluster role - START
resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}
resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSServicePolicy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
}
# Attach required policies to EKS cluster role - START



# IAM role and attach policy for Fargate pod execution - START
resource "aws_iam_role" "eks_fargate_pods" {
  count = var.use_fargate ? 1 : 0
  name = "${var.cluster_name}-fargate-pods-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks-fargate-pods.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_fargate_exec" {
  count      = var.use_fargate ? 1 : 0
  role       = aws_iam_role.eks_fargate_pods[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
}
# IAM role and attach policy for Fargate pod execution - END


# Security group for node group (allow kubelet, pod communication, etc.)
resource "aws_security_group" "node_sg" {
  count       = var.use_fargate ? 0 : 1
  name        = "${var.cluster_name}-node-sg"
  description = "Node group security group"
  vpc_id      = aws_vpc.eks_vpc.id

  ingress {
    description     = "Allow pods to communicate with nodes"
    from_port       = 1025
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.pod_sg.id]
  }

  ingress {
    description = "Allow SSH (optional, remove if not needed)"
    from_port   = 22
    to_port     = 22
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
    Name = "${var.cluster_name}-node-sg"
  }
}


# EKS node group (only created if use_fargate = false)
resource "aws_eks_node_group" "main" {
  count           = var.use_fargate ? 0 : 1
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "${var.cluster_name}-node-group"
  node_role_arn   = aws_iam_role.eks_node_group[0].arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = var.node_group_desired_size
    min_size     = var.node_group_min_size
    max_size     = var.node_group_max_size
  }

  instance_types = var.node_instance_types

  tags = {
    Name = "${var.cluster_name}-node-group"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.eks_node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.eks_node_AmazonEC2ContainerRegistryReadOnly,
  ]
}



# Security group for pods/cluster (allow outbound)
resource "aws_security_group" "pod_sg" {
  name        = "${var.cluster_name}-pod-sg"
  description = "Pod security group - private subnets"
  vpc_id      = aws_vpc.eks_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EKS cluster using the private subnets (2 AZs). Control plane endpoint remains public by default.
resource "aws_eks_cluster" "eks_cluster" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.33"

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = ["0.0.0.0/0"]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.eks_cluster_AmazonEKSServicePolicy,
  ]
}

# Fargate profiles: schedule pods in namespaces onto Fargate in private subnets
resource "aws_eks_fargate_profile" "fargate_profile_default" {
  count                  = var.use_fargate ? 1 : 0
  cluster_name           = aws_eks_cluster.eks_cluster.name
  fargate_profile_name   = "${var.cluster_name}-fp-default"
  pod_execution_role_arn = aws_iam_role.eks_fargate_pods[0].arn
  subnet_ids             = aws_subnet.private[*].id

  selector {
    namespace = "default"
  }
}

resource "aws_eks_fargate_profile" "fargate_profile_kube_system" {
  count                  = var.use_fargate ? 1 : 0
  cluster_name           = aws_eks_cluster.eks_cluster.name
  fargate_profile_name   = "${var.cluster_name}-fp-kube-system"
  pod_execution_role_arn = aws_iam_role.eks_fargate_pods[0].arn
  subnet_ids             = aws_subnet.private[*].id

  selector {
    namespace = "kube-system"
  }
}

resource "aws_eks_fargate_profile" "fargate_profile_ns1" {
  count                  = var.use_fargate ? 1 : 0
  cluster_name           = aws_eks_cluster.eks_cluster.name
  fargate_profile_name   = "${var.cluster_name}-fp-ns1"
  pod_execution_role_arn = aws_iam_role.eks_fargate_pods[0].arn
  subnet_ids             = aws_subnet.private[*].id

  selector {
    namespace = "ns1"
  }
}

resource "aws_eks_fargate_profile" "fargate_profile_ns2" {
  count                  = var.use_fargate ? 1 : 0
  cluster_name           = aws_eks_cluster.eks_cluster.name
  fargate_profile_name   = "${var.cluster_name}-fp-ns2"
  pod_execution_role_arn = aws_iam_role.eks_fargate_pods[0].arn
  subnet_ids             = aws_subnet.private[*].id

  selector {
    namespace = "ns2"
  }
}


output "eks_cluster_name" {
  value = aws_eks_cluster.eks_cluster.name
}
output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
output "subnet_ranges" {
  value = aws_subnet.private[*].cidr_block
}
output "node_group_id" {
  value = var.use_fargate ? null : try(aws_eks_node_group.main[0].id, null)
}
output "deployment_mode" {
  value = var.use_fargate ? "Fargate-only" : "EC2 Node Group"
}
