# METADATA
# title: Shared plan traversal helpers
# description: >
#   Collects resources from a Terraform plan including those inside child
#   modules.
#
#   Every policy originally read input.planned_values.root_module.resources
#   directly. That was correct when the configuration was flat, but once
#   terraform/baseline was extracted into a child module its 15 resources
#   became invisible to the gate — three policies were reporting success
#   against resource types they were no longer reading. Recorded as EXC-009.
#
#   walk() descends the whole plan, so root and child modules at any depth are
#   collected uniformly.
#
#   This package contains no deny rules. It is a library.
package compliance.lib

import rego.v1

# Every managed resource in the plan, at any module depth.
resources contains r if {
	walk(input.planned_values, [path, node])
	path[count(path) - 1] == "resources"
	some r in node
}

# The configuration block, likewise. Needed for the unknown-value fallbacks:
# configuration records expressions whether or not they resolve at plan time.
config_resources contains c if {
	walk(input.configuration, [path, node])
	path[count(path) - 1] == "resources"
	some c in node
}

# Match a planned address against a configuration address.
#
# planned_values uses fully-qualified addresses
# ("module.grc_baseline.azurerm_storage_account.evidence_vault") while
# configuration inside a module_call uses the local address
# ("azurerm_storage_account.evidence_vault"). Comparing them with == silently
# fails for every child-module resource, which would reintroduce the CMK false
# positive the fallback exists to prevent.
address_matches(planned, config) if planned == config

address_matches(planned, config) if endswith(planned, sprintf(".%s", [config]))
