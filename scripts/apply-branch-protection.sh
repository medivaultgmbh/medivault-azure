#!/usr/bin/env bash
#
# Apply branch protection to main, as code.
#
# Clicking these settings in the UI works, but leaves no record of what was
# configured, when, or why. Applying them from a script that lives in the
# repository makes the control auditable and reproducible - the same argument
# the project makes for infrastructure.
#
# Requires: gh CLI, authenticated with admin rights on the repo.
#
# Usage:
#   ./scripts/apply-branch-protection.sh medivaultgmbh/medivault-azure
#
set -euo pipefail

REPO="${1:?usage: apply-branch-protection.sh <org>/<repo>}"
BRANCH="main"

echo "==> Applying branch protection to ${REPO}:${BRANCH}"

# Required status checks differ per repo: only medivault-azure runs the policy
# gate. Detect rather than assume, so this script is safe everywhere.
CHECKS='[]'
if [[ "$REPO" == *"medivault-azure"* ]]; then
  CHECKS='["Policy gate (reference architecture)","Policy gate negative test"]'
  echo "    requiring policy gate checks"
fi

cat > /tmp/protection.json <<EOF
{
  "required_status_checks": {
    "strict": true,
    "contexts": ${CHECKS}
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
EOF

gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "/repos/${REPO}/branches/${BRANCH}/protection" \
  --input /tmp/protection.json > /dev/null

rm -f /tmp/protection.json

# Secret scanning + push protection. Free on public repositories.
echo "==> Enabling secret scanning and push protection"
gh api --method PATCH "/repos/${REPO}" \
  -f 'security_and_analysis[secret_scanning][status]=enabled' \
  -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled' \
  > /dev/null 2>&1 || echo "    (skipped - requires a public repo or GHAS)"

cat <<EOF

Applied to ${REPO}:

  required reviews          1, from a Code Owner
  stale reviews dismissed   yes
  enforce for admins        YES  <- deliberate
  linear history            required
  conversation resolution   required
  force push / deletion     blocked
  status checks             ${CHECKS}
  secret scanning           enabled with push protection

'enforce_admins: true' is the setting that matters on a solo project. Without
it, branch protection is advisory - the one person who can bypass it is the
only person committing. With it, the audit trail means something.

EOF
