terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    # Configure remote state
    # bucket = "my-terraform-state"
    # key    = "eav-platform/terraform.tfstate"
    # region = "us-east-1"
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = local.common_tags
  }
}
