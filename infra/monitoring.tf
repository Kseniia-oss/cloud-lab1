resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alb_dim = { LoadBalancer = aws_lb.main.arn_suffix }
  tg_dim  = { LoadBalancer = aws_lb.main.arn_suffix, TargetGroup = aws_lb_target_group.app.arn_suffix }
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${local.name}-5xx-errors"
  alarm_description   = "Застосунок повернув 5 і більше помилок 5xx за 5 хвилин"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = local.tg_dim
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "no_healthy_hosts" {
  alarm_name          = "${local.name}-no-healthy-hosts"
  alarm_description   = "Немає жодного здорового екземпляра за балансувальником"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = local.tg_dim
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = local.name

  dashboard_body = jsonencode({
    widgets = concat([
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "Кількість запитів за хвилину"
          region  = var.aws_region
          stat    = "Sum"
          period  = 60
          view    = "timeSeries"
          metrics = [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix]]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Помилки 5xx"
          region = var.aws_region
          stat   = "Sum"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.main.arn_suffix, "TargetGroup", aws_lb_target_group.app.arn_suffix, { label = "5xx від застосунку" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.main.arn_suffix, { label = "5xx від ALB (502/503)" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Латентність ALB p95 (секунди)"
          region = var.aws_region
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "p95", label = "p95" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "ECS: середнє завантаження CPU (%)"
          region = var.aws_region
          stat   = "Average"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.app.name],
          ]
          annotations = { horizontal = [{ value = local.scale_target_cpu, label = "Ціль масштабування" }] }
          yAxis       = { left = { min = 0, max = 100 } }
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "ECS: бажана і фактична кількість завдань"
          region = var.aws_region
          stat   = "Average"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["ECS/ContainerInsights", "DesiredTaskCount", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.app.name, { label = "Бажана" }],
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.app.name, { label = "Фактична" }],
          ]
          yAxis = { left = { min = 0 } }
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title  = "RDS: CPU (%), ReadIOPS і з'єднання"
          region = var.aws_region
          stat   = "Average"
          period = 60
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.main.identifier],
            ["AWS/RDS", "ReadIOPS", "DBInstanceIdentifier", aws_db_instance.main.identifier, { yAxis = "right" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.main.identifier, { yAxis = "right" }],
          ]
        }
      },
      {
        type = "log", x = 0, y = 18, width = 24, height = 6
        properties = {
          title  = "Останні помилки в логах застосунку"
          region = var.aws_region
          view   = "table"
          query  = "SOURCE '${aws_cloudwatch_log_group.app.name}' | fields @timestamp, @message | filter @message like /ERROR|Traceback| status=5/ | sort @timestamp desc | limit 50"
        }
      },
      ], flatten([for index, queue in aws_sqs_queue.tasks : [
        {
          type = "metric", x = 0, y = 24, width = 12, height = 6
          properties = {
            title  = "SQS: повідомлення в черзі та в обробці"
            region = var.aws_region
            period = 60
            stat   = "Maximum"
            metrics = [
              ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", queue.name, { label = "У черзі" }],
              ["AWS/SQS", "ApproximateNumberOfMessagesNotVisible", "QueueName", queue.name, { label = "В обробці" }],
            ]
          }
        },
        {
          type = "metric", x = 12, y = 24, width = 12, height = 6
          properties = {
            title  = "ECS: кількість обробників черги"
            region = var.aws_region
            period = 60
            stat   = "Average"
            metrics = [
              ["ECS/ContainerInsights", "DesiredTaskCount", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.queue_worker[index].name, { label = "Бажана" }],
              ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", aws_ecs_service.queue_worker[index].name, { label = "Фактична" }],
            ]
          }
        },
    ]]))
  })
}
