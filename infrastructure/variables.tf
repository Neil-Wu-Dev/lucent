variable "ec2_instance_profile_name" {
  description = "Existing AWS Academy instance profile attached to private EC2 instances for management access."
  type        = string
  default     = "LabInstanceProfile"
}

variable "backend_ecr_repository_name" {
  description = "ECR repository name for the Lucent Backend Docker image."
  type        = string
  default     = "lucent-backend"
}

variable "backend_container_port" {
  description = "Port exposed by the Lucent Backend container on each private EC2 instance."
  type        = number
  default     = 8080
}

variable "alb_listener_port" {
  description = "Public HTTP listener port for the Lucent Backend Application Load Balancer."
  type        = number
  default     = 80
}

variable "frontend_nginx_port" {
  description = "Port used by Nginx on each private frontend EC2 instance."
  type        = number
  default     = 80
}
