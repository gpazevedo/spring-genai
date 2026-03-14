#!/usr/bin/env bash
# Updates var.runtime_id_suffix in terraform/variables.tf to match the current
# AgentCore runtime, then applies. Required after terraform destroy + apply because
# AgentCore assigns a new random suffix that the runtime needs in its env vars.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARIABLES_FILE="$SCRIPT_DIR/terraform/variables.tf"

RUNTIME_ID=$(terraform -chdir="$SCRIPT_DIR/terraform" output -raw runtime_id)
NEW_SUFFIX="${RUNTIME_ID##*-}"

CURRENT_SUFFIX=$(grep -A4 '"runtime_id_suffix"' "$VARIABLES_FILE" | grep 'default' | sed 's/.*"\([^"]*\)".*/\1/')

if [ "$CURRENT_SUFFIX" = "$NEW_SUFFIX" ]; then
  echo "runtime_id_suffix is already $NEW_SUFFIX — nothing to do."
  exit 0
fi

sed -i "s/default     = \"${CURRENT_SUFFIX}\"/default     = \"${NEW_SUFFIX}\"/" "$VARIABLES_FILE"
echo "Updated runtime_id_suffix: $CURRENT_SUFFIX → $NEW_SUFFIX"

terraform -chdir="$SCRIPT_DIR/terraform" apply
