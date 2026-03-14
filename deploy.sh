#!/bin/bash
set -e

CLEAN=false
if [ "$1" = "--clean" ]; then
    CLEAN=true
fi

echo "🚀 Deploying Spring AI Chat Client to AgentCore Runtime"
echo ""

# Check prerequisites
if ! command -v terraform &> /dev/null; then
    echo "❌ Terraform is required but not installed"
    exit 1
fi

if ! command -v docker &> /dev/null; then
    echo "❌ Docker is required but not installed"
    exit 1
fi

if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI is required but not installed"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo "❌ AWS credentials not configured"
    exit 1
fi

echo "✅ Prerequisites check passed"
echo ""

# Navigate to terraform directory
cd terraform

# Clean deploy: delete the runtime first so all sessions are killed
if [ "$CLEAN" = true ]; then
    echo "🧹 Clean deploy: deleting existing runtime..."
    RUNTIME_ID=$(terraform output -raw runtime_id 2>/dev/null || true)
    if [ -n "$RUNTIME_ID" ]; then
        aws bedrock-agentcore-control delete-agent-runtime \
            --agent-runtime-id "$RUNTIME_ID" \
            --region us-east-1 --output json 2>/dev/null || true

        echo "   Waiting for runtime deletion..."
        while true; do
            STATUS=$(aws bedrock-agentcore-control get-agent-runtime \
                --agent-runtime-id "$RUNTIME_ID" \
                --region us-east-1 --query status --output text 2>&1)
            if echo "$STATUS" | grep -qi "not found\|ResourceNotFoundException"; then
                break
            fi
            sleep 5
        done
        echo "   ✅ Runtime deleted"

        # Remove from Terraform state so it can recreate it
        terraform state rm aws_bedrockagentcore_agent_runtime.extended_chat 2>/dev/null || true
    else
        echo "   No existing runtime found, skipping"
    fi
    echo ""
fi

# Initialize Terraform
echo "🔧 Initializing Terraform..."
terraform init -input=false

# Plan deployment
echo "📋 Planning deployment..."
terraform plan -out=tfplan

# Apply deployment
echo "🚀 Deploying to AgentCore Runtime..."
terraform apply -auto-approve tfplan

echo ""
echo "✅ Deployment Complete!"
echo ""

# Get outputs
MEMORY_ID=$(terraform output -raw memory_id)
RUNTIME_NAME=$(terraform output -raw runtime_name)
CONTAINER_URI=$(terraform output -raw container_uri)

echo "✅ Deployment successful!"
echo ""
echo "📊 Deployment Information:"
echo "  Memory ID: $MEMORY_ID"
echo "  Runtime Name: $RUNTIME_NAME"
echo "  Container URI: $CONTAINER_URI"
echo ""

# Sync runtime_id_suffix in variables.tf to the actual runtime's suffix.
# AgentCore assigns a new random suffix on every recreate; env vars (cloud.resource_id,
# aws.log.group.names) must reflect it for the GenAI Observability dashboard to work.
# This is a no-op if the suffix is already correct.
cd ..
RUNTIME_ID=$(terraform -chdir=terraform output -raw runtime_id)
NEW_SUFFIX="${RUNTIME_ID##*-}"
VARIABLES_FILE="terraform/variables.tf"
CURRENT_SUFFIX=$(grep -A4 '"runtime_id_suffix"' "$VARIABLES_FILE" | grep 'default' | sed 's/.*"\([^"]*\)".*/\1/')
if [ "$CURRENT_SUFFIX" != "$NEW_SUFFIX" ]; then
    echo "🔄 Syncing runtime_id_suffix: $CURRENT_SUFFIX → $NEW_SUFFIX"
    sed -i "s/default     = \"${CURRENT_SUFFIX}\"/default     = \"${NEW_SUFFIX}\"/" "$VARIABLES_FILE"
    terraform -chdir=terraform apply -auto-approve
    echo "✅ runtime_id_suffix synced"
fi

echo "🚀 What to run next:"
echo "  ./test.sh    # Test OAuth authentication and memory isolation"
echo ""

echo "🔍 Monitor runtime status:"
echo "  aws bedrock-agentcore-control get-agent-runtime \\"
echo "    --agent-runtime-id $RUNTIME_NAME \\"
echo "    --region us-east-1"
