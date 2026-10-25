# =========================
# PostgreSQL RDS
# =========================
# The subnet group places RDS only in the two dedicated private database
# subnets. The instance is Single-AZ for this learning environment and is
# reachable only through the existing database security group.

variable "database_name" {
  description = "Initial PostgreSQL database name for Lucent."
  type        = string
  default     = "lucent"
}

variable "database_username" {
  description = "Master username for the Lucent PostgreSQL database."
  type        = string
  default     = "lucentadmin"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9]{0,15}$", var.database_username))
    error_message = "The RDS PostgreSQL master username must start with a letter and contain at most 16 letters or numbers."
  }
}

variable "database_password" {
  description = "Master password for PostgreSQL. Supply through TF_VAR_database_password or a local ignored tfvars file."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.database_password) >= 8 && length(var.database_password) <= 128 && can(regex("^[^/@\"]+$", var.database_password))
    error_message = "The RDS PostgreSQL password must contain 8-128 characters and cannot include slash, double quote, or at sign."
  }
}

resource "aws_db_subnet_group" "lucent" {
  name       = "lucent-database-subnets"
  subnet_ids = [aws_subnet.database_a.id, aws_subnet.database_b.id]

  tags = {
    Name = "lucent-database-subnets"
  }
}

resource "aws_db_instance" "lucent" {
  identifier = "lucent-postgres"

  engine         = "postgres"
  instance_class = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 25
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.database_name
  username = var.database_username
  password = var.database_password

  db_subnet_group_name   = aws_db_subnet_group.lucent.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 0
  deletion_protection     = false
  skip_final_snapshot     = true
  apply_immediately       = true

  tags = {
    Name = "lucent-postgres"
  }
}
