provider "aws" {
  version = "~> 3.74.1"
  profile = "facetsnew"
  region  = "us-east-1"
}

module "ecs_service" {
  source = "../"

  instance      = jsondecode(file("${path.module}/test.json"))
  instance_name = "test-service"
  environment = {
    name        = "test"
    unique_name = "project_test"
  }
  aws_vpc_details = {
    attributes = {
      subnet_ids = ["subnet-12345678"] # Replace with actual subnet IDs
    }
  }
  inputs = {
    ecs_cluster_details = {
      attributes = {
        cluster_arn = "arn:aws:ecs:us-east-1:123456789012:cluster/test-cluster" # Replace with actual ARN
      }
    }
  }
}
