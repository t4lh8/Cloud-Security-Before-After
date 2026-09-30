variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"
}

variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "demo-app"
}

variable "vpc_id" {
  description = "VPC to deploy into."
  type        = string
  default     = "vpc-00000000000000000"
}

variable "public_subnet_id" {
  description = "Public subnet for the web server."
  type        = string
  default     = "subnet-00000000000000000"
}

variable "ami_id" {
  description = "AMI for the web server."
  type        = string
  default     = "ami-00000000000000000"
}
