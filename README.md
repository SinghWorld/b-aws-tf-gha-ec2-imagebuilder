# Golden Image Pipeline — Windows Server 2022 (EC2 Image Builder)

An enterprise-pattern golden image pipeline for **Windows Server 2022**, built
on **AWS EC2 Image Builder** and **Terraform**, and automated end-to-end
through **GitHub Actions** using short-lived **OIDC** credentials.

The pipeline is designed to slot into a hub-and-spoke landing zone: images are
built once in a central *image factory* account, validated, encrypted with a
customer-managed KMS key, and distributed to spoke accounts and regions. The
resulting AMI ID is published to **SSM Parameter Store** so downstream
infrastructure code never has to hardcode an AMI ID.

> For a deeper architectural walkthrough, security model, and operational
> runbook, see [`docs/TECHNICAL_DOCUMENTATION.md`](docs/TECHNICAL_DOCUMENTATION.md).

---

## Table of Contents

1. [What This Pipeline Creates](#1-what-this-pipeline-creates)
2. [How It Works](#2-how-it-works)
3. [Prerequisites](#3-prerequisites)
4. [Required Software and Tooling](#4-required-software-and-tooling)
5. [AWS Resources Created](#5-aws-resources-created)
6. [Inputs and Outputs](#6-inputs-and-outputs)
7. [Quick Start](#7-quick-start)
8. [GitHub Actions Integration](#8-github-actions-integration)
9. [Consuming the Golden AMI](#9-consuming-the-golden-ami)
10. [Extending the Pipeline](#10-extending-the-pipeline)
11. [Operational Notes and Known Gaps](#11-operational-notes-and-known-gaps)
12. [References](#12-references)

---

## 1. What This Pipeline Creates

At a glance, the Terraform module provisions and wires together:

* A **GitHub OIDC provider** and a tightly-scoped **IAM role** so GitHub
  Actions can assume AWS credentials without long-lived keys. Trust is scoped
  to a specific repository, branches, and GitHub Environments.
* An **EC2 Image Builder image recipe** built from the latest patched AWS
  Windows Server 2022 base image and an ordered sequence of components:
  Windows Updates → CIS hardening → agent installation → validation tests.
* An **infrastructure configuration** that defines the temporary build and
  test EC2 environment, including a dedicated S3 logging bucket with
  lifecycle rules and public-access blocking.
* A **distribution configuration** that copies the finished AMI to N accounts
  and N regions, encrypted with your KMS key, with launch permissions granted
  automatically.
* An **image pipeline** that orchestrates the recipe, infrastructure, and
  distribution on a monthly, patch-Tuesday-aligned schedule.
* **EventBridge + Lambda** post-build automation that detects successful
  builds, updates the SSM Parameter Store entry with the new AMI ID, and
  publishes an SNS notification.
* **IAM roles** for the build instance, the Lambda function, and the GitHub
  Actions runner — each with least-privilege permissions.

---

## 2. How It Works

```
GitHub Actions (OIDC) ──▶ Terraform Apply ──▶ Image Builder Resources
                                                      │
                                                      ▼
                          ┌───────────────────────────┴────────────────────────┐
                          ▼                                                    ▼
                  Image Pipeline                                       EventBridge Rule
                          │                                                    │
                          ▼                                                    ▼
                 Build/Test EC2 Instance                              Lambda (Python)
                  ┌──────────────────┐                                      │
                  │ 1. Win Updates   │                                      ▼
                  │ 2. CIS Hardening │                          ┌─────────────────────┐
                  │ 3. Agent Install │                          │  Update SSM Param   │
                  │ 4. Pester Tests  │                          │  Publish SNS Alert  │
                  └──────────────────┘                          └─────────────────────┘
                          │                                                    │
                          ▼                                                    ▼
                   Encrypted AMI ──▶ Copy to spoke accounts/regions ◀── Downstream Terraform
                                                                         (reads SSM param)
```

The full architecture diagram (with per-resource labels) is available in
`docs/architecture/architecture-ec2-image-builder.drawio`.

---

## 3. Prerequisites

The Terraform module manages Image Builder, IAM, Lambda, EventBridge, and SSM.
The following resources must already exist before the first `terraform apply`.

### 3.1 AWS Account and Network

| Prerequisite                | Why It Is Required                                                                                                             |
|-----------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| AWS account (image factory) | Hosts the pipeline, IAM roles, build environment, and S3 logging bucket                                                        |
| VPC subnet (`subnet_id`)    | Private subnet with SSM VPC endpoints (`ssm`, `ssmmessages`, `ec2messages`) **or** NAT/IGW egress. Image Builder controls instances exclusively through SSM — no SSH or RDP is used |
| Security group(s)           | Attached to the build instance; allow outbound to SSM, S3, KMS, and Image Builder service endpoints                            |

### 3.2 Cryptography and Notifications

| Prerequisite                | Why It Is Required                                                                                                             |
|-----------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| KMS key (`kms_key_id`)      | Encrypts the resulting AMI snapshot. Key policy must allow `kms:CreateGrant` for Image Builder, and `kms:Decrypt` for spoke accounts that consume the AMI. For multi-Organisation or per-region key topologies, add explicit cross-account grants. |
| SNS topic (optional)        | Receives build success and failure notifications. Strongly recommended for production use                                       |

### 3.3 Image Distribution

| Prerequisite                   | Why It Is Required                                                                                                          |
|--------------------------------|-----------------------------------------------------------------------------------------------------------------------------|
| Target account IDs             | Spoke accounts that should receive the AMI via `distribution_accounts` and `distribution_regions`                            |
| Cross-region KMS keys/grants   | Required only when distributing to additional regions that use different KMS keys                                            |

### 3.4 Source Control and Identity

| Prerequisite           | Why It Is Required                                                                                                                |
|------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
| GitHub repository      | Hosts the Terraform module and the GitHub Actions workflows. The OIDC role is scoped to `github_org/github_repo`                  |
| GitHub Environment     | Workflows run under `golden-image-shared-services` so an approval gate can be enforced. OIDC trust policy matches this environment explicitly |

### 3.5 Base Image

| Prerequisite     | Why It Is Required                                                                                  |
|------------------|-----------------------------------------------------------------------------------------------------|
| Base image ARN   | SSM alias ARN for the latest patched AWS-managed Windows Server 2022 base. Verify with `aws ssm get-parameters --names /aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base` |

---

## 4. Required Software and Tooling

The following tooling is required on any machine (laptop, CI runner, or
bastion) that plans, applies, or develops against this module.

### 4.1 Local Development Machine

| Tool         | Minimum Version | Purpose                                                                                                            |
|--------------|-----------------|--------------------------------------------------------------------------------------------------------------------|
| Terraform    | **1.10.0**      | Required for S3-native state locking (`use_lockfile = true`). Older versions fall back to deprecated DynamoDB locking |
| AWS CLI      | **v2**          | Authenticate, look up pipeline ARNs, trigger manual builds, retrieve the resulting AMI ID                            |
| `jq`         | **1.6+**        | Parse AWS CLI JSON output in ad-hoc scripts                                                                         |
| `zip`        | any             | Rebuild the Lambda deployment package after editing `lambda/index.py`                                              |
| `bash`       | **4.0+**        | Run the bootstrap and destroy bootstrap scripts                                                                    |
| `git`        | **2.30+**       | Clone the repository and push to remote branches                                                                    |
| OpenSSL      | any             | Compute SHA256 hashes for Lambda source code                                                                        |

### 4.2 CI / CD Environment (GitHub Actions Runners)

The workflows in `.github/workflows/` run on `ubuntu-latest` GitHub-hosted
runners and install the following via actions:

| Tool                              | Version    | Provided By                                  |
|-----------------------------------|------------|----------------------------------------------|
| Terraform                         | 1.11.0     | `hashicorp/setup-terraform@v3`               |
| AWS credentials                   | OIDC token | `aws-actions/configure-aws-credentials@v4`   |
| `aws` CLI                         | latest     | Ubuntu runner base image                     |
| `zip`                             | any        | Ubuntu runner base image                     |

No additional runner setup is required.

### 4.3 AWS Permissions for Local Operators

When applying Terraform locally for the first time (the bootstrap step — see
[Quick Start](#7-quick-start)), the operator's IAM principal needs permission
to create all resources listed in [Section 5](#5-aws-resources-created),
including the IAM roles themselves. Subsequent applies from CI use the OIDC
role described in [Section 6](#6-inputs-and-outputs).

---

## 5. AWS Resources Created

The Terraform module creates the following AWS resources, grouped by
functional responsibility.

### 5.1 EC2 Image Builder

| Terraform Resource                                   | Purpose                                                                 |
|------------------------------------------------------|-------------------------------------------------------------------------|
| `aws_imagebuilder_component.windows_updates`         | Installs the latest Windows Updates                                      |
| `aws_imagebuilder_component.cis_hardening`           | Applies CIS Benchmark hardening                                          |
| `aws_imagebuilder_component.agent_install`           | Installs/validates SSM Agent and CloudWatch Agent                        |
| `aws_imagebuilder_component.validation_test`         | Pester test suite for hardening, agents, services                        |
| `aws_imagebuilder_image_recipe`                      | Composes the base image with the four components in order               |
| `aws_imagebuilder_infrastructure_configuration`     | Build/test environment: instance types, subnet, SG, IAM profile, logs   |
| `aws_imagebuilder_distribution_configuration`       | Cross-account and cross-region AMI copy with launch permissions         |
| `aws_imagebuilder_image_pipeline`                    | Orchestrator with schedule and image tests configuration                |

### 5.2 Storage and Parameter Store

| Terraform Resource                                          | Purpose                                                                |
|-------------------------------------------------------------|------------------------------------------------------------------------|
| `aws_s3_bucket` (imagebuilder logs)                         | Build/test logs with 180-day lifecycle                                 |
| `aws_s3_bucket_lifecycle_configuration`                     | Expire logs after 180 days                                             |
| `aws_s3_bucket_public_access_block`                         | Block all public access on the logs bucket                             |
| `aws_s3_bucket_policy`                                      | Allow Image Builder service principal to write logs (in-account only)  |
| `aws_ssm_parameter` (`/golden-images/<name_prefix>/latest-ami-id`) | Stores the latest validated AMI ID; updated by Lambda post-build |

### 5.3 Identity and Access Management

| Terraform Resource                                       | Purpose                                                                                          |
|----------------------------------------------------------|--------------------------------------------------------------------------------------------------|
| `aws_iam_role` (Image Builder instance)                  | Build instance role with SSM and Image Builder managed policies                                   |
| `aws_iam_role_policy_attachment` × 3                     | `AmazonSSMManagedInstanceCore`, `EC2InstanceProfileForImageBuilder`, `EC2InstanceProfileForImageBuilderECRContainerBuilds` |
| `aws_iam_role_policy` (logs access)                      | Inline policy granting explicit access to the logs bucket                                         |
| `aws_iam_instance_profile`                               | Instance profile attached to the build/test instances                                            |
| `aws_iam_role` (Lambda execution)                        | Lambda execution role                                                                             |
| `aws_iam_role_policy` (Lambda inline)                    | `ssm:PutParameter`, `imagebuilder:GetImage`, `sns:Publish`, CloudWatch Logs                      |
| `aws_iam_openid_connect_provider` (GitHub OIDC)          | `token.actions.githubusercontent.com` provider                                                   |
| `aws_iam_role` (GitHub Actions)                          | Role assumed by GitHub Actions via OIDC                                                          |
| `aws_iam_role_policy` (GitHub Actions inline)            | Twelve least-privilege statements covering Image Builder, EC2, IAM, S3, KMS, SSM, Lambda, EventBridge, CloudWatch Logs, SNS |

### 5.4 Event-Driven Automation

| Terraform Resource                                   | Purpose                                                              |
|------------------------------------------------------|----------------------------------------------------------------------|
| `aws_cloudwatch_event_rule` (image state change)     | Matches Image Builder `AVAILABLE` and `FAILED` state transitions     |
| `aws_cloudwatch_event_target` (invoke Lambda)        | Routes the matched event to the post-build Lambda                    |
| `aws_lambda_permission` (EventBridge invoke)         | Grants EventBridge permission to invoke the Lambda                   |
| `aws_lambda_function` (update SSM parameter)         | Python 3.12 handler that updates SSM and publishes to SNS            |

### 5.5 Resource Counts Summary

| Service                     | Approximate Resource Count |
|-----------------------------|----------------------------|
| EC2 Image Builder           | 8                          |
| S3                          | 4 (bucket + 3 supporting)  |
| SSM                         | 1                          |
| IAM                         | ~11                        |
| Lambda                      | 1                          |
| EventBridge                 | 2                          |
| **Total**                   | **~27**                    |

---

## 6. Inputs and Outputs

### 6.1 Required Inputs

| Variable             | Description                                                                                       |
|----------------------|---------------------------------------------------------------------------------------------------|
| `subnet_id`          | Private subnet with SSM VPC endpoints or NAT/IGW egress                                            |
| `security_group_ids` | Security groups for the build instance                                                             |
| `kms_key_id`         | KMS key ARN for AMI encryption                                                                     |
| `github_org`         | GitHub organisation or username                                                                   |
| `github_repo`        | Repository name (without org prefix)                                                               |
| `tf_state_bucket`    | S3 bucket for Terraform remote state (created out of band by `bootstrap-sandbox.sh`)              |
| `tf_state_region`    | Region of the state bucket                                                                         |

### 6.2 Common Optional Inputs

| Variable                    | Default                                          | Notes                                              |
|-----------------------------|--------------------------------------------------|----------------------------------------------------|
| `name_prefix`               | `golden-win2022`                                 | Prefix on every resource name                      |
| `aws_region`                | `us-east-1`                                      | Primary build region                               |
| `base_image_arn`            | Windows Server 2022 English base (SSM alias)     | Always resolves to the latest AWS-managed patch baseline |
| `instance_types`            | `["t3.large", "t3a.large"]`                      | Build instance types                               |
| `distribution_accounts`     | `[]`                                             | Spoke accounts that receive the AMI                |
| `distribution_regions`      | `{}`                                             | Additional regions and their target account lists  |
| `schedule_cron`             | `cron(0 18 ? * SAT#2 *)`                         | Second Saturday of each month                      |
| `sns_topic_arn`             | `""`                                             | Build notifications                                |
| `allowed_branches`          | `["main"]`                                       | Push events that can assume the OIDC role          |
| `allowed_pr_branches`       | `["*"]`                                          | Pull-request events that can run `terraform plan`  |
| `allowed_dispatch_branches` | `["*"]`                                          | `workflow_dispatch` events                         |
| `allowed_environments`      | `["golden-image-shared-services"]`               | GitHub Environments overriding the OIDC sub claim  |
| `create_oidc_provider`      | `true`                                           | Set `false` if the OIDC provider already exists    |

### 6.3 Outputs

| Output                              | Description                                                              |
|-------------------------------------|--------------------------------------------------------------------------|
| `pipeline_arn`                      | Image Builder pipeline ARN (used to trigger manual builds)               |
| `recipe_arn`                        | Image recipe ARN                                                         |
| `infrastructure_configuration_arn`  | Infrastructure configuration ARN                                         |
| `distribution_configuration_arn`    | Distribution configuration ARN                                           |
| `golden_ami_ssm_parameter_name`     | SSM parameter name (consume from downstream Terraform)                   |
| `logging_bucket`                    | S3 logging bucket name                                                   |
| `github_actions_role_arn`           | IAM role ARN for GitHub Actions OIDC (`AWS_OIDC_ROLE_ARN` secret)        |
| `github_oidc_provider_arn`          | OIDC provider ARN (only when `create_oidc_provider = true`)              |

---

## 7. Quick Start

### 7.1 First-Time Bootstrap

The `bootstrap-sandbox.sh` script handles the chicken-and-egg problem of
bootstrapping a Terraform module that creates its own state backend and its
own CI role. It is idempotent for a fresh environment.

```bash
# From the repository root:
bash golden-image-windows/scripts/bootstrap-sandbox.sh
```

The script will:

1. Prompt for AWS credentials, region, GitHub org/repo, and other required values.
2. Create the S3 state bucket (with versioning, encryption, public access blocking).
3. Create the KMS key used to encrypt the state bucket.
4. Generate `backend.hcl` and `terraform.tfvars` from your inputs.
5. Run `terraform init -backend-config=backend.hcl`.
6. Run `terraform apply` to create all module resources.
7. Push the required GitHub secrets to your repository.

### 7.2 Manual First Apply (alternative to bootstrap)

If you prefer to run `terraform apply` by hand:

```bash
cd golden-image-windows
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your subnet, SG, KMS key, account IDs, GitHub org/repo

terraform init -backend-config=backend.hcl   # values for bucket/region/key
terraform validate
terraform fmt -check -recursive
terraform plan
terraform apply
```

The schedule only triggers **future** runs, so kick off the first build
manually:

```bash
aws imagebuilder start-image-pipeline-execution \
  --image-pipeline-arn "$(terraform output -raw pipeline_arn)"
```

### 7.3 Tearing Down

```bash
bash golden-image-windows/scripts/destroybootstrap-sandbox.sh
```

This script runs `terraform destroy`, purges the KMS key (respecting the
mandatory 7-to-30-day deletion window), removes the GitHub secrets, and
cleans up local files.

---

## 8. GitHub Actions Integration

The repository ships with three workflows in `.github/workflows/`.

| Workflow                                | Trigger                                                       | Purpose                                                                                  |
|-----------------------------------------|---------------------------------------------------------------|------------------------------------------------------------------------------------------|
| `golden-image-terraform.yml`            | PR, push to main, `workflow_dispatch`                         | `terraform plan` on PRs; `terraform apply -auto-approve` on push to main                 |
| `golden-image-build.yml`                | Push to main (component changes), `workflow_dispatch`, schedule | Starts an Image Builder pipeline execution and polls until terminal state               |
| `golden-image-terraform-destroy.yml`    | `workflow_dispatch`                                           | Controlled tear-down of all module resources                                             |

### 8.1 Required GitHub Secrets

The workflows read the following secrets. They are pushed automatically by
`bootstrap-sandbox.sh`; you can also configure them manually.

| Secret                                | Purpose                                                                |
|---------------------------------------|------------------------------------------------------------------------|
| `AWS_OIDC_ROLE_ARN`                   | IAM role ARN assumed via OIDC                                          |
| `TF_STATE_BUCKET`                     | S3 bucket holding the Terraform remote state                           |
| `TF_STATE_REGION`                     | Region of the state bucket                                             |
| `TF_STATE_KEY`                        | Object key of the state file (defaults to `golden-image-windows/terraform.tfstate`) |
| `GOLDEN_IMAGE_SUBNET_ID`              | Build instance subnet                                                  |
| `GOLDEN_IMAGE_SG_IDS`                 | JSON array of security group IDs                                       |
| `GOLDEN_IMAGE_KMS_KEY_ARN`            | KMS key ARN for AMI encryption                                         |
| `GOLDEN_IMAGE_DISTRIBUTION_ACCOUNTS`  | JSON array of spoke account IDs                                        |
| `GOLDEN_IMAGE_SNS_TOPIC_ARN`          | SNS topic ARN for build notifications                                  |

### 8.2 OIDC Trust Policy

The GitHub Actions role's trust policy uses four statements, each gated on
`event_name` (and a fifth for GitHub Environments):

* **push** from `allowed_branches` (default `["main"]`) — drives `terraform apply`.
* **workflow_dispatch** from `allowed_dispatch_branches` (default `["*"]`) —
  manual workflow runs.
* **pull_request** from `allowed_pr_branches` plus the literal `:pull_request`
  suffix for forks — drives `terraform plan` on PRs.
* **environment** — when a job declares an `environment:` GitHub overrides the
  OIDC sub claim to `repo:OWNER/REPO:environment:<name>`; this statement
  matches that shape regardless of the underlying event.

The audience check (`sts.amazonaws.com`) is enforced in every statement.

---

## 9. Consuming the Golden AMI

Downstream infrastructure should always read the AMI ID from SSM Parameter
Store — never hardcode an AMI ID in a launch template, auto scaling group,
or EC2 resource.

```hcl
data "aws_ssm_parameter" "golden_ami" {
  name = "/golden-images/golden-win2022/latest-ami-id"
}

resource "aws_instance" "example" {
  ami           = data.aws_ssm_parameter.golden_ami.value
  instance_type = "t3.large"
}
```

The parameter is updated **only on successful builds**. Failed builds leave
the previous known-good AMI in place, so downstream workloads always point at
a validated image.

---

## 10. Extending the Pipeline

### 10.1 Adding a New Image Builder Component

1. Create the component YAML in `golden-image-windows/components/`.
2. Add an `aws_imagebuilder_component` resource in `recipe.tf`.
3. Append the new component to the `component {}` list on
   `aws_imagebuilder_image_recipe.this`. Order matters — components run
   sequentially in the build phase.
4. Bump the component `version` and the recipe `version`.
5. Open a PR; CI will run `terraform plan` automatically.
6. Merge to `main` to apply the changes. The build workflow fires because
   the components directory changed.

### 10.2 Updating the Lambda Function

```bash
cd golden-image-windows/lambda
# Edit index.py
zip -j update_ssm_param.zip index.py
git add update_ssm_param.zip
git commit -m "feat(lambda): update SSM notification format"
git push
```

The `golden-image-terraform.yml` workflow rebuilds the package, computes the
new SHA256 hash, and passes it to `terraform apply` so the Lambda is updated
deterministically.

### 10.3 Adding Cross-Account or Cross-Region Distribution

* Append account IDs to `distribution_accounts` in `terraform.tfvars` for
  same-region sharing.
* Add entries to `distribution_regions` for additional regions. Each entry
  takes its own `target_account_ids` and `ami_name`.
* Ensure the KMS key policy grants `kms:Decrypt` to the destination accounts,
  or use per-region KMS keys with explicit grants.

### 10.4 Tightening the OIDC Trust Policy

The defaults are intentionally permissive (`["*"]`) so PR-based plans and
manual triggers work out of the box for feature branches. Once your team
settles on a branching model, narrow `allowed_pr_branches` and
`allowed_dispatch_branches` to specific prefixes (e.g. `release/*`,
`hotfix/*`). Push events remain restricted to `allowed_branches` regardless
of those settings, so tightening them does **not** widen who can trigger
`terraform apply`.

---

## 11. Operational Notes and Known Gaps

### 11.1 Operational Notes

* **First apply is manual.** The OIDC role this module creates is what
  GitHub Actions uses to apply it. Bootstrap once with your own credentials,
  then hand off to CI.
* **One OIDC provider per AWS account per URL.** If you already created
  `token.actions.githubusercontent.com` for another pipeline, set
  `create_oidc_provider = false` and pass its ARN via
  `existing_oidc_provider_arn`.
* **State locking.** Uses Terraform 1.10+ S3-native locking (`use_lockfile`).
  DynamoDB-based locking is intentionally disabled because it is deprecated
  upstream.
* **Log retention.** Defaults to 180 days. Adjust
  `aws_s3_bucket_lifecycle_configuration.imagebuilder_logs` to match your
  audit retention requirements.
* **SSM parameter is the contract.** Downstream Terraform reads
  `/golden-images/<name_prefix>/latest-ami-id`. Never hardcode AMI IDs.

### 11.2 Known Gaps

| Gap                                         | Recommended Approach                                                                                          |
|---------------------------------------------|---------------------------------------------------------------------------------------------------------------|
| Domain join                                 | Add a component for AD DS / Azure AD join, or perform it at launch via SSM Association. Keep the golden image domain-agnostic when possible |
| EDR / AV agent                              | Replace the placeholder step in `agent-install.yaml` with the real installer, pulling binaries/tokens from S3 or Secrets Manager |
| Cross-account KMS grants                    | Add explicit `kms:Grant` resources when spoke accounts are in a different Organisation or use different keys   |
| Multi-version support                       | Duplicate the module with a different `name_prefix` and `base_image_arn` per OS version                        |
| Full CIS coverage                           | Replace inline controls in `cis-hardening.yaml` with Microsoft's official CIS GPO baseline via `LGPO.exe`, or call a DSC / Ansible pull from your compliance-as-code repo |

---

## 12. References

* [`docs/TECHNICAL_DOCUMENTATION.md`](docs/TECHNICAL_DOCUMENTATION.md) —
  Detailed architecture, security model, and operational runbook.
* [`docs/architecture/`](docs/architecture/) — drawio architecture diagrams.
* AWS EC2 Image Builder — user guide and API reference.
* AWS IAM OIDC identity providers — trust policy and condition keys.
* Terraform S3 backend with native locking — `use_lockfile` (Terraform 1.10+).
* GitHub Actions OIDC — token claims (`sub`, `event_name`, `environment`).
* CIS Microsoft Windows Server 2022 Benchmark — controls applied in
  `cis-hardening.yaml`.
