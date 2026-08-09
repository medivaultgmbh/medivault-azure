###############################################################################
# FinOps - cost guardrail
#
# IMPORTANT, AND THE POINT OF THE EXERCISE:
#
# An Azure budget is a NOTIFICATION mechanism, not a spending cap. Crossing the
# threshold sends an alert; it does not stop, throttle, or delete anything. Pay-
# as-you-go subscriptions have no hard spending limit - only the legacy free
# trial and some MSDN/Visual Studio offers do, and those suspend the entire
# subscription rather than shedding load gracefully.
#
# So the EUR/USD 20 ceiling below is a detective control, not a preventive one.
# Treating it as preventive is one of the most common and most expensive FinOps
# mistakes: teams set a budget, assume they are protected, and discover
# otherwise on the invoice.
#
# Preventive controls actually in force in this deployment:
#   - Log Analytics daily_quota_gb = 1        (caps the largest variable cost)
#   - No Cosmos DB, Functions, APIM, or       (~EUR 235/mo of the ~EUR 240
#     private endpoints deployed               reference architecture omitted)
#   - LRS instead of GRS on evidence storage
#   - Standard instead of Premium Key Vault
#
# The architecture is cheap by construction. The budget is the backstop that
# catches what design decisions did not anticipate.
#
# See docs/FINOPS.md for the enforcement pattern (budget webhook -> Automation
# runbook -> teardown) and why it is documented rather than deployed here.
###############################################################################

locals {
  # Azure requires a subscription budget to start on the first day of a month.
  # Defaults to the current month; override to keep the plan stable over time.
  budget_start = coalesce(
    var.budget_start_date,
    formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  )

  budget_end = formatdate("YYYY-MM-01'T'00:00:00Z", timeadd(local.budget_start, "8760h"))
}

###############################################################################
# Action group - the delivery channel for budget alerts.
#
# Separated from the budget itself so that adding an enforcement path later
# (webhook, Logic App, Automation runbook) is a change to this resource only.
###############################################################################

resource "azurerm_monitor_action_group" "cost_alerts" {
  name                = "${var.name_prefix}-cost-alerts"
  resource_group_name = azurerm_resource_group.demo.name
  short_name          = "cost" # <= 12 chars, shown in SMS/push notifications

  dynamic "email_receiver" {
    for_each = var.budget_alert_emails
    content {
      name                    = "cost-owner-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  tags = local.tags
}

###############################################################################
# Subscription budget
#
# Scoped to the whole subscription rather than the demo resource group, so it
# also captures the Terraform state storage account and anything created
# outside this configuration. A resource-group budget would miss exactly the
# spend most likely to be forgotten.
#
# Four notifications, deliberately layered:
#   50%  actual      - early signal, informational
#   80%  actual      - act now, still time to intervene
#  100%  actual      - ceiling breached
#   90%  forecasted  - Azure projects the month will breach; usually the most
#                      useful of the four, because it fires BEFORE the money is
#                      spent rather than after
###############################################################################

resource "azurerm_consumption_budget_subscription" "demo_ceiling" {
  name            = "${var.name_prefix}-demo-ceiling"
  subscription_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"

  amount     = var.budget_amount
  time_grain = "Monthly"

  time_period {
    start_date = local.budget_start
    end_date   = local.budget_end
  }

  # 50% - informational
  notification {
    enabled        = true
    threshold      = 50
    threshold_type = "Actual"
    operator       = "GreaterThanOrEqualTo"

    contact_emails = var.budget_alert_emails
    contact_groups = [azurerm_monitor_action_group.cost_alerts.id]
  }

  # 80% - intervene
  notification {
    enabled        = true
    threshold      = 80
    threshold_type = "Actual"
    operator       = "GreaterThanOrEqualTo"

    contact_emails = var.budget_alert_emails
    contact_groups = [azurerm_monitor_action_group.cost_alerts.id]
  }

  # 100% - ceiling breached
  notification {
    enabled        = true
    threshold      = 100
    threshold_type = "Actual"
    operator       = "GreaterThanOrEqualTo"

    contact_emails = var.budget_alert_emails
    contact_groups = [azurerm_monitor_action_group.cost_alerts.id]
  }

  # 90% forecasted - the predictive one. Fires on Azure's projection of
  # month-end spend, so it warns before the spend actually happens.
  notification {
    enabled        = true
    threshold      = 90
    threshold_type = "Forecasted"
    operator       = "GreaterThanOrEqualTo"

    contact_emails = var.budget_alert_emails
    contact_groups = [azurerm_monitor_action_group.cost_alerts.id]
  }

  lifecycle {
    # local.budget_start derives from timestamp() when not pinned, which would
    # otherwise show a diff on every plan.
    ignore_changes = [time_period]
  }
}
