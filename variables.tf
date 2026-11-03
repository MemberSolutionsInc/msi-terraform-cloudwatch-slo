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

variable "tier_hold_periods" {
  description = <<-EOT
    Optional per-tier override of how many consecutive clean 5-minute
    evaluations a burn-rate alarm needs before it returns to OK (the
    alarm's evaluation_periods, with datapoints_to_alarm = 1). Unset
    tiers use the defaults in locals.tf (fast 12, medium 6, slow 12).
    This only changes how long an alarm stays in ALARM after the
    condition clears; it never delays detection. Each value must be
    1-288 (CloudWatch caps evaluation_periods x period at 24 hours).
  EOT
  type = object({
    fast   = optional(number)
    medium = optional(number)
    slow   = optional(number)
  })
  default = {}

  validation {
    condition = alltrue([
      for v in values(var.tier_hold_periods) : v == null ? true : (v >= 1 && v <= 288 && v == floor(v))
    ])
    error_message = "tier_hold_periods values must be whole numbers between 1 and 288."
  }
}

variable "notify_on_ok_severities" {
  description = <<-EOT
    Severities whose burn-rate alarms also notify when they return to OK.
    Recovery messages matter for critical and warning (they close the
    loop on a page); for the info tier they are pure chat noise, so it is
    excluded by default. Add "info" to restore v0.3.0 behaviour.
  EOT
  type        = list(string)
  default     = ["critical", "warning"]

  validation {
    condition     = alltrue([for s in var.notify_on_ok_severities : contains(["critical", "warning", "info"], s)])
    error_message = "notify_on_ok_severities may only contain critical, warning and info."
  }
}

variable "runbook_url" {
  description = "Optional runbook/dashboard URL appended to every burn-rate alarm description so the notification links straight to triage steps."
  type        = string
  default     = null
}
