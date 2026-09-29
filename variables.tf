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

  # The alarm tiers in locals.tf are tuned in 5-minute periods - e.g. the
  # fast tier's "2 bad in a 10-minute window" only means "2 consecutive
  # failures" at 300s. Revisit those tiers before relaxing this.
  validation {
    condition     = alltrue([for s in values(var.slos) : s.sli_period_seconds == 300])
    error_message = "sli_period_seconds must be 300: the burn-rate alarm tiers in locals.tf are tuned for 5-minute SLI periods."
  }
}

variable "goal_period_days" {
  description = <<-EOT
    Rolling SLO evaluation window, in days, applied to every SLO in this
    module invocation. Since v0.3.0 the burn-rate alarm tiers in
    locals.tf are stated as "N failed SLI periods within a look-back
    window" - converted to BurnRate thresholds per SLO from its
    attainment_goal_percent and sli_period_seconds - so this only sets
    the SLO's attainment window, not the alarm thresholds.
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
