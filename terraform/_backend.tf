terraform {
  backend "s3" {
    bucket = "facp-terraform-state"
    key    = "terraform.tfstate"
    region = "ap-southeast-2"
  }
}