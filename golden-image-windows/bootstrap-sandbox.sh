#!/usr/bin/env bash
#
# bootstrap-sandbox.sh
#
# Automates steps 2-6 of the golden image setup:
#   2. Discover a usable subnet + security group
#   3. (base_image_arn already correct in terraform.tfvars.example — no action needed)
#   4. Create a KMS key for AMI encryption
#   5. Generate terraform.tfvars from discovered values
#   6. terraform init / plan / apply (with manual confirmation before apply)
#
# Run this from inside the golden-image-windows/ directory.
#
# Safety behaviours:
#   - Never overwrites an existing terraform.tfvars without confirmation
#   - Never applies without showing the plan and asking y/N first
#   - Fails fast and loudly on any AWS CLI error (set -euo pipefail)
#   - Prints exactly which account/region it's about to touch before doing anything
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — adjust these two if your sandbox/repo differs
# ---------------------------------------------------------------------------
AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="golden-win2022"
GITHUB_ORG="SinghWorld"
GITHUB_REPO="b-aws-tf-gha-ec2-imagebuilder"

export AWS_PROFILE
export AWS_REGION

echo "=============================================================="
echo " Golden Image Sandbox Bootstrap"
echo "=============================================================="
echo "AWS profile : $AWS_PROFILE"
echo "AWS region  : $AWS_REGION"
echo ""

# ---------------------------------------------------------------------------
# Step 0: Confirm identity and account — the single most important safety check
# ---------------------------------------------------------------------------
echo "--- Step 0: Confirming AWS identity ---"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
CALLER_ARN=$(aws sts get-caller-identity --query "Arn" --output text)

echo "Account ID : $ACCOUNT_ID"
echo "Caller ARN : $CALLER_ARN"
echo ""
read -rp "Is this the correct SANDBOX account? Type 'yes' to continue: " CONFIRM_ACCOUNT
if [[ "$CONFIRM_ACCOUNT" != "yes" ]]; then
  echo "Aborting. Set AWS_PROFILE to the correct sandbox profile and re-run."
  exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Step 2: Discover a default subnet and security group
# ---------------------------------------------------------------------------
echo "--- Step 2: Discovering network resources ---"

DEFAULT_VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=is-default,Values=true" \
  --query "Vpcs[0].VpcId" --output text)

if [[ "$DEFAULT_VPC_ID" == "None" || -z "$DEFAULT_VPC_ID" ]]; then
  echo "ERROR: No default VPC found in this account/region."
  echo "You'll need to supply subnet_id and security_group_ids manually in terraform.tfvars."
  exit 1
fi

echo "Default VPC: $DEFAULT_VPC_ID"

SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${DEFAULT_VPC_ID}" "Name=default-for-az,Values=true" \
  --query "Subnets[0].SubnetId" --output text)

if [[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]]; then
  echo "ERROR: No default-for-az subnet found in VPC $DEFAULT_VPC_ID."
  echo "Falling back to the first available subnet in this VPC instead..."
  SUBNET_ID=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${DEFAULT_VPC_ID}" \
    --query "Subnets[0].SubnetId" --output text)
fi

if [[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]]; then
  echo "ERROR: No subnets found at all in VPC $DEFAULT_VPC_ID. Cannot continue."
  exit 1
fi

SUBNET_AZ=$(aws ec2 describe-subnets \
  --subnet-ids "$SUBNET_ID" \
  --query "Subnets[0].AvailabilityZone" --output text)

SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${DEFAULT_VPC_ID}" "Name=group-name,Values=default" \
  --query "SecurityGroups[0].GroupId" --output text)

if [[ "$SECURITY_GROUP_ID" == "None" || -z "$SECURITY_GROUP_ID" ]]; then
  echo "ERROR: No default security group found in VPC $DEFAULT_VPC_ID. Cannot continue."
  exit 1
fi

echo "Subnet            : $SUBNET_ID ($SUBNET_AZ)"
echo "Security group     : $SECURITY_GROUP_ID"
echo ""
echo "NOTE: this is the VPC's default security group, which allows all"
echo "outbound traffic — sufficient for Image Builder's SSM-based build"
echo "process. Tighten this later for anything beyond sandbox testing."
echo ""

# ---------------------------------------------------------------------------
# Step 3: base_image_arn — no discovery needed
# ---------------------------------------------------------------------------
echo "--- Step 3: Base image ARN ---"
BASE_IMAGE_ARN="arn:aws:imagebuilder:${AWS_REGION}:aws:image/windows-server-2022-english-full-base-x86/x.x.x"
echo "Using: $BASE_IMAGE_ARN"
echo "(the x.x.x suffix is Image Builder's literal syntax for 'always latest' — not a placeholder you need to fill in)"
echo ""

# ---------------------------------------------------------------------------
# Step 4: Create a KMS key for AMI encryption
# ---------------------------------------------------------------------------
echo "--- Step 4: KMS key for AMI encryption ---"

EXISTING_KEY_ID=$(aws kms list-aliases \
  --query "Aliases[?AliasName=='alias/${NAME_PREFIX}-sandbox'].TargetKeyId" \
  --output text 2>/dev/null || true)

if [[ -n "$EXISTING_KEY_ID" && "$EXISTING_KEY_ID" != "None" ]]; then
  echo "Found existing key via alias/${NAME_PREFIX}-sandbox — reusing it."
  KMS_KEY_ARN=$(aws kms describe-key --key-id "$EXISTING_KEY_ID" --query "KeyMetadata.Arn" --output text)
else
  echo "Creating new KMS key..."
  KMS_KEY_ID=$(aws kms create-key \
    --description "${NAME_PREFIX} golden image AMI encryption (sandbox)" \
    --tags TagKey=Project,TagValue=golden-image-lab TagKey=Environment,TagValue=sandbox \
    --query "KeyMetadata.KeyId" --output text)

  aws kms create-alias \
    --alias-name "alias/${NAME_PREFIX}-sandbox" \
    --target-key-id "$KMS_KEY_ID"

  KMS_KEY_ARN=$(aws kms describe-key --key-id "$KMS_KEY_ID" --query "KeyMetadata.Arn" --output text)
  echo "Created key: $KMS_KEY_ARN"
  echo "Alias: alias/${NAME_PREFIX}-sandbox"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 5: Generate terraform.tfvars
# ---------------------------------------------------------------------------
echo "--- Step 5: Generating terraform.tfvars ---"

if [[ -f terraform.tfvars ]]; then
  echo "terraform.tfvars already exists."
  read -rp "Overwrite it with freshly discovered sandbox values? (y/N): " OVERWRITE
  if [[ "$OVERWRITE" != "y" && "$OVERWRITE" != "Y" ]]; then
    echo "Leaving terraform.tfvars untouched. Skipping to Step 6."
    SKIP_TFVARS_WRITE=true
  fi
fi

if [[ "${SKIP_TFVARS_WRITE:-false}" != "true" ]]; then
  cat > terraform.tfvars <<EOF
aws_region   = "${AWS_REGION}"
name_prefix  = "${NAME_PREFIX}"

base_image_arn = "${BASE_IMAGE_ARN}"

subnet_id           = "${SUBNET_ID}"
security_group_ids  = ["${SECURITY_GROUP_ID}"]

kms_key_id = "${KMS_KEY_ARN}"

# Empty in sandbox — no spoke accounts to distribute to yet
distribution_accounts = []
distribution_regions  = {}

sns_topic_arn = ""

tags = {
  Environment = "sandbox"
  ManagedBy   = "terraform"
  Project     = "golden-image-lab"
  Owner       = "balraj"
}

# --- GitHub OIDC ---
github_org          = "${GITHUB_ORG}"
github_repo         = "${GITHUB_REPO}"
allowed_branches    = ["main"]
allow_pull_requests = true
role_name           = "${NAME_PREFIX}-github-actions-role"

create_oidc_provider       = true
existing_oidc_provider_arn = ""
EOF
  echo "Wrote terraform.tfvars"
fi
echo ""
echo "Review terraform.tfvars before continuing:"
echo "--------------------------------------------------------------"
cat terraform.tfvars
echo "--------------------------------------------------------------"
echo ""
read -rp "Does this look correct? Type 'yes' to continue to terraform init/plan: " CONFIRM_TFVARS
if [[ "$CONFIRM_TFVARS" != "yes" ]]; then
  echo "Stopping here. Edit terraform.tfvars manually, then re-run with SKIP steps as needed."
  exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Step 6: terraform init / plan / apply
# ---------------------------------------------------------------------------
echo "--- Step 6: Terraform init, plan, apply ---"

if ! command -v terraform &> /dev/null; then
  echo "ERROR: terraform CLI not found on PATH. Install it first: https://developer.hashicorp.com/terraform/install"
  exit 1
fi

# Lambda zip must exist before apply, since aws_lambda_function references it by path
if [[ ! -f lambda/update_ssm_param.zip ]]; then
  echo "Building lambda/update_ssm_param.zip..."
  (cd lambda && zip -j update_ssm_param.zip index.py)
fi

terraform init -input=false

echo ""
echo "Running terraform plan..."
terraform plan -input=false -out=tfplan.binary

echo ""
echo "=============================================================="
echo " Review the plan output above carefully."
echo " This will create real AWS resources in account: $ACCOUNT_ID"
echo "=============================================================="
read -rp "Apply this plan now? Type 'yes' to apply: " CONFIRM_APPLY

if [[ "$CONFIRM_APPLY" != "yes" ]]; then
  echo "Plan saved to tfplan.binary. Apply later with: terraform apply tfplan.binary"
  exit 0
fi

terraform apply -input=false tfplan.binary

echo ""
echo "=============================================================="
echo " Apply complete. Key outputs:"
echo "=============================================================="
terraform output

# ---------------------------------------------------------------------------
# Step 7: Push secrets to the GitHub repo via gh CLI
# ---------------------------------------------------------------------------
# After the apply succeeds, every value the GitHub Actions workflows need
# is now available either from terraform.tfvars (which we just generated)
# or from terraform output. Push them all to the repo so CI can run.
#
# Falls back to manual instructions if gh is missing/unauthenticated, so
# this block is safe to run in any environment.
# ---------------------------------------------------------------------------
echo ""
echo "=============================================================="
echo " Step 7: Push GitHub repo secrets"
echo "=============================================================="

GITHUB_ACTIONS_ROLE_ARN=$(terraform output -raw github_actions_role_arn 2>/dev/null || true)

if [[ -z "$GITHUB_ACTIONS_ROLE_ARN" || "$GITHUB_ACTIONS_ROLE_ARN" == "null" ]]; then
  echo "WARNING: could not read github_actions_role_arn from terraform output."
  echo "AWS_OIDC_ROLE_ARN will be skipped."
fi

push_secrets_via_gh() {
  if ! command -v gh &> /dev/null; then
    echo "gh CLI not found on PATH — falling back to manual instructions."
    echo "Install from https://cli.github.com/ and re-run, or set the"
    echo "secrets manually as shown in the 'Next steps' section below."
    return 1
  fi

  if ! gh auth status &> /dev/null; then
    echo "gh CLI is installed but not authenticated — falling back to manual instructions."
    echo "Run 'gh auth login' and re-run, or set the secrets manually."
    return 1
  fi

  echo "Will set the following secrets on ${GITHUB_ORG}/${GITHUB_REPO}:"
  echo "  AWS_OIDC_ROLE_ARN                  = ${GITHUB_ACTIONS_ROLE_ARN:-<skipped — not available>}"
  echo "  GOLDEN_IMAGE_SUBNET_ID             = ${SUBNET_ID}"
  echo "  GOLDEN_IMAGE_SG_IDS                = [\"${SECURITY_GROUP_ID}\"]"
  echo "  GOLDEN_IMAGE_KMS_KEY_ARN           = ${KMS_KEY_ARN}"
  echo "  GOLDEN_IMAGE_DISTRIBUTION_ACCOUNTS = []"
  echo "  GOLDEN_IMAGE_SNS_TOPIC_ARN         = (empty string)"
  echo ""
  read -rp "Push these secrets to ${GITHUB_ORG}/${GITHUB_REPO} now? (yes/no): " CONFIRM_SECRETS

  if [[ "$CONFIRM_SECRETS" != "yes" ]]; then
    echo "Skipped. See the 'Next steps' section below for manual instructions."
    return 1
  fi

  echo ""
  echo "Pushing secrets..."

  set_one_secret() {
    local name="$1"
    local value="$2"
    if gh secret set "$name" --repo "${GITHUB_ORG}/${GITHUB_REPO}" --body "$value" &> /dev/null; then
      echo "  ✓ set: $name"
    else
      echo "  ✗ FAILED: $name"
      return 1
    fi
  }

  local rc=0

  if [[ -n "$GITHUB_ACTIONS_ROLE_ARN" && "$GITHUB_ACTIONS_ROLE_ARN" != "null" ]]; then
    set_one_secret "AWS_OIDC_ROLE_ARN" "$GITHUB_ACTIONS_ROLE_ARN" || rc=1
  else
    echo "  - skipped (no value): AWS_OIDC_ROLE_ARN"
  fi

  set_one_secret "GOLDEN_IMAGE_SUBNET_ID"             "$SUBNET_ID" || rc=1
  set_one_secret "GOLDEN_IMAGE_SG_IDS"                "[\"${SECURITY_GROUP_ID}\"]" || rc=1
  set_one_secret "GOLDEN_IMAGE_KMS_KEY_ARN"           "$KMS_KEY_ARN" || rc=1
  set_one_secret "GOLDEN_IMAGE_DISTRIBUTION_ACCOUNTS" "[]" || rc=1
  set_one_secret "GOLDEN_IMAGE_SNS_TOPIC_ARN"         "" || rc=1

  echo ""
  if [[ $rc -eq 0 ]]; then
    echo "All secrets pushed. Verify with:"
    echo "  gh secret list --repo ${GITHUB_ORG}/${GITHUB_REPO}"
  else
    echo "One or more secrets failed to push. Re-run the script or set them manually."
    echo "  See 'Next steps' below for the exact values."
  fi
  return $rc
}

push_secrets_via_gh || true   # never block the rest of the output on a secret-push failure

echo ""
echo "Next steps:"
echo "  1. Copy the 'github_actions_role_arn' output above into your"
echo "     GitHub repo secret: AWS_OIDC_ROLE_ARN"
echo "  2. Also set these GitHub secrets (sandbox values, since lists are empty):"
echo "       GOLDEN_IMAGE_SUBNET_ID               = ${SUBNET_ID}"
echo "       GOLDEN_IMAGE_SG_IDS                  = [\"${SECURITY_GROUP_ID}\"]"
echo "       GOLDEN_IMAGE_KMS_KEY_ARN              = ${KMS_KEY_ARN}"
echo "       GOLDEN_IMAGE_DISTRIBUTION_ACCOUNTS    = []"
echo "       GOLDEN_IMAGE_SNS_TOPIC_ARN            = \"\""
echo "  3. Trigger your first build MANUALLY before pushing to GitHub:"
echo "       aws imagebuilder start-image-pipeline-execution \\"
echo "         --image-pipeline-arn \$(terraform output -raw pipeline_arn)"
echo "  4. Poll status with:"
echo "       aws imagebuilder get-image --image-build-version-arn <arn> --query 'image.state' --output table"
echo ""
