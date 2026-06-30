# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is an **Enterprise Golden Image Pipeline** for Windows Server 2022 using AWS EC2 Image Builder and Terraform. It builds hardened, validated, encrypted Windows AMIs and distributes them across accounts/regions in a hub-and-spoke landing zone architecture.

**Key Architecture:**
- **GitHub Actions OIDC** → assumes IAM role (no long-lived keys)
- **Terraform** manages all Image Builder resources (pipeline, recipe, components, infra config, distribution config)
- **EC2 Image Builder** orchestrates build/test/distribute
- **EventBridge + Lambda** → auto-updates SSM Parameter Store with latest AMI ID on success
- **Downstream consumers** (ASGs, launch templates, other Terraform) read AMI ID from SSM Parameter Store — never hardcode AMI IDs

---

## Repository Structure

```
b-aws-tf-gha-ec2-imagebuilder/
├── .github/workflows/
│   ├── golden-image-build.yml       # Triggers Image Builder pipeline on component changes
│   └── golden-image-terraform.yml   # Terraform plan/apply for infra changes
├── golden-image-windows/
│   ├── components/                  # Image Builder components (YAML)
│   │   ├── windows-updates.yaml     # Windows Updates installation
│   │   ├── cis-hardening.yaml       # CIS Benchmark hardening
│   │   ├── agent-install.yaml       # SSM Agent + CloudWatch Agent
│   │   └── validation-test.yaml     # Pester validation tests
│   ├── lambda/
│   │   ├── index.py                 # Lambda: updates SSM param + SNS on build completion
│   │   └── update_ssm_param.zip     # Pre-built deployment package
│   ├── *.tf                         # Terraform modules (see below)
│   ├── terraform.tfvars.example     # Template for terraform.tfvars
│   └── terraform.tfvars             # Actual values (gitignored, from GitHub secrets)
├── README.md                         # Full documentation
└── test.md                           # Testing documentation
```

The golden-image-windows/scripts/ subfolder contains local sandbox lifecycle scripts (not used by CI):

```
golden-image-windows/scripts/
├── bootstrap-sandbox.sh              # One-time sandbox bootstrap (creates state bucket,
│                                       KMS key, tfvars, runs first apply, pushes secrets)
└── destroybootstrap-sandbox.sh       # Sandbox teardown (terraform destroy, KMS purge,
                                        removes GitHub secrets, cleans local files)
```

Both scripts are self-locating — they derive the Terraform working directory from `BASH_SOURCE[0]`, so they can be invoked from anywhere (e.g. `bash golden-image-windows/scripts/bootstrap-sandbox.sh`).

---

## Terraform Files (golden-image-windows/)

| File | Purpose |
|------|---------|
| `provider.tf` | AWS provider config, required_version |
| `variables.tf` | Input variables (subnet, SG, KMS, accounts, GitHub OIDC, etc.) |
| `variables.tf` | OIDC-specific variables |
| `iam.tf` | IAM roles: Image Builder instance role, instance profile |
| `recipe.tf` | Image recipe + 4 components (updates → CIS → agents → validation) |
| `infrastructure-configuration.tf` | Build instance config (subnet, SG, instance types, logging bucket) |
| `distribution-configuration.tf` | Cross-account/region AMI distribution, KMS encryption, launch permissions |
| `pipeline.tf` | Image pipeline + schedule + SSM parameter for latest AMI |
| `eventbridge.tf` | EventBridge rule + Lambda to update SSM param on build completion |
| `oidc-github-actions.tf` | GitHub OIDC provider + IAM role with least-privilege policy |
| `outputs.tf` | Pipeline ARN, recipe ARN, SSM param name, GitHub role ARN |

---

## GitHub Actions Workflows

### 1. `golden-image-build.yml` — Trigger Build
**Triggers:** Push to main (component changes), manual dispatch, weekly schedule
**Purpose:** Starts Image Builder pipeline execution, polls until completion (up to 90 min)
**Environment:** `golden-image-shared-services` (requires approval gate)
**Key steps:**
1. Configure AWS credentials via OIDC
2. Look up pipeline ARN by name
3. `aws imagebuilder start-image-pipeline-execution`
4. Poll `aws imagebuilder get-image` until `AVAILABLE`/`FAILED`
5. On success: fetch AMI ID, confirm SSM param updated via EventBridge+Lambda

### 2. `golden-image-terraform.yml` — Terraform Plan/Apply
**Triggers:** PR/push to main (`.tf` files, lambda code), manual dispatch
**Jobs:**
- `terraform-plan`: Runs on PRs and pushes; posts plan to PR comment; uploads plan artifact
- `terraform-apply`: Runs only on push to main; downloads plan artifact; applies with `-auto-approve`

---

## Common Development Commands

### Terraform (run from `golden-image-windows/`)

```bash
# Initial setup
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values (subnet, SG, KMS, GitHub org/repo, etc.)

terraform init
terraform fmt -check -recursive
terraform validate
terraform plan

# Apply (first time must be manual — bootstraps OIDC role that CI then uses)
terraform apply

# Trigger first build manually (schedule only runs future builds)
aws imagebuilder start-image-pipeline-execution \
  --image-pipeline-arn $(terraform output -raw pipeline_arn)

# View outputs
terraform output
```

### Lambda Development (in `golden-image-windows/lambda/`)

```bash
# After editing index.py, rebuild the deployment package
cd lambda
zip -j update_ssm_param.zip index.py
# Commit the updated zip; terraform-apply workflow will pick it up
```

### Local Validation

```bash
# Validate Terraform syntax
terraform validate

# Check formatting
terraform fmt -check -recursive

# Validate Image Builder component YAML syntax
# (aws imagebuilder create-component --cli-input-yaml file://components/windows-updates.yaml --dry-run)
```

---

## Key Variables (from `terraform.tfvars.example`)

| Variable | Required | Description |
|----------|----------|-------------|
| `subnet_id` | Yes | Private subnet with SSM VPC endpoints or NAT |
| `security_group_ids` | Yes | SG for build instance |
| `kms_key_id` | Yes | KMS key ARN for AMI encryption |
| `distribution_accounts` | No | Spoke account IDs to share AMI |
| `distribution_regions` | No | Cross-region distribution map |
| `github_org` | Yes | GitHub org/user |
| `github_repo` | Yes | Repository name |
| `allowed_branches` | No | `["main"]` — branches trusted for OIDC |
| `allow_pull_requests` | No | `true` — allow PR plans to assume role |
| `create_oidc_provider` | No | `true` unless provider already exists in account |

**Critical:** `subnet_id` **must have SSM VPC endpoints** (`com.amazonaws.<region>.ssm`, `ssm-messages`, `ec2messages`) or NAT/IGW egress. Image Builder controls instances via SSM only — no SSH/RDP.

---

## Architecture Flow

```
GitHub Actions (OIDC) → Terraform Apply → Image Builder Resources
                                                          ↓
                              ┌─────────────────────────────┴──────────┐
                              ▼                                        ▼
                        Image Pipeline                              EventBridge
                              ↓                                        ↓
                        Build Instance                           Lambda
                     (Windows Updates                              ↓
                     → CIS Hardening                      Update SSM Param
                     → Install Agents                       Publish SNS
                     → Pester Tests)                    (Downstream reads this)
                              ↓
                        Golden AMI
                              ↓
                     Cross-Account/Region Copy
```

---

## Component Order (recipe.tf)

Order matters — components run sequentially:
1. **windows-updates** — Install latest Windows patches first
2. **cis-hardening** — Apply CIS benchmark (requires patched base)
3. **agent-install** — SSM Agent + CloudWatch Agent (needs hardening first)
4. **validation-test** — Pester tests run in separate test phase

---

## Common Tasks

### Add a new Image Builder component
1. Create `golden-image-windows/components/new-component.yaml`
2. Add `aws_imagebuilder_component` resource in `recipe.tf`
3. Add component to `aws_imagebuilder_image_recipe` component list (order matters)
4. Push to main → `golden-image-terraform.yml` applies → `golden-image-build.yml` triggers build

### Update Lambda function
1. Edit `golden-image-windows/lambda/index.py`
2. Rebuild zip: `cd golden-image-windows/lambda && zip -j update_ssm_param.zip index.py`
3. Commit → workflow rebuilds and deploys

### Add cross-account distribution
1. Add account IDs to `distribution_accounts` in terraform.tfvars
2. For cross-region: add entries to `distribution_regions` map
3. Ensure KMS key policy allows cross-account `kms:Decrypt` or use per-region keys with grants

### Trigger manual build
```bash
# Via GitHub Actions UI (workflow_dispatch) or CLI:
aws imagebuilder start-image-pipeline-execution \
  --image-pipeline-arn $(terraform output -raw pipeline_arn)
```

### Consume golden AMI downstream
```hcl
data "aws_ssm_parameter" "golden_ami" {
  name = "/golden-images/golden-win2022/latest-ami-id"
}

resource "aws_instance" "example" {
  ami           = data.aws_ssm_parameter.golden_ami.value
  instance_type = "t3.large"
}
```

---

## Known Gaps / Future Work (from README)

- **Domain join**: No AD/Azure AD join component — typically done at launch via SSM Association
- **EDR/AV agent**: `agent-install.yaml` has placeholder — integrate real agent installer
- **Cross-account KMS grants**: Not automated; add if spoke accounts are in different Org or using different keys
- **Multi-version**: Duplicate module with different `name_prefix` + `base_image_arn` per OS version

---

## Important Notes

1. **First apply is manual** — The OIDC role this module creates is what GitHub Actions uses to apply it. Bootstrap once with your own credentials, then CI takes over.

2. **One OIDC provider per account** — If `token.actions.githubusercontent.com` already exists (e.g., from Terraform-Drift-Detection), set `create_oidc_provider = false` and pass its ARN.

3. **SSM Parameter is source of truth** — Never hardcode AMI IDs. Downstream Terraform reads `/golden-images/<name_prefix>/latest-ami-id`.

4. **Logs retention** — S3 bucket has 180-day lifecycle; adjust in `infrastructure-configuration.tf` if needed.

5. **Schedule** — Default cron: `cron(0 18 ? * SAT#2 *)` (2nd Saturday ~1 week after Patch Tuesday). Adjust `schedule_cron` variable.