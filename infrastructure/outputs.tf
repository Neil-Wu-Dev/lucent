output "vpc_id" {
  description = "Lucent VPC ID."
  value       = aws_vpc.lucent_vpc.id
}

output "public_subnet_ids" {
  description = "Public subnets for future Internet-facing infrastructure such as ALB and NAT."
  value = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id
  ]
}

output "private_application_subnet_ids" {
  description = "Private application subnets that hold the two EC2 instances."
  value = [
    aws_subnet.app_a.id,
    aws_subnet.app_b.id
  ]
}

output "private_database_subnet_ids" {
  description = "Private database subnets reserved for future PostgreSQL RDS."
  value = [
    aws_subnet.database_a.id,
    aws_subnet.database_b.id
  ]
}

output "application_instance_ids" {
  description = "Private application EC2 instance IDs."
  value = [
    aws_instance.app_a.id,
    aws_instance.app_b.id
  ]
}

output "application_private_ips" {
  description = "Private IP addresses of the application EC2 instances."
  value = [
    aws_instance.app_a.private_ip,
    aws_instance.app_b.private_ip
  ]
}

output "nat_gateway_id" {
  description = "NAT Gateway used by private application EC2 instances for outbound Internet access."
  value       = aws_nat_gateway.nat.id
}

output "backend_ecr_repository_url" {
  description = "ECR repository URL for the Lucent Backend Docker image."
  value       = aws_ecr_repository.backend.repository_url
}

output "backend_alb_dns_name" {
  description = "DNS name of the Internet-facing ALB for Lucent Backend."
  value       = aws_lb.backend.dns_name
}

output "backend_target_group_arn" {
  description = "Target Group ARN that contains the two private backend EC2 instances."
  value       = aws_lb_target_group.backend.arn
}

output "frontend_target_group_arn" {
  description = "Target Group ARN that contains the two private frontend Nginx EC2 instances."
  value       = aws_lb_target_group.frontend.arn
}

output "alb_security_group_id" {
  description = "Security Group ID for the Lucent Backend ALB."
  value       = aws_security_group.alb.id
}

output "application_security_group_id" {
  description = "Security Group ID for the private Lucent Backend EC2 instances."
  value       = aws_security_group.app_ec2.id
}

output "database_security_group_id" {
  description = "Security Group ID reserved for future PostgreSQL RDS."
  value       = aws_security_group.database.id
}

output "frontend_security_group_id" {
  description = "Security Group ID for the private Lucent Frontend Nginx EC2 instances."
  value       = aws_security_group.frontend_ec2.id
}

output "frontend_instance_ids" {
  description = "Private frontend EC2 instance IDs."
  value = [
    aws_instance.frontend_a.id,
    aws_instance.frontend_b.id
  ]
}

output "frontend_private_ips" {
  description = "Private IP addresses of the frontend EC2 instances."
  value = [
    aws_instance.frontend_a.private_ip,
    aws_instance.frontend_b.private_ip
  ]
}

output "lucent_alb_url" {
  description = "HTTP URL for Lucent through the shared ALB. /api/* routes to backend; all other paths route to frontend."
  value       = "http://${aws_lb.backend.dns_name}"
}
