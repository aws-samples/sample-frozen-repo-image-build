output "service_name" {
  description = "Name of the ECS mirror service."
  value       = aws_ecs_service.mirror.name
}

output "alb_dns_name" {
  description = "DNS name of the internal ALB."
  value       = aws_lb.mirror.dns_name
}

output "alb_arn" {
  description = "ARN of the internal ALB."
  value       = aws_lb.mirror.arn
}

output "target_group_arn" {
  description = "ARN of the mirror target group."
  value       = aws_lb_target_group.mirror.arn
}

output "task_role_arn" {
  description = "ARN of the cross-account task role."
  value       = aws_iam_role.task.arn
}

output "mirror_url" {
  description = "HTTPS URL of the mirror service."
  value       = "https://${var.mirror_hostname}"
}
