# msi-terraform-cloudwatch-slo

Service Level Objectives (SLOs) for arbitrary CloudWatch metrics - built for
CloudWatch Synthetics canaries' `SuccessPercent` metric, but works with any
metric that's meaningfully binary per period.

## Purpose

Gives a canary (or any CloudWatch metric) a real error-budget-based SLO -
"99.9% of periods over a rolling 30 days" - instead of just a flat
threshold alarm, plus the industry-standard **multi-window multi-burn-rate**
alerting pattern (Google SRE Workbook, "Alerting on SLOs" - the same
reference AWS's own Application Signals team cites) so a short sharp outage
and a slow creeping degradation both get caught, at different severities,
without either one drowning out the other.

Uses the **`awscc`** (Cloud Control) provider, not the classic `aws`
provider: a native `aws_service_level_objective` resource doesn't exist in
the classic AWS provider yet (verified empirically against provider 5.100.0's
full schema - [hashicorp/terraform-provider-aws#39555](https://github.com/hashicorp/terraform-provider-aws/issues/39555)
is still an open, unimplemented feature request as of when this module was
written). `awscc_applicationsignals_service_level_objective` wraps the same
`AWS::ApplicationSignals::ServiceLevelObjective` CloudFormation type Cloud
Control already supports.

This module creates:
- One `awscc_applicationsignals_service_level_objective` per entry in `slos`
  - a period-based SLO with a binary per-period SLI (`metric >= 100`).
- Three `aws_cloudwatch_metric_alarm` resources per SLO (fast/critical,
  medium/warning, slow/info) - metric-math alarms that combine a long and
  a short look-back window of the `AWS/ApplicationSignals` `BurnRate`
  metric each SLO publishes. The SLO resource itself only tracks and
  reports - it doesn't alert on its own, which is what these alarms are
  for.

## Usage

```hcl
module "canary_slos" {
  source = "git::https://github.com/MemberSolutionsInc/msi-terraform-cloudwatch-slo.git?ref=v0.3.0"

  slos = {
    api-heartbeat = {
      metric_namespace = "CloudWatchSynthetics"
      metric_name       = "SuccessPercent"
      dimensions        = { CanaryName = "api-heartbeat" }
      # attainment_goal_percent defaults to 99.9
    }
  }

  sns_topic_arns = {
    critical = "arn:aws:sns:us-east-1:123456789012:aws-cw-critical"
    warning  = "arn:aws:sns:us-east-1:123456789012:aws-cw-warning"
    info     = "arn:aws:sns:us-east-1:123456789012:aws-cw-info"
  }

  tags = { owner = "platform" }
}
```

## The alarm tiers

`goal_period_days` (default 7) is the rolling window the SLO's
`attainment_goal` is measured against. The alarm tiers are stated as
**failed SLI periods within a look-back window**, and converted per SLO to
`BurnRate` thresholds:

```
burn_rate = (bad_periods / periods_in_window) / (1 - goal)
```

| Tier   | Fires when                                                                 | Holds before OK | Severity |
|--------|----------------------------------------------------------------------------|-----------------|----------|
| fast   | 2 consecutive failed periods, **or** >=4 failed in 1h with one in the last 15m | 60 min          | critical |
| medium | >=3 failed in 6h with one in the last 2h                                   | 10 min          | warning  |
| slow   | >=3 failed in 3d with one in the last 6h                                   | 5 min           | info     |

A single isolated failed run fires nothing.

### Why counts, not budget fractions (changed in v0.3.0)

Up to v0.2.0 the thresholds were the Google SRE Workbook budget fractions
(1h/2%, 6h/5%, 3d/10%). That table assumes lots of events per window. A
canary gives one 5-minute sample at a time, and at 99.9% over 7 days the
whole error budget is ~2 bad periods. `BurnRate` moves in whole bad
periods: one bad period reads 83.3 in the 1h window, 13.9 in 6h and 1.16 in
3d, while the thresholds were 3.36 / 1.4 / 0.23. So a single transient
failure paged critical for 50 minutes, warning for ~6 hours and kept info
in ALARM for 3 days. In ms-production that was every alarm raised by
`mm-api` in September 2026 (6 blips, 0 real incidents).

Each tier pairs a long window (the problem is real) with a short window
(it is still happening), following the Workbook's multi-window pattern, so
alarms reset soon after recovery. `hold_periods` (evaluation periods with
`datapoints_to_alarm = 1`) adds hysteresis so an intermittent failure
pattern stays in ALARM instead of flapping. The tiers were tuned by
replaying 27 days of ms-production canary data plus synthetic
periodic/random failure patterns. The real 2026-09-04 outage (16-21
consecutive failures) still paged about 10 minutes after onset.

## Fit and limits

- **Binary SLI only.** The per-period check is fixed at `metric >= 100` in
  `main.tf`, not exposed as a variable, because this module was built for
  metrics like a canary's `SuccessPercent` where each period is either
  fully successful or it isn't - there's no meaningful partial credit. If
  you need a non-binary SLI (e.g. a latency percentile with a real
  threshold), this module isn't the right fit as-is; that would need a
  different `metric_threshold`/`comparison_operator` exposed per SLO.
- **One `goal_period_days` per module invocation**, applied to every SLO
  in it, since the burn-rate thresholds are derived from it account-wide.
  Give SLOs that need a different rolling window their own module
  invocation.
- **5-minute SLI periods only.** `sli_period_seconds` is validated to 300,
  because the tiers are tuned in 5-minute periods (e.g. "2 bad in a
  10-minute window" means "2 consecutive failures" only at 300s).
- **Low-volume metrics.** AWS's own guidance on burn-rate alerting warns
  that burn rate gets noisy with too few underlying data points in the
  look-back window. A canary running every 5 minutes only has ~12
  datapoints in the fast (1h) window - fine for a fixed-cadence heartbeat,
  but worth knowing if you point this at a metric with genuinely variable
  volume (this module doesn't implement a low-traffic guard alarm).
