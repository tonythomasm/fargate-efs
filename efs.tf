# provider "aws" {
#   region  = var.aws_region
#   profile = "default"
# }

# variable "aws_region" {
#   default = "us-east-1"
# }
# variable "cluster_name" {
#   default = "test-tony-eks"
# }

variable "namespaces" {
  type    = list(string)
  default = ["ns1"]   # set list of namespaces you want EFS+PV/PVC for
}


# variable "vpc_id" {}
# variable "subnet_ids" {
#   type = list(string)
# }
# variable "pod_sg_id" {} # security group used by pods (allow NFS 2049 from pods)

# data "aws_eks_cluster" "cluster" {
#   name = var.cluster_name
# }
# data "aws_eks_cluster_auth" "cluster" {
#   name = var.cluster_name
# }


# One security group per EFS filesystem (allows NFS from pod SG)
resource "aws_security_group" "efs_sg" {
  for_each = toset(var.namespaces)
  name     = "${var.cluster_name}-efs-sg-${each.key}"
  vpc_id   = aws_vpc.eks_vpc.id

  ingress {
    description     = "Allow NFS from pods"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    # security_groups = [var.pod_sg_id]
    cidr_blocks     = aws_subnet.private[*].cidr_block
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-efs-sg-${each.key}"
  }
}

# One EFS file system per namespace
resource "aws_efs_file_system" "efs" {
  for_each = toset(var.namespaces)

  creation_token = "${var.cluster_name}-${each.key}-efs"
  tags = {
    Name      = "${var.cluster_name}-efs-${each.key}"
    Namespace = each.key
  }
}

# Create an Access Point for each filesystem to isolate directory per namespace
# Only for Fargate (EC2 can mount EFS directly without access points)
resource "aws_efs_access_point" "ap" {
  for_each       = var.use_fargate ? aws_efs_file_system.efs : {}
  # for_each       = aws_efs_file_system.efs
  file_system_id = each.value.id

  posix_user {
    uid = 1001
    gid = 1001
  }

  root_directory {
    path = "/${each.key}"
    creation_info {
      owner_gid   = 1001
      owner_uid   = 1001
      permissions = "0750"
    }
  }

  tags = {
    Name = "${var.cluster_name}-ap-${each.key}"
  }
}

# Create mount targets: one per filesystem per subnet (ensures EFS is reachable in each AZ)
# Using count instead of for_each to avoid dynamic key issues
locals {
  mount_target_configs = var.use_fargate ? flatten([
    for ns in var.namespaces : [
      for idx, subnet_id in aws_subnet.private[*].id : {
        namespace = ns
        subnet_id = subnet_id
        index     = "${ns}-${idx}"
      }
    ]
  ]) : []
}

resource "aws_efs_mount_target" "mt" {
  count              = length(local.mount_target_configs)
  file_system_id     = aws_efs_file_system.efs[local.mount_target_configs[count.index].namespace].id
  subnet_id          = local.mount_target_configs[count.index].subnet_id
  security_groups    = [aws_security_group.efs_sg[local.mount_target_configs[count.index].namespace].id]
}

output "fs_id" {
  value = { for k, v in aws_efs_file_system.efs : k => v.id }
}

output "fs_access_point_id" {
  # value = var.use_fargate ? { for k, v in aws_efs_access_point.ap : k => v.id } : {}
  value = { for k, v in aws_efs_access_point.ap : k => v.id }
}

output "mount_targets" {
  value = var.use_fargate ? [for mt in aws_efs_mount_target.mt : mt.id] : []
}