locals {
  # The classic multi-window multi-burn-rate table (Google SRE Workbook,
  # "Alerting on SLOs") - the same reference AWS's own Application
  # Signals team cites for their published example (the Amazon Search
  # team's "Alarming on SLOs ... with CloudWatch Application Signals"
  # blog: 1h/2%, 6h/5%, 3d/10%). consumption_fraction is "what fraction
  # of the total error budget is acceptable to burn within this window
  # before alerting" - burn_rate_thresholds below converts that into the
  # actual BurnRate metric value CloudWatch publishes.
  burn_rate_tiers = {
    fast = {
      window_minutes       = 60   # 1h - a sharp, short outage
      consumption_fraction = 0.02 # 2%
      severity             = "critical"
    }
    medium = {
      window_minutes       = 360  # 6h - a sustained partial degradation
      consumption_fraction = 0.05 # 5%
      severity             = "warning"
    }
    slow = {
      window_minutes       = 4320 # 3d - a slow, creeping decline
      consumption_fraction = 0.10 # 10%
      severity             = "info"
    }
  }

  # burn_rate = consumption_fraction / (window_days / goal_period_days)
  #           = consumption_fraction * goal_period_days / window_days
  # e.g. the fast tier at the default 30-day goal:
  # 0.02 * 30 / (60/1440) = 14.4 - matches the Google SRE Workbook's
  # canonical "page immediately" burn-rate value for a 1-hour window.
  burn_rate_thresholds = {
    for tier, cfg in local.burn_rate_tiers :
    tier => cfg.consumption_fraction * var.goal_period_days / (cfg.window_minutes / 1440)
  }

  # Flatten slo x burn-rate-tier into one map, keyed by "<slo>-<tier>",
  # for the single burn_rate alarm resource in main.tf.
  slo_burn_rate_alarms = merge([
    for slo_name, slo in var.slos : {
      for tier, cfg in local.burn_rate_tiers : "${slo_name}-${tier}" => {
        slo_name       = slo_name
        tier           = tier
        window_minutes = cfg.window_minutes
        threshold      = local.burn_rate_thresholds[tier]
        severity       = cfg.severity
      }
    }
  ]...)
}
