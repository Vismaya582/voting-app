provider "aws" {
    region = "ap-south-1"
}

resource "aws_vpc" "voter-app-vpc" {
    cidr_block = "10.0.0.0/16"
    tags = {
        Name = "voter-app-vpc"
    }
}

# Create 4 Subnets- 2 Public and 2 Private
resource "aws_subnet" "public_subnet_1" {
    vpc_id            = aws_vpc.voter-app-vpc.id
    cidr_block        = "10.0.1.0/24"
    availability_zone = "ap-south-1a"
    tags = {
        Name = "public-subnet-1"
        "kubernetes.io/role/elb" = "1"
    }
}

resource "aws_subnet" "public_subnet_2" {
    vpc_id            = aws_vpc.voter-app-vpc.id
    cidr_block        = "10.0.2.0/24"
    availability_zone = "ap-south-1b"
    tags = {
        Name = "public-subnet-2"
        "kubernetes.io/role/elb" = "1"
    }
}

resource "aws_subnet" "private_subnet_1" {
    vpc_id            = aws_vpc.voter-app-vpc.id
    cidr_block        = "10.0.3.0/24"
    availability_zone = "ap-south-1a"
    tags = {
        Name = "private-subnet-1"
        "kubernetes.io/role/internal-elb" = "1"
    }
}

resource "aws_subnet" "private_subnet_2" {
    vpc_id            = aws_vpc.voter-app-vpc.id
    cidr_block        = "10.0.4.0/24"
    availability_zone = "ap-south-1b"
    tags = {
        Name = "private-subnet-2"
        "kubernetes.io/role/internal-elb" = "1"
    }
}

# Create Internet Gateway
resource "aws_internet_gateway" "voter-app-igw" {
    vpc_id = aws_vpc.voter-app-vpc.id
    tags = {
        Name = "voter-app-igw"
    }
}

# Create Route Table for Public Subnets
resource "aws_route_table" "public_route_table" {
    vpc_id = aws_vpc.voter-app-vpc.id
    tags = {
        Name = "public-route-table"
    }
}

# Create Route to Internet Gateway
resource "aws_route" "public_route" {
    route_table_id         = aws_route_table.public_route_table.id
    destination_cidr_block = "0.0.0.0/0"
    gateway_id             = aws_internet_gateway.voter-app-igw.id
}

# Route table association for public subnets
resource "aws_route_table_association" "public_subnet_1_association" {
    subnet_id      = aws_subnet.public_subnet_1.id
    route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "public_subnet_2_association" {
    subnet_id      = aws_subnet.public_subnet_2.id
    route_table_id = aws_route_table.public_route_table.id
}

# NAT Gateway for private subnets
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_subnet_1.id
}

resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.voter-app-vpc.id
}

resource "aws_route" "private_route" {
  route_table_id         = aws_route_table.private_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

resource "aws_route_table_association" "private_subnet_1_association" {
  subnet_id      = aws_subnet.private_subnet_1.id
  route_table_id = aws_route_table.private_route_table.id
}

resource "aws_route_table_association" "private_subnet_2_association" {
  subnet_id      = aws_subnet.private_subnet_2.id
  route_table_id = aws_route_table.private_route_table.id
}

# EKS Cluster

resource "aws_eks_cluster" "voter-app-eks-cluster" {
  name     = "voter-app-eks-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids = [
      aws_subnet.public_subnet_1.id,
      aws_subnet.public_subnet_2.id,
      aws_subnet.private_subnet_1.id,
      aws_subnet.private_subnet_2.id
    ]
  }

  tags = {
    Name = "voter-app-eks-cluster"
  }
}

# IAM Role for EKS Cluster
resource "aws_iam_role" "eks_cluster_role" {
    name = "eks-cluster-role"
    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Action = "sts:AssumeRole"
                Effect = "Allow"
                Principal = {
                    Service = "eks.amazonaws.com"
                }
            }
        ]
    })
}   

# Attach necessary policies to the EKS Cluster Role
resource "aws_iam_role_policy_attachment" "eks_cluster_role_attachment" {
    role       = aws_iam_role.eks_cluster_role.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_node_group" "voter-app-node-group" {
  cluster_name    = aws_eks_cluster.voter-app-eks-cluster.name
  node_group_name = "voter-app-node-group"
  node_role_arn   = aws_iam_role.eks_node_group_role.arn
  instance_types = ["m7i-flex.large"]
  subnet_ids      = [
    aws_subnet.private_subnet_1.id,
    aws_subnet.private_subnet_2.id
  ]
  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  tags = {
    Name = "voter-app-node-group"
  }
  
}

# IAM Role for EKS Node Group
resource "aws_iam_role" "eks_node_group_role" {
    name = "eks-node-group-role"
    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Action = "sts:AssumeRole"
                Effect = "Allow"
                Principal = {
                    Service = "ec2.amazonaws.com"
                }
            }
        ]
    })
}

# Attach necessary policies to the EKS Node Group Role
resource "aws_iam_role_policy_attachment" "eks_node_group_role_attachment" {
    role       = aws_iam_role.eks_node_group_role.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy_attachment" {
    role       = aws_iam_role.eks_node_group_role.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_registry_policy_attachment" {
    role       = aws_iam_role.eks_node_group_role.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

