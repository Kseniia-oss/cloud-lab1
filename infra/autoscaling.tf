locals {
  scale_min         = 1
  scale_max         = 3
  scale_target_cpu  = 60
  lab2_service_dims = { ClusterName = aws_ecs_cluster.main.name, ServiceName = aws_ecs_service.app.name }
}

resource "aws_appautoscaling_target" "app" {
  min_capacity       = local.scale_min
  max_capacity       = local.scale_max
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  lifecycle {
    ignore_changes = [min_capacity]
  }
}

resource "aws_appautoscaling_policy" "app_cpu" {
  name               = "${local.name}-cpu-target"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.app.resource_id
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  service_namespace  = aws_appautoscaling_target.app.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = local.scale_target_cpu
    scale_out_cooldown = 60
    scale_in_cooldown  = 180

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "capacity_ceiling" {
  alarm_name          = "${local.name}-maximum-tasks"
  alarm_description   = "Бажана кількість завдань ECS досягла верхньої межі"
  namespace           = "ECS/ContainerInsights"
  metric_name         = "DesiredTaskCount"
  dimensions          = local.lab2_service_dims
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = local.scale_max
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_appautoscaling_scheduled_action" "minimum" {
  for_each = var.enable_scheduled_scaling ? {
    day   = { cron = "cron(0 8 * * ? *)", minimum = 2 }
    night = { cron = "cron(0 20 * * ? *)", minimum = local.scale_min }
  } : {}

  name               = "${local.name}-${each.key}-minimum"
  resource_id        = aws_appautoscaling_target.app.resource_id
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  service_namespace  = aws_appautoscaling_target.app.service_namespace
  schedule           = each.value.cron
  timezone           = "Europe/Kyiv"

  scalable_target_action {
    min_capacity = each.value.minimum
    max_capacity = local.scale_max
  }
}

variable "enable_scheduled_scaling" {
  description = "Підняти мінімум ECS до двох завдань на період 08:00–20:00 за Києвом"
  type        = bool
  default     = false
}

variable "tasks_cache_enabled" {
  description = "Увімкнути кеш відповідей на GET /tasks"
  type        = bool
  default     = false
}
