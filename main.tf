# msi-terraform-cloudwatch-slo
#
# CloudWatch Application Signals SLOs for arbitrary CloudWatch metrics
# (e.g. a Synthetics canary's SuccessPercent), with the standard
# multi-window multi-burn-rate alerting pattern layered on top via plain
# CloudWatch alarms - the SLO resource itself only tracks and reports, it
# doesn't alert on its own.
#
# Uses the awscc (Cloud Control) provider, not the classic aws provider:
# a native aws_service_level_objective resource doesn't exist in the
# classic AWS provider yet (verified empirically by dumping provider
# 5.100.0's full resource schema and finding zero matches for
# "service_level" or "signals" - hashicorp/terraform-provider-aws#39555
# is still an open, unimplemented feature request as of this writing).
# awscc_applicationsignals_service_level_objective wraps the same
# AWS::ApplicationSignals::ServiceLevelObjective CloudFormation type
# Cloud Control already supports, confirmed via a real create/read/
# destroy cycle against the ms-production account before this module was
# written.

resource "awscc_applicationsignals_service_level_objective" "this" {
  for_each = var.slos

  name = each.key
  description = coalesce(
    each.value.description,
    "Availability SLO for ${each.key}: ${each.value.attainment_goal_percent}% of ${each.value.sli_period_seconds}s periods over a rolling ${var.goal_period_days}-day window."
  )

  sli = {
    # Binary per-period check: a period only counts as "good" if the
    # metric hit exactly 100 (e.g. a canary run either fully passed or it
    # didn't - there's no partial credit for a heartbeat check). The real
    # target you're tuning is goal.attainment_goal below.
    comparison_operator = "GreaterThanOrEqualTo"
    metric_threshold    = 100

    sli_metric = {
      # period_seconds/statistic at this level are mutually exclusive
      # with metric_data_queries - confirmed empirically, AWS rejects the
      # create call with "InvalidRequest: All other properties than
      # MetricDataQueries of SliMetric must not be populated" if both are
      # set - so this only ever uses metric_data_queries.
      metric_data_queries = [
        {
          id          = "sli"
          return_data = true
          metric_stat = {
            metric = {
              namespace   = each.value.metric_namespace
              metric_name = each.value.metric_name
              dimensions = [
                for name, value in each.value.dimensions : { name = name, value = value }
              ]
            }
            period = each.value.sli_period_seconds
            stat   = "Average"
          }
        }
      ]
    }
  }

  goal = {
    attainment_goal   = each.value.attainment_goal_percent
    warning_threshold = 50
    interval = {
      rolling_interval = {
        duration      = var.goal_period_days
        duration_unit = "DAY"
      }
    }
  }

  burn_rate_configurations = [
    for tier, cfg in local.burn_rate_tiers : { look_back_window_minutes = cfg.window_minutes }
  ]

  tags = [for k, v in var.tags : { key = k, value = v }]
}

# ---------------------------------------------------------------------------
# Burn-rate alarms - one per SLO per tier (fast/medium/slow), watching the
# AWS/ApplicationSignals BurnRate metric each SLO's burn_rate_configurations
# above causes AWS to publish. A burn rate of exactly 1 means "on pace to
# exhaust the error budget right as the goal period ends"; the thresholds
# in locals.tf trigger well before that, scaled per window so a short,
# sharp outage and a long, slow degradation both get caught without either
# one drowning out the other.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "burn_rate" {
  for_each = local.slo_burn_rate_alarms

  alarm_name          = "slo-${each.value.slo_name}-burn_rate-${each.value.tier}"
  alarm_description   = "${each.value.slo_name} is burning its error budget at ${format("%.1f", each.value.threshold)}x or faster over the last ${each.value.window_minutes} minutes (${each.value.tier}-burn tier)."
  comparison_operator = "GreaterThanThreshold"
  threshold           = each.value.threshold

  namespace   = "AWS/ApplicationSignals"
  metric_name = "BurnRate"
  statistic   = "Maximum"

  # Matches the AWS Application Signals team's own published example
  # (the Amazon Search team's SLO alarming blog): 5-minute granularity,
  # evaluated across 3 periods.
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  dimensions = {
    SloName               = each.value.slo_name
    BurnRateWindowMinutes = tostring(each.value.window_minutes)
  }

  # No burn-rate data usually just means too few underlying SLI periods
  # have landed in the window yet to compute a rate (e.g. right after the
  # SLO is created) - not itself a signal that anything is broken.
  treat_missing_data = "notBreaching"

  alarm_actions = [var.sns_topic_arns[each.value.severity]]
  ok_actions    = [var.sns_topic_arns[each.value.severity]]

  tags = merge(var.tags, { Name = "slo-${each.value.slo_name}-burn_rate-${each.value.tier}" })

  depends_on = [awscc_applicationsignals_service_level_objective.this]
}
