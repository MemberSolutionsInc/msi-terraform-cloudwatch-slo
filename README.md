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
- Three `aws_cloudwatch_metric_alarm` resources per SLO, watching the
  `AWS/ApplicationSignals` `BurnRate` metric each SLO publishes, at three
  look-back windows: 1h/critical, 6h/warning, 3d/info. The SLO resource
  itself only tracks and reports - it doesn't alert on its own, which is
  what these alarms are for.

## Usage

```hcl
module "canary_slos" {
  source = "git::https://github.com/MemberSolutionsInc/msi-terraform-cloudwatch-slo.git?ref=v0.1.0"

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

## The burn-rate math

`goal_period_days` (default 30) is the rolling window the SLO's
`attainment_goal` is measured against. The three alarm thresholds are
*derived* from it, not hardcoded, so changing `goal_period_days` recalculates
them correctly:

```
burn_rate = consumption_fraction * goal_period_days / window_days
```

| Tier   | Window | Consumption | Threshold @ 30-day goal | Severity |
|--------|--------|-------------|--------------------------|----------|
| fast   | 1h     | 2%          | 14.4x                    | critical |
| medium | 6h     | 5%          | 6x                       | warning  |
| slow   | 3d     | 10%         | 1x                       | info     |

A burn rate of 1x means "consuming the error budget at exactly the rate
that exhausts it right as the goal period ends." The fast tier catches a
sharp outage fast (2% of a 30-day budget in 1 hour is a real incident); the
slow tier catches a gradual decline that never looks urgent on its own but
adds up.

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
- **Low-volume metrics.** AWS's own guidance on burn-rate alerting warns
  that burn rate gets noisy with too few underlying data points in the
  look-back window. A canary running every 5 minutes only has ~12
  datapoints in the fast (1h) window - fine for a fixed-cadence heartbeat,
  but worth knowing if you point this at a metric with genuinely variable
  volume (this module doesn't implement a low-traffic guard alarm).
