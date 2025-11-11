# EKS Fargate with EFS

This Terraform configuration sets up an Amazon EKS cluster on AWS Fargate with EFS (Elastic File System) support for persistent storage.

## Overview

The infrastructure includes:
- **VPC**: Custom VPC with public and private subnets across 2 availability zones
- **EKS Cluster**: Kubernetes cluster running on Fargate in private subnets
- **EFS**: Persistent file storage with namespace isolation via access points
- **IAM Roles**: Proper IAM configuration for EKS control plane and Fargate pod execution
- **Networking**: NAT Gateway for private subnet egress, Security Groups for pod and EFS access

## Files

- **[eks.tf](eks.tf)**: VPC, EKS cluster, Fargate profiles, and networking resources
- **[efs.tf](efs.tf)**: EFS file systems, access points, and mount targets
- **[terraform.tfvars](terraform.tfvars)**: Input variables (region, cluster name)

## Prerequisites

- AWS Account with appropriate permissions
- Terraform >= 1.0
- AWS CLI configured
- kubectl installed (for managing the cluster)

## Variables

Key variables defined in [eks.tf](eks.tf):

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-east-1` | AWS region |
| `cluster_name` | `test-eks` | EKS cluster name |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR block |
| `namespaces` | `["ns1"]` | Kubernetes namespaces for EFS |

## Quick Start

1. **Initialize Terraform**:
   ```bash
   terraform init
   ```

2. **Review the plan**:
   ```bash
   terraform plan
   ```

3. **Apply the configuration**:
   ```bash
   terraform apply
   ```

4. **Configure kubectl**:
   ```bash
   aws eks update-kubeconfig --name test-tony-eks --region us-east-1
   ```

## Outputs

After deployment, the following outputs are available:

- `eks_cluster_name`: Name of the EKS cluster
- `private_subnet_ids`: IDs of private subnets for the cluster
- `subnet_rages`: CIDR blocks of private subnets
- `fs_id`: Map of EFS file system IDs by namespace
- `fs_access_point_id`: Map of EFS access point IDs by namespace

## Architecture

### Networking
- 2 public subnets (one per AZ) with internet gateway access
- 2 private subnets (one per AZ) with NAT gateway for outbound traffic
- EKS control plane with public and private endpoint access

### Fargate Profiles
- `default`: Runs pods in the default namespace
- `kube-system`: Runs system pods
- `ns1`, `ns2`: Application-specific namespaces

### Storage
- EFS mounted to pods in specified namespaces
- Access points provide directory isolation per namespace
- Mount targets in each AZ for high availability

## Customization

To add more namespaces with EFS:
1. Update `namespaces` variable in [efs.tf](efs.tf)
2. (Optional) Add corresponding Fargate profile in [eks.tf](eks.tf)

Example:
```hcl
variable "namespaces" {
  type    = list(string)
  default = ["ns1", "ns2", "ns3"]
}
```

## Cleanup

To destroy all resources:
```bash
terraform destroy
```

## Notes

- EKS control plane endpoint is publicly accessible by default (`endpoint_public_access = true`)
- All pods run on Fargate in private subnets
- EFS access is restricted to pod security group CIDR ranges
- NAT gateway provides outbound internet access for private subnets