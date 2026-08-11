# METADATA
# title: GDPR Chapter V — personal data must remain in the EU/EEA
# description: >
#   Every resource that stores or processes MediVault personal data must be
#   deployed to an EU or EEA region. GDPR Chapter V (Art. 44-49) restricts
#   transfers of personal data to third countries; since Schrems II (CJEU
#   C-311/18) invalidated Privacy Shield, transfers to the United States
#   require case-by-case assessment that MediVault has not performed.
#
#   This rule was added after West Europe refused new resources for the demo
#   subscription and the deployment moved to Germany West Central. That move
#   was safe, but nothing in the gate would have objected had it gone to East
#   US instead: EU residency was asserted in Parts 1 and 2 and enforced
#   nowhere. See EXC-008.
# custom:
#   framework: gdpr
#   controls:
#     - "Art.44 — general principle for transfers"
#     - "Art.45 — transfers on the basis of an adequacy decision"
#     - "Art.46 — transfers subject to appropriate safeguards"
#   severity: critical
#   aws_equivalent: SCP restricting non-eu-* regions
#   remediation: >
#     Deploy to an EU/EEA region. Widening the fallback list is acceptable;
#     leaving the jurisdiction is not.
package compliance.gdpr.eu_data_residency

import data.compliance.lib
import rego.v1

# EU/EEA regions only. Deliberately excludes uksouth and ukwest: post-Brexit
# the UK holds an adequacy decision, but it is time-limited and renewable
# rather than permanent, so it is not treated as equivalent here.
eu_regions := {
	"westeurope", # Netherlands
	"northeurope", # Ireland
	"germanywestcentral", # Germany
	"germanynorth",
	"francecentral",
	"francesouth",
	"swedencentral",
	"norwayeast",
	"norwaywest",
	"switzerlandnorth", # adequacy decision in force
	"switzerlandwest",
	"polandcentral",
	"italynorth",
	"spaincentral",
}

# Pseudo-locations. Action groups and activity log alerts are control-plane
# metadata objects that Azure requires to be declared as "Global"; they hold no
# personal data and have no region to assess. Two of these exist in
# terraform/baseline, and without this exemption the rule denies them the first
# time it runs against the module - a false positive of exactly the kind
# EXC-009's sibling finding was about.
non_regional := {"global"}

# Azure accepts "West Europe", "westeurope" and "WestEurope" interchangeably,
# so normalise before comparing rather than trusting the author's spacing.
normalise(loc) := replace(lower(loc), " ", "")

deny contains msg if {
	some r in lib.resources

	# Only resources that actually carry a location. Data sources, role
	# assignments and policy objects have none, and must not be flagged.
	loc := r.values.location

	# Guard against plan-time unknowns. A location computed from another
	# resource is absent from planned_values rather than present-and-empty,
	# but an empty string would otherwise produce a false positive - the same
	# defect that made the CMK rule reject correct infrastructure.
	is_string(loc)
	loc != ""

	region := normalise(loc)
	not non_regional[region]
	not eu_regions[region]

	msg := sprintf(
		"[GDPR Art.44] %s: location \"%s\" is outside the EU/EEA. Personal data must not leave the EU without a transfer mechanism under Chapter V.",
		[r.address, loc],
	)
}
