variable "slos" {
  description = <<-EOT
    Map of SLO name -> config. Each becomes one period-based CloudWatch
    Application Signals SLO plus three burn-rate alarms (fast/medium/slow
    - see locals.tf).

    The per-period SLI check is fixed in main.tf at "metric >= 100" and
    isn't exposed here, because this module is built for binary
    pass/fail metrics like a Synthetics canary's SuccessPercent - each
    period either fully succeeded or it didn't, so there's no meaningful
    partial threshold. The real target you're tuning is
    attainment_goal_percent below (what fraction of those periods must
    be good over the rolling window). If you need a non-binary SLI (e.g.
    a latency percentile), this module isn't the right fit as-is.
  EOT
  type = map(object({
    metric_namespace        = string
    metric_name             = string
    dimensions              = map(string)
    attainment_goal_percent = optional(number, 99.9)
    sli_period_seconds      = optional(number, 300)
    description             = optional(string)
  }))
}

variable "goal_period_days" {
  description = <<-EOT
    Rolling SLO evaluation window, in days, applied to every SLO in this
    module invocation. Defaults to 7, not the 30 days the classic Google
    SRE Workbook / AWS Application Signals reference examples use -
    MemberSolutions' own convention for these SLOs. Burn-rate alarm
    thresholds in locals.tf are DERIVED from this value (burn_rate =
    consumption_fraction * goal_period_days / window_days), so changing
    it recalculates the alarm thresholds correctly instead of leaving
    them stale - there's no separate threshold input to keep in sync by
    hand.
  EOT
  type        = number
  default     = 7
}

variable "sns_topic_arns" {
  description = "Severity-routed SNS topic ARNs. Fast-burn alarms route to critical, medium-burn to warning, slow-burn to info."
  type = object({
    critical = string
    warning  = string
    info     = string
  })
}

variable "tags" {
  description = "Common tags applied to every SLO and alarm created by this module."
  type        = map(string)
  default     = {}
}
