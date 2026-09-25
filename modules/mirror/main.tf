##############################################################################
# Mirror (read path): WORKLOAD air-gapped account (us-west-2). Fargate + internal
# ALB reading a frozen S3 bucket in the DISTRIBUTION account via cross-account role.
##############################################################################

locals {
  container_name = "mirror"
  container_port = 8080
  log_group_name = "/ecs/${var.task_family}"

  # ELBv2 names cap at 32 chars; task_family+"-alb" can exceed it. Collapse the
  # repeated segment to a short base, then cap defensively.
  lb_base_name = substr(replace(var.task_family, "-frozen-repo-", "-"), 0, 28)
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

##############################################################################
# (1) ECS cluster (Fargate) + Container Insights + log group
##############################################################################

resource "aws_ecs_cluster" "this" {
  name = "${var.task_family}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_cloudwatch_log_group" "mirror" {
  #checkov:skip=CKV_AWS_158:log group CMK supplied per-deployment via var.log_kms_key_arn
  name              = local.log_group_name
  retention_in_days = 365
  kms_key_id        = var.log_kms_key_arn
  tags              = var.tags
}

##############################################################################
# (2) ECR repository: immutable tags, scan on push, keep last 5 images
##############################################################################

resource "aws_ecr_repository" "mirror" {
  name                 = var.mirror_ecr_repo_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.ecr_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = var.ecr_kms_key_arn != null ? "KMS" : "AES256"
    kms_key         = var.ecr_kms_key_arn
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "mirror" {
  repository = aws_ecr_repository.mirror.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

##############################################################################
# (5) IAM: cross-account task role + task execution role
##############################################################################

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# Task role: reads from the frozen bucket in the distribution account and
# decrypts with that account's KMS key.
resource "aws_iam_role" "task" {
  name               = "${var.task_family}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "task" {
  statement {
    sid    = "FrozenBucketRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
    ]
    resources = [
      var.frozen_bucket_arn,
      "${var.frozen_bucket_arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [var.frozen_bucket_account_id]
    }
  }

  statement {
    sid    = "FrozenBucketKmsDecrypt"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [var.frozen_bucket_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${var.task_family}-task-policy"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# Execution role: pulls the image from ECR and writes logs.
resource "aws_iam_role" "execution" {
  name               = "${var.task_family}-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

##############################################################################
# (7) Security groups: internal ALB SG + task SG
##############################################################################

resource "aws_security_group" "alb" {
  name        = "${var.task_family}-alb-sg"
  description = "Internal ALB for the mirror service"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from allowed CIDRs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.ingress_cidrs
  }

  # Egress is scoped to the mirror task SG on the container port only
  # (see aws_security_group_rule.alb_to_task below). No blanket egress.

  tags = var.tags
}

# ALB egress to the mirror tasks only, on the container port over TCP.
# Declared as a separate rule to avoid a cycle between the two SGs.
resource "aws_security_group_rule" "alb_to_task" {
  type                     = "egress"
  description              = "Container port to mirror tasks only"
  from_port                = local.container_port
  to_port                  = local.container_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.task.id
}

resource "aws_security_group" "task" {
  name        = "${var.task_family}-task-sg"
  description = "Mirror Fargate tasks"
  vpc_id      = var.vpc_id

  # No open egress: mirror only reaches AWS APIs. S3 data plane via gateway
  # endpoint prefix list; KMS/ECR/Logs via interface endpoints (SG-to-SG when created here, VPC-CIDR-scoped otherwise).
  egress {
    description     = "HTTPS to S3 via the gateway endpoint prefix list"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.s3.id]
  }

  dynamic "egress" {
    for_each = var.create_vpc_endpoints ? [1] : []
    content {
      description     = "HTTPS to module-created interface VPC endpoints (KMS, ECR, Logs)"
      from_port       = 443
      to_port         = 443
      protocol        = "tcp"
      security_groups = [aws_security_group.vpce[0].id]
    }
  }

  dynamic "egress" {
    for_each = var.create_vpc_endpoints ? [] : [1]
    content {
      description = "HTTPS to pre-existing interface VPC endpoints in this VPC"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [data.aws_vpc.this.cidr_block]
    }
  }

  tags = var.tags
}

# Container port ingress from the ALB SG only (separate resource to avoid a
# cycle between the two security groups).
resource "aws_security_group_rule" "task_from_alb" {
  type                     = "ingress"
  description              = "Container port from the internal ALB only"
  from_port                = local.container_port
  to_port                  = local.container_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.task.id
  source_security_group_id = aws_security_group.alb.id
}

##############################################################################
# (7b) VPC endpoints: the ONLY egress paths the mirror task has (S3 regional API
# reached by IAM, not a private link). Toggle create_vpc_endpoints=false when the
# VPC already provides them, since AWS permits only ONE private-DNS interface
# endpoint per service per VPC and a duplicate hard-fails at apply.
##############################################################################

# The AWS-managed S3 prefix list exists per region independent of any
# endpoint, so the task SG egress can always reference it.
data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.${data.aws_region.current.region}.s3"
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

data "aws_route_tables" "vpc" {
  vpc_id = var.vpc_id
}

resource "aws_vpc_endpoint" "s3" {
  count = var.create_vpc_endpoints ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.vpc.ids
  tags              = var.tags
}

# SG for the interface endpoint ENIs: accepts 443 ONLY from the mirror task SG.
resource "aws_security_group" "vpce" {
  count = var.create_vpc_endpoints ? 1 : 0

  name        = "${var.task_family}-vpce-sg"
  description = "Interface VPC endpoints for the mirror (KMS, ECR, Logs)"
  vpc_id      = var.vpc_id

  tags = var.tags
}

resource "aws_security_group_rule" "vpce_from_task" {
  count = var.create_vpc_endpoints ? 1 : 0

  type                     = "ingress"
  description              = "HTTPS from the mirror task SG only"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vpce[0].id
  source_security_group_id = aws_security_group.task.id
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.create_vpc_endpoints ? toset(["kms", "ecr.api", "ecr.dkr", "logs"]) : toset([])

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.vpce[0].id]
  private_dns_enabled = true
  tags                = var.tags
}

##############################################################################
# (6) Internal ALB + HTTPS listener + target group
##############################################################################

resource "aws_lb" "mirror" {
  #checkov:skip=CKV_AWS_91:ALB access-log bucket supplied per-deployment via var.access_logs_bucket
  name                       = "${local.lb_base_name}-alb"
  internal                   = true
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.subnet_ids
  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true

  dynamic "access_logs" {
    for_each = var.access_logs_bucket != null ? [1] : []
    content {
      bucket  = var.access_logs_bucket
      enabled = true
    }
  }

  tags = var.tags
}

resource "aws_lb_target_group" "mirror" {
  name        = "${local.lb_base_name}-tg"
  port        = local.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.mirror.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mirror.arn
  }

  tags = var.tags
}

##############################################################################
# (3) ECS task definition
##############################################################################

resource "aws_ecs_task_definition" "mirror" {
  family                   = var.task_family
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = "${aws_ecr_repository.mirror.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = local.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "S3_BUCKET", value = var.s3_bucket },
        { name = "S3_REGION", value = var.s3_region },
        { name = "GOMEMLIMIT", value = "1800MiB" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.mirror.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = local.container_name
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:9090/ || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
    }
  ])

  tags = var.tags
}

##############################################################################
# (4) ECS service
##############################################################################

resource "aws_ecs_service" "mirror" {
  name                   = "${var.task_family}-svc"
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.mirror.arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mirror.arn
    container_name   = local.container_name
    container_port   = local.container_port
  }

  depends_on = [aws_lb_listener.https]

  tags = var.tags
}

##############################################################################
# Optional Route53 alias record in the private zone -> ALB. Alias (not CNAME) so it
# works at the zone apex where CNAMEs are forbidden, resolving direct at no per-query cost.
##############################################################################

resource "aws_route53_record" "mirror" {
  count   = var.create_dns_record ? 1 : 0
  zone_id = var.private_zone_id
  name    = var.mirror_hostname
  type    = "A"

  alias {
    name                   = aws_lb.mirror.dns_name
    zone_id                = aws_lb.mirror.zone_id
    evaluate_target_health = true
  }
}
