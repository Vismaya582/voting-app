# Configuration for S3 Bucket and DynamoDB Table for Terraform State Management

terraform {
  backend "s3" {
    bucket         = "voting-app-project-2-terraform"
    key            = "project-2/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "voting-app-lock-table"
    encrypt        = true
  }
}