output "slo_arns" {
  description = "Map of SLO name -> ARN."
  value       = { for k, v in awscc_applicationsignals_service_level_objective.this : k => v.id }
}

output "burn_rate_thresholds" {
  description = "Map of tier (fast/medium/slow) -> the numeric BurnRate alarm threshold actually used, for reference."
  value       = local.burn_rate_thresholds
}
