variable "enable_idempotency" {
  description = "Створити приватний Redis для Idempotency-Key"
  type        = bool
  default     = false
}

resource "aws_security_group" "idempotency_redis" {
  count       = var.enable_idempotency ? 1 : 0
  name        = "${local.name}-idempotency-redis"
  description = "Allow Redis TLS from ECS tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Redis TLS from the ECS application"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
}

resource "aws_elasticache_serverless_cache" "idempotency" {
  count              = var.enable_idempotency ? 1 : 0
  engine             = "redis"
  name               = "${local.name}-idempotency"
  security_group_ids = [aws_security_group.idempotency_redis[0].id]
  subnet_ids         = aws_subnet.private_app[*].id

  cache_usage_limits {
    data_storage {
      maximum = 2
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = 5000
    }
  }
}

resource "aws_vpc_security_group_egress_rule" "app_to_idempotency" {
  count                        = var.enable_idempotency ? 1 : 0
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.idempotency_redis[0].id
  description                  = "Redis TLS"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}
