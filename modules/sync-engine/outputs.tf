# Sync Engine module - outputs

output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.sync.name
}

output "cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.sync.arn
}

output "task_family" {
  description = "ECS task definition family."
  value       = aws_ecs_task_definition.sync.family
}

output "task_definition_arn" {
  description = "Family-scoped ARN of the sync ECS task definition (no revision suffix), so the approver Lambda's ecs:RunTask targets the latest active revision and the manifest-updater's EventBridge taskDefinitionArn prefix filter matches every revision. Derived from the revision ARN by stripping the trailing ':<revision>'."
  value       = replace(aws_ecs_task_definition.sync.arn, "/:[0-9]+$/", "")
}

output "task_role_arn" {
  description = "ARN of the task role."
  value       = aws_iam_role.task.arn
}

output "task_exec_role_arn" {
  description = "ARN of the task execution role."
  value       = aws_iam_role.execution.arn
}

output "security_group_id" {
  description = "ID of the sync engine security group."
  value       = aws_security_group.sync.id
}

output "ecr_repository_url" {
  description = "URL of the ECR repository."
  value       = aws_ecr_repository.sync.repository_url
}

output "log_group_name" {
  description = "Name of the CloudWatch log group."
  value       = aws_cloudwatch_log_group.sync.name
}
