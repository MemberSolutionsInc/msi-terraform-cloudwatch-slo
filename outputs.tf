output "slo_arns" {
  description = "Map of SLO name -> ARN."
  value       = { for k, v in awscc_applicationsignals_service_level_objective.this : k => v.id }
}

output "burn_rate_alarm_expressions" {
  description = "Map of \"<slo>-<tier>\" -> the metric-math expression its burn-rate alarm evaluates, for reference."
  value       = { for k, v in local.slo_burn_rate_alarms : k => v.expression }
}
