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
}

variable "vpc_cidr" {
  description = "CIDR range of the VPC, used to limit database traffic to inside the network."
  type        = string
}

variable "private_subnet_id" {
  description = "Private subnet (no internet gateway route) for the web server."
  type        = string
}

variable "db_subnet_ids" {
  description = "At least two private subnets in different availability zones for the database."
  type        = list(string)
}

variable "load_balancer_sg_id" {
  description = "Security group of the load balancer that forwards traffic to the web server."
  type        = string
}

variable "ami_id" {
  description = "AMI for the web server (e.g. latest Amazon Linux 2023)."
  type        = string
}
