output "app_url" {
  description = "Публічна адреса застосунку (через ALB)"
  value       = "http://${aws_lb.main.dns_name}"
}

output "swagger_url" {
  description = "Swagger UI"
  value       = "http://${aws_lb.main.dns_name}/docs"
}

output "github_actions_role_arn" {
  description = "Вставити в GitHub: Settings → Secrets and variables → Actions → Variables → AWS_ROLE_ARN"
  value       = var.enable_github_oidc ? aws_iam_role.github_actions[0].arn : null
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "db_endpoint" {
  description = "Приватна адреса бази (доступна лише зсередини VPC)"
  value       = aws_db_instance.main.address
}

output "db_password_secret_arn" {
  description = "Де лежить пароль від бази (Secrets Manager)"
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.main.dashboard_name}"
}
