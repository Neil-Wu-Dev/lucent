output "database_endpoint" {
  description = "Private PostgreSQL RDS endpoint for backend connections."
  value       = aws_db_instance.lucent.address
}

output "database_port" {
  description = "PostgreSQL port exposed only to the backend EC2 security group."
  value       = aws_db_instance.lucent.port
}

output "database_name" {
  description = "Initial Lucent PostgreSQL database name."
  value       = aws_db_instance.lucent.db_name
}

output "database_username" {
  description = "PostgreSQL master username used by the backend deployment."
  value       = aws_db_instance.lucent.username
}

output "database_password" {
  description = "PostgreSQL master password for the deployment script."
  value       = var.database_password
  sensitive   = true
}
