#!/usr/bin/env python3
"""
Unit tests for the GDPR policy set.

WHY THIS EXISTS

The negative-test job in CI proves the gate rejects a wholly non-compliant
fixture. It cannot prove the gate rejects the *right things*, nor that it
accepts compliant infrastructure - and a policy that denies nothing passes that
job just as happily as one that works.

EXC-009 is the case in point: three policies spent weeks reading only
root-module resources after the configuration was modularised. Every CI run was
green. These tests assert on plan shapes directly, so that class of silent
coverage loss fails loudly.

    pip install regopy
    python3 policies/test/test_policies.py
"""
import glob
import json
import os
import sys

try:
    from regopy import Interpreter
except ImportError:
    sys.exit("regopy not installed:  pip install regopy")

POLICY_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

NAMESPACES = [
    "adls_encryption",
    "api_logging",
    "cosmos_pitr",
    "keyvault_key_rotation",
    "no_public_storage",
    "rbac_no_wildcard",
    "eu_data_residency",
]


def denies(plan, namespace):
    """Deny messages produced by one policy for one plan."""
    rego = Interpreter()
    for f in sorted(glob.glob(os.path.join(POLICY_DIR, "*.rego"))):
        rego.add_module(os.path.basename(f), open(f).read())
    rego.set_input(plan)
    raw = str(rego.query(f"data.compliance.gdpr.{namespace}.deny"))
    return [] if raw.strip() == '{"expressions":[[]]}' else [raw]


def plan(root=None, child=None, configuration=None):
    return {
        "planned_values": {
            "root_module": {
                "resources": root or [],
                "child_modules": [{"address": "module.grc_baseline",
                                   "resources": child}] if child else [],
            }
        },
        "configuration": configuration or {"root_module": {"resources": [], "module_calls": {}}},
    }


RESULTS = []


def check(name, condition, detail=""):
    RESULTS.append((name, condition, detail))
    print(f"  {'PASS' if condition else 'FAIL'}  {name}" + (f"  {detail}" if not condition else ""))


# --------------------------------------------------------------------------
# EXC-009: resources inside child modules must be evaluated.
# --------------------------------------------------------------------------
child_violation = plan(child=[
    {"address": "module.grc_baseline.azurerm_key_vault.v", "type": "azurerm_key_vault",
     "values": {"location": "westeurope", "purge_protection_enabled": False}},
])
check("child-module violations are detected (EXC-009)",
      len(denies(child_violation, "keyvault_key_rotation")) > 0,
      "child modules are invisible to the gate again")

# --------------------------------------------------------------------------
# EU data residency.
# --------------------------------------------------------------------------
check("non-EU region is denied",
      len(denies(plan(root=[
          {"address": "azurerm_storage_account.s", "type": "azurerm_storage_account",
           "values": {"location": "eastus"}}]), "eu_data_residency")) > 0)

check("'Global' pseudo-region is exempt",
      len(denies(plan(root=[
          {"address": "azurerm_monitor_action_group.g", "type": "azurerm_monitor_action_group",
           "values": {"location": "Global"}}]), "eu_data_residency")) == 0,
      "action groups must not be flagged - Azure requires location Global")

check("spaced region names are normalised",
      len(denies(plan(root=[
          {"address": "azurerm_storage_account.s", "type": "azurerm_storage_account",
           "values": {"location": "West Europe"}}]), "eu_data_residency")) == 0)

check("unknown location does not false-positive",
      len(denies(plan(root=[
          {"address": "azurerm_storage_account.s", "type": "azurerm_storage_account",
           "values": {}}]), "eu_data_residency")) == 0)

# --------------------------------------------------------------------------
# No false positives on a compliant plan. This is the assertion that would have
# caught the CMK regression, where correct infrastructure was rejected because
# key_vault_key_id is unknown at plan time.
# --------------------------------------------------------------------------
compliant = plan(
    root=[{"address": "azurerm_key_vault.grc", "type": "azurerm_key_vault",
           "values": {"location": "westeurope", "purge_protection_enabled": True}}],
    child=[
        {"address": "module.grc_baseline.azurerm_monitor_action_group.ops",
         "type": "azurerm_monitor_action_group", "values": {"location": "Global"}},
        {"address": "module.grc_baseline.azurerm_storage_account.evidence_vault",
         "type": "azurerm_storage_account",
         "values": {"location": "West Europe", "public_network_access_enabled": False,
                    "min_tls_version": "TLS1_2", "is_hns_enabled": True}},
    ],
    configuration={"root_module": {"resources": [], "module_calls": {"grc_baseline": {"module": {
        "resources": [{"address": "azurerm_storage_account.evidence_vault",
                       "expressions": {"customer_managed_key": [
                           {"key_vault_key_id": {"references": ["azurerm_key_vault_key.k"]}}]}}]}}}}},
)

for ns in NAMESPACES:
    check(f"compliant plan is accepted by {ns}",
          len(denies(compliant, ns)) == 0,
          "false positive - this blocks correct infrastructure")

failed = [n for n, ok, _ in RESULTS if not ok]
print()
print(f"  {len(RESULTS) - len(failed)}/{len(RESULTS)} passed")
sys.exit(1 if failed else 0)
