variable "enable_task_queue" {
  description = "Розгорнути чергу SQS, ECS worker та масштабування за чергою"
  type        = bool
  default     = false
}

locals {
  queue_enabled = var.enable_task_queue ? 1 : 0
  worker_max    = 3
}

resource "aws_sqs_queue" "tasks_dlq" {
  count                     = local.queue_enabled
  name                      = "${local.name}-jobs-dlq"
  message_retention_seconds = 345600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "tasks" {
  count                      = local.queue_enabled
  name                       = "${local.name}-jobs"
  message_retention_seconds  = 86400
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.tasks_dlq[0].arn
    maxReceiveCount     = 5
  })
}

resource "aws_iam_role_policy" "queue_send" {
  count = local.queue_enabled
  name  = "send-task-jobs"
  role  = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.tasks[0].arn
    }]
  })
}

resource "aws_iam_role" "queue_worker" {
  count              = local.queue_enabled
  name               = "${local.name}-jobs-worker"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "queue_consume" {
  count = local.queue_enabled
  name  = "consume-task-jobs"
  role  = aws_iam_role.queue_worker[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
      Resource = aws_sqs_queue.tasks[0].arn
    }]
  })
}

resource "aws_ecs_task_definition" "queue_worker" {
  count                    = local.queue_enabled
  family                   = "${local.name}-jobs-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.app_cpu
  memory                   = var.app_memory
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.queue_worker[0].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    for container in jsondecode(aws_ecs_task_definition.app.container_definitions) : merge(container, {
      name         = "worker"
      command      = ["python", "-m", "app.worker"]
      portMappings = []
      secrets      = [for secret in container.secrets : secret if secret.name == "DB_PASSWORD"]
      environment  = concat(container.environment, [{ name = "JWT_SECRET", value = "unused-by-queue-worker" }])
      logConfiguration = merge(container.logConfiguration, {
        options = merge(container.logConfiguration.options, { awslogs-stream-prefix = "worker" })
      })
    })
  ])
}

resource "aws_ecs_service" "queue_worker" {
  count           = local.queue_enabled
  name            = "${local.name}-jobs-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.queue_worker[0].arn
  desired_count   = 0
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = aws_subnet.private_app[*].id
    security_groups = [aws_security_group.app.id]
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_iam_role_policy.queue_consume]
}

resource "aws_appautoscaling_target" "queue_worker" {
  count              = local.queue_enabled
  min_capacity       = 0
  max_capacity       = local.worker_max
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.queue_worker[0].name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "worker_backlog" {
  for_each = var.enable_task_queue ? toset(["grow", "drain"]) : toset([])

  name               = "${local.name}-jobs-${each.key}"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.queue_worker[0].resource_id
  scalable_dimension = aws_appautoscaling_target.queue_worker[0].scalable_dimension
  service_namespace  = "ecs"

  step_scaling_policy_configuration {
    adjustment_type         = each.key == "grow" ? "ChangeInCapacity" : "ExactCapacity"
    cooldown                = each.key == "grow" ? 60 : 120
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = each.key == "grow" ? 1 : 0
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "worker_backlog" {
  count               = local.queue_enabled
  alarm_name          = "${local.name}-jobs-backlog"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.tasks[0].name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_appautoscaling_policy.worker_backlog["grow"].arn]
}

resource "aws_cloudwatch_metric_alarm" "worker_idle" {
  count               = local.queue_enabled
  alarm_name          = "${local.name}-jobs-idle"
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_appautoscaling_policy.worker_backlog["drain"].arn]

  metric_query {
    id          = "idle"
    expression  = "IF(visible + inflight == 0, 1, 0)"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = {
      visible  = "ApproximateNumberOfMessagesVisible"
      inflight = "ApproximateNumberOfMessagesNotVisible"
    }
    content {
      id = metric_query.key
      metric {
        namespace   = "AWS/SQS"
        metric_name = metric_query.value
        dimensions  = { QueueName = aws_sqs_queue.tasks[0].name }
        period      = 60
        stat        = "Maximum"
      }
    }
  }
}
