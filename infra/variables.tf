variable "region" {
  description = "AWS Region"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project prefix"
  type        = string
  default     = "jenkinsci/cd"
}

variable "account_id" {
  description = "Your AWS Account ID"
  type        = string
  # default     = "" 
}

