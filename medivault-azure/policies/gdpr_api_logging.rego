# METADATA
# title: GDPR Art. 32 + NIS2 Art. 21 — API Management must have access logging configured
# description: >
#   All azurerm_api_management instances must have a corresponding
#   azurerm_monitor_diagnostic_setting with the GatewayLogs category enabled.
#   API gateway logs are the primary evidence source for detecting unauthorised
#   access to healthcare partner data and for reconstructing the sequence of
#   events during a GDPR Art. 33 / NIS2 Art. 23 incident notification.
# custom:
#   framework: gdpr
#   controls:
#     - "Art.32 — logging as a technical measure"
#     - "NIS2 Art.21(2)(b) — incident handling"
#     - "NIS2 Art.23 — reporting obligations: 24h early warning evidence"
#   severity: medium
#   aws_equivalent: compliance.hipaa.api_logging
#   remediation: >
#     Add an azurerm_monitor_diagnostic_setting targeting the APIM resource ID
#     with enabled_log { category = "GatewayLogs" } and a log_analytics_workspace_id.
package compliance.gdpr.api_logging

import rego.v1

deny contains msg if {
	some apim in input.planned_values.root_module.resources
	apim.type == "azurerm_api_management"
	not has_gateway_logs_diagnostic(apim.values.id)
	msg := sprintf(
		"[GDPR Art.32 / NIS2 Art.21] %s: API Management must have a Diagnostic Setting with GatewayLogs enabled.",
		[apim.address],
	)
}

has_gateway_logs_diagnostic(apim_id) if {
	some diag in input.planned_values.root_module.resources
	diag.type == "azurerm_monitor_diagnostic_setting"
	diag.values.target_resource_id == apim_id
	some log in diag.values.enabled_log
	log.category == "GatewayLogs"
}

# Also check via configuration references (handles planned_values ID being unknown at plan time)
has_gateway_logs_diagnostic(_) if {
	some diag in input.configuration.root_module.resources
	diag.type == "azurerm_monitor_diagnostic_setting"
	some ref in diag.expressions.target_resource_id.references
	contains(ref, "azurerm_api_management")
	some log_expr in diag.expressions.enabled_log
	log_expr.category.constant_value == "GatewayLogs"
}
