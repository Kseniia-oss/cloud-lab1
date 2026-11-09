variable "aws_region" {
  description = "Регіон AWS"
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Префікс імен усіх ресурсів"
  type        = string
  default     = "tasks-api"
}

variable "alert_email" {
  description = "Email для бюджету та алертів CloudWatch (підписку SNS треба підтвердити з листа)"
  type        = string
}

variable "github_repo" {
  description = "GitHub-репозиторій у форматі owner/repo (регістр має значення) — лише йому дозволено OIDC-роль"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "Формат: owner/repo"
  }
}

variable "budget_limit_usd" {
  description = "Місячний бюджет у доларах"
  type        = number
  default     = 10
}

variable "vpc_cidr" {
  description = "Діапазон адрес VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "app_desired_count" {
  description = "Кількість екземплярів застосунку (2 — по одному в кожній AZ)"
  type        = number
  default     = 2
}

variable "app_cpu" {
  description = "CPU задачі Fargate (1024 = 1 vCPU)"
  type        = number
  default     = 256
}

variable "app_memory" {
  description = "Пам'ять задачі Fargate, MiB"
  type        = number
  default     = 512
}

variable "image_tag" {
  description = "Тег образу для першого створення task definition. Далі образи деплоїть GitHub Actions з тегом = хеш коміту"
  type        = string
  default     = "bootstrap"
}

variable "db_instance_class" {
  description = "Клас інстансу RDS (db.t4g.micro входить у Free Tier)"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_backup_retention_days" {
  description = "Скільки днів зберігати автоматичні бекапи (0 вимикає бекапи і point-in-time recovery)"
  type        = number
  default     = 1
}

variable "enable_github_oidc" {
  description = "Створити OIDC-провайдер і роль для GitHub Actions. У новому режимі AWS (проєкти, Free/Paid plan) це заборонено SCP, тому за замовчуванням вимкнено"
  type        = bool
  default     = false
}
