# Output to display after terraform apply
output "eks_cluster_endpoint" {
  value = aws_eks_cluster.voter-app-eks-cluster.endpoint
}

output "eks_cluster_name" {
  value = aws_eks_cluster.voter-app-eks-cluster.name
}