variable "project_name" {
  default = "craneops"
}

variable "location" {
  default = "swedencentral" # Student-friendly region
}

variable "sql_admin_username" {
  default = "craneadmin"
}

variable "sql_admin_password" {
  description = "Password for SQL Server. Pass via -var or env var."
  sensitive   = true
}