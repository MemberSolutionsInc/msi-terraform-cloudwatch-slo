locals {
  # Burn-rate alert tiers, expressed as "N bad SLI periods within a
  # look-back window" rather than as a fraction of the error budget.
  #
  # Why counts and not the Google SRE Workbook budget fractions (1h/2%,
  # 6h/5%, 3d/10%) this module used up to v0.2.0: at a 99.9% goal over
  # 5-minute SLI periods and a 7-day window, the WHOLE error budget is
  # ~2 bad periods, so a single failed canary run is already ~50% of it.
  # The BurnRate metric is quantised in whole bad periods - one bad
  # period reads 83.3 in the 1h window, 13.9 in 6h and 1.16 in 3d - so
  # every budget-fraction threshold (3.36 / 1.4 / 0.23) sat BELOW one
  # failure, and every transient single-run blip fired all three tiers
  # (critical for 50 minutes, info for 3 days). Stating the thresholds
  # as counts makes the quantisation explicit and lets the tiers tell a
  # blip apart from an outage.
  #
  # Each tier fires when ANY of its clauses holds; a clause holds when
  # ALL of its terms hold. Pairing a long window with a short one is the
  # SRE Workbook's multi-window pattern: the long window proves the
  # problem is real, the short one proves it is still happening, so the
  # alarm resets soon after recovery instead of waiting for the long
  # window to drain.
  #
  # hold_periods is the alarm's evaluation_periods with
  # datapoints_to_alarm = 1: once in ALARM it only returns to OK after
  # this many consecutive 5-minute evaluations without a breach. That
  # hysteresis is what stops an intermittent failure pattern from
  # flapping the alarm OK <-> ALARM.
  #
  # Tuned by replaying ms-production's 12 canaries (2026-09-02 ..
  # 2026-09-28) plus synthetic periodic/random intermittent failure
  # patterns: zero alarms from the 10 isolated single-run blips in that
  # data, and the 2026-09-04 mp-billing/mp-member/mp-user outage still
  # paged within ~10 minutes (earlier than v0.2.0's 15).
  alert_tiers = {
    fast = {
      severity     = "critical"
      hold_periods = 12 # 60 min before OK - no re-paging during an intermittent outage
      summary      = "hard down: 2 consecutive failed periods, or >=4 failed periods in the last hour with one in the last 15 minutes"
      clauses = [
        [{ window_minutes = 10, min_bad = 2 }],
        [{ window_minutes = 60, min_bad = 4 }, { window_minutes = 15, min_bad = 1 }],
      ]
    }
    medium = {
      severity     = "warning"
      hold_periods = 2
      summary      = "sustained degradation: >=3 failed periods in the last 6 hours with one in the last 2 hours"
      clauses = [
        [{ window_minutes = 360, min_bad = 3 }, { window_minutes = 120, min_bad = 1 }],
      ]
    }
    slow = {
      severity     = "info"
      hold_periods = 1
      summary      = "slow erosion: >=3 failed periods in the last 3 days with one in the last 6 hours"
      clauses = [
        [{ window_minutes = 4320, min_bad = 3 }, { window_minutes = 360, min_bad = 1 }],
      ]
    }
  }

  # Every look-back window any tier references - each SLO publishes a
  # BurnRate series per window (burn_rate_configurations in main.tf).
  # Zero-padded before sort() because sort() orders lexically.
  burn_rate_windows = [
    for w in sort(distinct(flatten([
      for tier in values(local.alert_tiers) : [
        for clause in tier.clauses : [for term in clause : format("%05d", term.window_minutes)]
      ]
    ]))) : tonumber(w)
  ]

  # Per SLO x tier: the metric-math expression and the windows it reads.
  # A term's BurnRate threshold is the value (min_bad - 0.5) bad periods
  # would produce - halfway between min_bad - 1 and min_bad, so float
  # rounding in the published metric can't tip it either way:
  #
  #   burn_rate = (bad_periods / periods_in_window) / (1 - goal)
  #
  # e.g. 2 bad in a 10-minute window of 5-minute periods at 99.9%:
  # threshold = (1.5 / 2) / 0.001 = 750 (one bad reads 500, two 1000).
  slo_burn_rate_alarms = merge([
    for slo_name, slo in var.slos : {
      for tier, cfg in local.alert_tiers : "${slo_name}-${tier}" => {
        slo_name     = slo_name
        tier         = tier
        severity     = cfg.severity
        hold_periods = cfg.hold_periods
        summary      = cfg.summary
        windows      = distinct(flatten([for clause in cfg.clauses : [for term in clause : term.window_minutes]]))
        expression = join(" OR ", [
          for clause in cfg.clauses : "(${join(" AND ", [
            for term in clause : format(
              "FILL(w%d, 0) > %.4f",
              term.window_minutes,
              (term.min_bad - 0.5) / (term.window_minutes * 60 / slo.sli_period_seconds) / (1 - slo.attainment_goal_percent / 100)
            )
          ])})"
        ])
      }
    }
  ]...)
}
