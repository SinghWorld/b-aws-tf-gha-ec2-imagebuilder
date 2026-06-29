#!/usr/bin/env bash
#
# destroybootstrap-sandbox.sh
#
# Reverses every action performed by bootstrap-sandbox.sh, in reverse order:
#   1. terraform destroy       → removes all Terraform-managed AWS resources
#                                 (Image Builder, IAM, Lambda, EventBridge,
#                                 SNS, S3 logging bucket, SSM param, OIDC
#                                 provider, etc.)
#   2. delete KMS key + alias  → created directly via `aws kms create-key`
#                                 in bootstrap's Step 4, so it is NOT in
#                                 Terraform state and must be cleaned up
#                                 separately.
#   3. remove GitHub secrets   → the six secrets bootstrap pushed via
#                                 `gh secret set` in its Step 7.
#   4. remove local files      → terraform.tfvars, tfstate, tfplan,
#                                 .terraform/ directory.
#
# Run this from inside the golden-image-windows/ directory (same as bootstrap).
#
# Safety behaviours:
#   - Confirms AWS identity BEFORE doing anything (matches bootstrap's Step 0)
#   - Requires typing the literal word "destroy" as the first confirmation
#   - Shows the terraform destroy plan and asks y/N before applying
#   - Asks for explicit confirmation before deleting the KMS key
#   - Asks for explicit confirmation before removing GitHub secrets
#   - Idempotent — safe to re-run; any resource already absent is skipped
#   - Fails fast and loudly on any AWS CLI / terraform error
#     (set -euo pipefail)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — must match bootstrap-sandbox.sh
# ---------------------------------------------------------------------------
AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="golden-win2022"
GITHUB_ORG="SinghWorld"
GITHUB_REPO="b-aws-tf-gha-ec2-imagebuilder"

export AWS_PROFILE
export AWS_REGION

echo "=============================================================="
echo " Golden Image Sandbox DESTROY"
echo "=============================================================="
echo "AWS profile : $AWS_PROFILE"
echo "AWS region  : $AWS_REGION"
echo "GitHub repo : ${GITHUB_ORG}/${GITHUB_REPO}"
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
echo "This script will REMOVE every resource bootstrap-sandbox.sh created"
echo "in account $ACCOUNT_ID / region $AWS_REGION:"
echo "  - All Terraform-managed AWS resources (Image Builder pipeline + recipe"
echo "    + components, IAM roles, Lambda, EventBridge, SNS, S3 logging"
echo "    bucket, SSM parameter, GitHub OIDC provider)"
echo "  - KMS key + alias '${NAME_PREFIX}-sandbox' (scheduled for deletion)"
echo "  - GitHub repo secrets pushed by bootstrap (with confirmation)"
echo "  - Local files: terraform.tfvars, tfstate, tfplan, .terraform/"
echo ""
read -rp "Type the word 'destroy' (all lowercase) to continue: " CONFIRM_ACCOUNT
if [[ "$CONFIRM_ACCOUNT" != "destroy" ]]; then
  echo "Aborting. No resources were modified."
  exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Step 1: terraform destroy
# ---------------------------------------------------------------------------
echo "--- Step 1: Terraform destroy ---"

if ! command -v terraform &> /dev/null; then
  echo "ERROR: terraform CLI not found on PATH."
  exit 1
fi

# Sanity check: make sure we're actually inside the terraform working dir,
# otherwise 'terraform destroy' would happily read whatever .tf files it
# finds in cwd (or fail with a confusing error).
if [[ ! -f "provider.tf" && ! -f "main.tf" ]]; then
  echo "ERROR: No Terraform configuration files found in $(pwd)."
  echo "This script must be run from inside the golden-image-windows/ directory."
  exit 1
fi

if [[ ! -d ".terraform" ]]; then
  echo "No .terraform directory found — running 'terraform init' first..."
  terraform init -input=false
fi

echo ""
echo "Building a destroy plan..."
terraform plan -destroy -input=false -out=tfplan.destroy

echo ""
echo "=============================================================="
echo " Review the destroy plan above carefully."
echo " It will DELETE every Terraform-managed resource in account:"
echo "   $ACCOUNT_ID"
echo "=============================================================="
read -rp "Apply this destroy plan now? Type 'yes' to destroy: " CONFIRM_DESTROY

if [[ "$CONFIRM_DESTROY" != "yes" ]]; then
  echo "Aborting before any destruction."
  echo "Plan saved to tfplan.destroy — inspect or apply later with:"
  echo "  terraform apply tfplan.destroy"
  exit 0
fi

terraform apply -input=false tfplan.destroy
rm -f tfplan.destroy

echo ""
echo "Terraform-managed resources have been destroyed."
echo ""

# ---------------------------------------------------------------------------
# Step 2: Delete the KMS key + alias (NOT managed by Terraform)
# ---------------------------------------------------------------------------
echo "--- Step 2: KMS key + alias ---"

KMS_ALIAS="alias/${NAME_PREFIX}-sandbox"
EXISTING_KEY_ID=$(aws kms list-aliases \
  --query "Aliases[?AliasName=='${KMS_ALIAS}'].TargetKeyId" \
  --output text 2>/dev/null || true)

if [[ -z "$EXISTING_KEY_ID" || "$EXISTING_KEY_ID" == "None" ]]; then
  echo "No alias '${KMS_ALIAS}' found — KMS key not present, skipping."
else
  KMS_KEY_ARN=$(aws kms describe-key --key-id "$EXISTING_KEY_ID" --query "KeyMetadata.Arn" --output text)
  echo "Found KMS key:"
  echo "  Alias : ${KMS_ALIAS}"
  echo "  KeyId : ${EXISTING_KEY_ID}"
  echo "  ARN   : ${KMS_KEY_ARN}"
  echo ""
  echo "KMS deletion is asynchronous and irreversible:"
  echo "  1. The alias is removed immediately."
  echo "  2. The key is scheduled for deletion with a 7-day waiting period"
  echo "     (the AWS minimum). During this window you can cancel."
  echo "  3. After the wait, the key material is purged and unrecoverable."
  echo ""
  read -rp "Schedule this KMS key for deletion? Type 'yes' to continue: " CONFIRM_KMS
  if [[ "$CONFIRM_KMS" == "yes" ]]; then
    echo "Deleting alias ${KMS_ALIAS}..."
    aws kms delete-alias --alias-name "$KMS_ALIAS"
    echo "Scheduling key deletion (7-day waiting period)..."
    aws kms schedule-key-deletion \
      --key-id "$EXISTING_KEY_ID" \
      --pending-window-in-days 7
    echo "Done. The key is queued for purge; AWS will remove it after 7 days."
    echo "To cancel deletion within the waiting period:"
    echo "  aws kms cancel-key-deletion --key-id ${EXISTING_KEY_ID}"
  else
    echo "Skipped KMS cleanup. Key ${EXISTING_KEY_ID} still exists."
  fi
fi
echo ""

# ---------------------------------------------------------------------------
# Step 3: Remove GitHub repo secrets (optional, with confirmation)
# ---------------------------------------------------------------------------
echo "--- Step 3: Remove GitHub repo secrets ---"

SECRETS_TO_REMOVE=(
  "AWS_OIDC_ROLE_ARN"
  "GOLDEN_IMAGE_SUBNET_ID"
  "GOLDEN_IMAGE_SG_IDS"
  "GOLDEN_IMAGE_KMS_KEY_ARN"
  "GOLDEN_IMAGE_DISTRIBUTION_ACCOUNTS"
  "GOLDEN_IMAGE_SNS_TOPIC_ARN"
)

remove_github_secrets() {
  if ! command -v gh &> /dev/null; then
    echo "gh CLI not found on PATH — skipping GitHub secret cleanup."
    return 1
  fi

  if ! gh auth status &> /dev/null; then
    echo "gh CLI is installed but not authenticated — skipping."
    return 1
  fi

  echo "Will attempt to remove these secrets from ${GITHUB_ORG}/${GITHUB_REPO}:"
  printf '  - %s\n' "${SECRETS_TO_REMOVE[@]}"
  echo ""
  read -rp "Remove these GitHub secrets now? Type 'yes' to continue: " CONFIRM_SECRETS

  if [[ "$CONFIRM_SECRETS" != "yes" ]]; then
    return 1
  fi

  echo ""
  for secret in "${SECRETS_TO_REMOVE[@]}"; do
    if gh secret delete "$secret" --repo "${GITHUB_ORG}/${GITHUB_REPO}" 2>/dev/null; then
      echo "  ✓ removed: $secret"
    else
      echo "  - not present (skipped): $secret"
    fi
  done
  return 0
}

if ! remove_github_secrets; then
  echo ""
  echo "If you want to clean up GitHub secrets manually, remove these from"
  echo "${GITHUB_ORG}/${GITHUB_REPO} → Settings → Secrets and variables → Actions:"
  printf '  - %s\n' "${SECRETS_TO_REMOVE[@]}"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 4: Remove local files generated by bootstrap
# ---------------------------------------------------------------------------
echo "--- Step 4: Local file cleanup ---"

LOCAL_FILES_TO_REMOVE=(
  "terraform.tfvars"
  "terraform.tfstate"
  "terraform.tfstate.backup"
  "tfplan.binary"
)

for f in "${LOCAL_FILES_TO_REMOVE[@]}"; do
  if [[ -e "$f" ]]; then
    rm -f "$f"
    echo "  ✓ removed: $f"
  else
    echo "  - not present (skipped): $f"
  fi
done

if [[ -d ".terraform" ]]; then
  rm -rf .terraform
  echo "  ✓ removed: .terraform/"
else
  echo "  - not present (skipped): .terraform/"
fi

echo ""
echo "These files were intentionally LEFT IN PLACE because they may be"
echo "checked into git or used by other tooling:"
echo "  - .terraform.lock.hcl         (dependency lock; commit + reuse)"
echo "  - lambda/update_ssm_param.zip (deployment artifact)"
echo "  - lambda/index.py             (Lambda source)"
echo "  - *.tf                        (Terraform config — owned by git)"
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=============================================================="
echo " Destroy complete"
echo "=============================================================="
echo "  Terraform-managed AWS resources : removed"
echo "  KMS key                         : see Step 2 output (deletion pending)"
echo "  GitHub repo secrets             : see Step 3 output"
echo "  Local files                     : see Step 4 output"
echo ""
echo "To re-bootstrap, copy terraform.tfvars.example to terraform.tfvars"
echo "(or re-run bootstrap-sandbox.sh from scratch) and apply Terraform again."
