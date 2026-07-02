# Technical Documentation — Windows Server 2022 Golden Image Pipeline

> **Audience:** Platform engineers, infrastructure security reviewers, and on-call
> operators responsible for building, maintaining, and consuming this pipeline.
>
> **Status:** Living document — update whenever a Terraform resource, OIDC trust
> statement, or workflow contract changes. The `golden-image-windows/` module is
> the single source of truth; this document explains *why* it is shaped that way.

---

## 1. Purpose and Scope

This repository delivers an **enterprise-grade golden image pipeline** for
Microsoft Windows Server 2022. It is designed to fit cleanly into a hub-and-spoke
AWS landing zone: the pipeline runs in a central *image factory* account and
publishes the resulting AMI to one or more spoke accounts and regions, encrypted
with a customer-managed KMS key.

The pipeline covers the full lifecycle of a golden image:

1. **Provision** all required AWS resources as code (Terraform).
2. **Build** the image on a temporary EC2 instance managed by EC2 Image Builder,
   applying Windows Updates, CIS Benchmark hardening, and agent installation in
   a deterministic order.
3. **Validate** the resulting image with a Pester test suite in a separate test
   phase.
4. **Distribute** the image to target accounts and regions, encrypted and tagged.
5. **Publish** the validated AMI ID to SSM Parameter Store so downstream
   Terraform modules (auto scaling groups, launch templates, EC2 workloads)
   never need to hardcode an AMI ID.
6. **Notify** operators through SNS on success and failure.

Continuous integration is driven by **GitHub Actions** using **OpenID Connect
(OIDC)** to assume an AWS IAM role — no long-lived access keys are stored in
GitHub.

---

## 2. High-Level Architecture

The pipeline is composed of four logical zones that interact through well-defined
contracts.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ZONE 1 — EXTERNAL: GitHub Actions                                       │
│   • golden-image-terraform.yml   (plan / apply via OIDC)                 │
│   • golden-image-build.yml       (trigger + poll pipeline execution)     │
└──────────────────────────────────────────────────────────────────────────┘
                                  │ OIDC (short-lived STS token)
                                  ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ ZONE 2 — CONTROL PLANE: Image Factory Account                           │
│   • Terraform-managed resources (this module)                           │
│   • IAM: Image Builder instance role, Lambda role, GitHub Actions role   │
│   • S3: logging bucket, remote-state bucket                             │
└──────────────────────────────────────────────────────────────────────────┘
                                  │ EC2 Image Builder orchestrates
                                  ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ ZONE 3 — BUILD ENVIRONMENT: Temporary EC2 instance                      │
│   • Runs components in order: Updates → CIS → Agents → Validation       │
│   • Streams logs to S3, reports status back over SSM                    │
└──────────────────────────────────────────────────────────────────────────┘
                                  │ snapshot/AMI created, encrypted with KMS
                                  ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ ZONE 4 — DISTRIBUTION + CONSUMPTION                                     │
│   • AMI copied to spoke accounts/regions (launch permissions granted)   │
│   • EventBridge → Lambda → SSM Parameter Store                          │
│   • Downstream Terraform reads AMI ID from SSM                          │
└──────────────────────────────────────────────────────────────────────────┘
```

Source diagrams are maintained in `docs/architecture/` (drawio format).

---

## 3. Repository Layout

```
.
├── .github/workflows/
│   ├── golden-image-build.yml             # Triggers Image Builder pipeline
│   ├── golden-image-terraform.yml         # Plan/apply for Terraform changes
│   └── golden-image-terraform-destroy.yml # Tear-down workflow
├── docs/
│   ├── TECHNICAL_DOCUMENTATION.md         # This document
│   └── architecture/                      # drawio diagrams
├── golden-image-windows/                  # Terraform module (root for state)
│   ├── components/                        # Image Builder component YAMLs
│   │   ├── windows-updates.yaml
│   │   ├── cis-hardening.yaml
│   │   ├── agent-install.yaml
│   │   └── validation-test.yaml
│   ├── lambda/
│   │   ├── index.py                       # Post-build automation handler
│   │   └── update_ssm_param.zip           # Pre-built deployment package
│   ├── scripts/
│   │   ├── bootstrap-sandbox.sh           # One-time sandbox bootstrap
│   │   └── destroybootstrap-sandbox.sh    # Sandbox teardown
│   ├── provider.tf                        # Provider + remote state backend
│   ├── variables.tf                       # Core input variables
│   ├── oidc-variables.tf                  # GitHub OIDC input variables
│   ├── iam.tf                             # Image Builder IAM + instance profile
│   ├── recipe.tf                          # Image recipe + 4 components
│   ├── infrastructure-configuration.tf    # Build env + S3 logging bucket
│   ├── distribution-configuration.tf      # Cross-account/region AMI copy
│   ├── pipeline.tf                        # Image pipeline + SSM parameter
│   ├── eventbridge.tf                     # EventBridge rule + Lambda
│   ├── oidc-github-actions.tf             # GitHub OIDC provider + IAM role
│   ├── outputs.tf                         # Terraform outputs
│   └── terraform.tfvars.example           # Template for terraform.tfvars
└── README.md                              # High-level overview + quick start
```

---

## 4. Terraform Module Reference

### 4.1 Component Order (recipe.tf)

Components run sequentially inside the build phase, with the validation suite
running as a separate test phase. Order matters: each step depends on the
preceding one.

| # | Component            | Phase  | Purpose                                                  |
|---|----------------------|--------|----------------------------------------------------------|
| 1 | `windows-updates`    | Build  | Install the latest Windows patches first                 |
| 2 | `cis-hardening`      | Build  | Apply CIS Benchmark controls on the patched baseline     |
| 3 | `agent-install`      | Build  | Install/validate SSM Agent and CloudWatch Agent          |
| 4 | `validation-test`    | Test   | Pester suite validating hardening, agents, services      |

The image recipe uses `create_before_destroy` so that version bumps do not break
the in-place pipeline reference.

### 4.2 Infrastructure Configuration

Defines the temporary build/test EC2 environment. The instance type list is
configurable (defaults to `t3.large` and `t3a.large`). Logging streams to a
dedicated S3 bucket whose naming follows
`<name_prefix>-imagebuilder-logs-<account-id>`. The bucket has a 180-day
lifecycle rule and full public-access blocking, and is fronted by a bucket
policy that allows the `imagebuilder.amazonaws.com` service principal to write
logs only when invoked from the same account.

### 4.3 Distribution Configuration

Builds the AMI once in the primary region and copies it to:

* The configured list of spoke accounts via `launch_permission.user_ids`.
* Any number of additional regions declared in the `distribution_regions` map.

Each destination receives a launch permission grant and an AMI tag set
inherited from `var.tags` plus `Name` and `BuildSource=EC2ImageBuilder`.

### 4.4 Image Pipeline

The orchestrator ties recipe, infrastructure, and distribution together with
a configurable schedule (default `cron(0 18 ? * SAT#2 *)`, the second Saturday
of the month, roughly one week after Patch Tuesday). The pipeline is enabled
by default. Image tests are enabled with a 90-minute timeout — long enough to
absorb Pester runs on cold instances.

### 4.5 SSM Parameter

`/golden-images/<name_prefix>/latest-ami-id` is the single source of truth for
the validated AMI ID. Terraform creates it with a placeholder value; the
`lifecycle.ignore_changes = [value]` directive ensures that the post-build
automation (EventBridge → Lambda) can update the value without Terraform
fighting back.

### 4.6 Event-Driven Post-Build Automation

* **EventBridge rule** (`<name_prefix>-image-state-change`) matches
  `aws.imagebuilder` events for `AVAILABLE` and `FAILED` image states.
* **Lambda** (`<name_prefix>-update-ssm-param`, Python 3.12) extracts the new
  AMI ID, calls `ssm:PutParameter` to update the SSM pointer, and publishes
  to SNS. On `FAILED`, it publishes a failure notification and deliberately
  does **not** touch the parameter, so the last known-good AMI stays live.
* **Lambda IAM role** has least-privilege permissions on SSM (parameter ARN
  scoped), Image Builder (`GetImage`), SNS (publish), and CloudWatch Logs.

### 4.7 GitHub OIDC Integration

The IAM role assumed by GitHub Actions is fully scoped to this module's
resources:

* **Trust policy** has four statements, each gated on `event_name`:
  1. `push` from `allowed_branches` (default `["main"]`) — drives
     `terraform apply`.
  2. `workflow_dispatch` from `allowed_dispatch_branches` (default `["*"]`)
     — drives manual runs from the Actions UI.
  3. `pull_request` from `allowed_pr_branches` plus the literal
     `:pull_request` suffix for forks — drives `terraform plan` on PRs.
  4. `environment`-scoped jobs, matching the
     `repo:OWNER/REPO:environment:<name>` sub-claim shape, regardless of
     the underlying event. This is required because GitHub overrides the
     sub claim when a job declares an `environment:`.
* **Audience check** (`sts.amazonaws.com`) is enforced in every statement.
* **Permissions** are split into twelve logical statements (Image Builder,
  EC2, IAM pass-role, S3 logs, S3 state, KMS, SSM, Lambda + EventBridge,
  CloudWatch Logs, SNS) — each scoped to the resource ARN where possible
  and to `*` only where Image Builder / Lambda / EventBridge ARNs are not
  knowable at plan time.

### 4.8 Terraform State

State is stored in S3 with **S3-native state locking** (`use_lockfile = true`),
which writes a `.tflock` object via the S3 conditional-writes API. DynamoDB
locking is explicitly disabled (`dynamodb_table = null`) — DynamoDB-based
locking is deprecated upstream. The state bucket is provisioned **out of
band** by `bootstrap-sandbox.sh` because the module cannot manage its own
state bucket (chicken-and-egg).

---

## 5. AWS Resources Created

The complete inventory of AWS resources managed by this module is grouped below
by functional responsibility. The Terraform resource names in parentheses are
the canonical identifiers used in `*.tf` files.

### 5.1 EC2 Image Builder

| Terraform Resource                                 | Purpose                                                                                       |
|----------------------------------------------------|-----------------------------------------------------------------------------------------------|
| `aws_imagebuilder_component.windows_updates`       | Install latest Windows Updates at build time                                                  |
| `aws_imagebuilder_component.cis_hardening`         | Apply CIS Benchmark hardening                                                                 |
| `aws_imagebuilder_component.agent_install`         | Install/validate SSM Agent and CloudWatch Agent                                               |
| `aws_imagebuilder_component.validation_test`       | Pester validation suite (runs in test phase)                                                  |
| `aws_imagebuilder_image_recipe.this`               | Composes the base image with the four components above                                        |
| `aws_imagebuilder_infrastructure_configuration.this` | Build/test environment: instance type, subnet, SG, IAM profile, logging                       |
| `aws_imagebuilder_distribution_configuration.this` | Cross-account/region AMI copy with launch permissions and KMS encryption                      |
| `aws_imagebuilder_image_pipeline.this`             | Orchestrates recipe + infra + distribution, plus schedule and image tests                     |

### 5.2 Storage and Parameter Store

| Terraform Resource                                  | Purpose                                                                          |
|-----------------------------------------------------|----------------------------------------------------------------------------------|
| `aws_s3_bucket.imagebuilder_logs`                   | Build/test logs (180-day lifecycle, public access blocked)                       |
| `aws_s3_bucket_lifecycle_configuration.imagebuilder_logs` | Expire logs after 180 days                                                |
| `aws_s3_bucket_public_access_block.imagebuilder_logs` | Block all public access                                                          |
| `aws_s3_bucket_policy.imagebuilder_logs`            | Allow Image Builder service principal to write logs (in-account only)            |
| `aws_ssm_parameter.golden_ami_latest`               | SSM parameter `/golden-images/<name_prefix>/latest-ami-id` (managed post-build)  |

### 5.3 Identity and Access Management

| Terraform Resource                                            | Purpose                                                                    |
|---------------------------------------------------------------|----------------------------------------------------------------------------|
| `aws_iam_role.imagebuilder_instance_role`                     | EC2 Image Builder instance role (SSM + Image Builder managed policies)      |
| `aws_iam_role_policy_attachment.ssm_managed_instance_core`    | Attaches `AmazonSSMManagedInstanceCore`                                    |
| `aws_iam_role_policy_attachment.imagebuilder_instance_policy` | Attaches `EC2InstanceProfileForImageBuilder`                               |
| `aws_iam_role_policy_attachment.imagebuilder_ecr_logs`        | Attaches `EC2InstanceProfileForImageBuilderECRContainerBuilds`             |
| `aws_iam_role_policy.imagebuilder_logs_access`                | Inline policy: explicit S3 access to the logs bucket                       |
| `aws_iam_instance_profile.imagebuilder_profile`               | Instance profile attached to the build/test instances                      |
| `aws_iam_role.lambda_update_role`                             | Lambda execution role                                                      |
| `aws_iam_role_policy.lambda_update_policy`                    | Inline policy: SSM PutParameter, ImageBuilder GetImage, SNS Publish, Logs  |
| `aws_iam_openid_connect_provider.github`                      | GitHub OIDC provider (`token.actions.githubusercontent.com`)               |
| `aws_iam_role.github_actions`                                 | IAM role assumed by GitHub Actions via OIDC                                |
| `aws_iam_role_policy.github_actions_permissions`              | Least-privilege inline policy (twelve logical statements)                  |

### 5.4 Event-Driven Automation and Notifications

| Terraform Resource                                 | Purpose                                                          |
|----------------------------------------------------|------------------------------------------------------------------|
| `aws_cloudwatch_event_rule.image_state_change`     | Matches Image Builder `AVAILABLE` and `FAILED` state transitions |
| `aws_cloudwatch_event_target.invoke_update_lambda` | Routes the event to the post-build Lambda                        |
| `aws_lambda_permission.allow_eventbridge`          | Allows EventBridge to invoke the Lambda                          |
| `aws_lambda_function.update_golden_ami_parameter`  | Python 3.12: updates SSM parameter, publishes SNS notification   |

---

## 6. GitHub Actions Workflows

### 6.1 `golden-image-terraform.yml` — Plan / Apply

| Job               | When                                | Purpose                                                                                 |
|-------------------|-------------------------------------|-----------------------------------------------------------------------------------------|
| `terraform-plan`  | PR, push to main, workflow_dispatch | `init` → `validate` → `fmt -check` → `plan`; posts plan summary to PR; uploads `tfplan` |
| `terraform-apply` | Push to main only                   | Downloads the plan artifact and runs `terraform apply -auto-approve`                    |

Both jobs run under the `golden-image-shared-services` environment, so a
required-reviewer approval gate can be configured in GitHub.

### 6.2 `golden-image-build.yml` — Trigger Build

Triggers on:

* Push to `main` that touches `golden-image-windows/components/**`.
* Manual dispatch (`workflow_dispatch`).
* Optional weekly schedule (commented as a safety-net trigger).

Steps:

1. Configure AWS credentials via OIDC.
2. Look up the Image Builder pipeline ARN by name.
3. Start a pipeline execution.
4. Poll the resulting image every two minutes for up to 90 minutes, exiting
   on `AVAILABLE` (success), `FAILED`/`CANCELLED`/`DEPRECATED` (failure), or
   timeout.
5. On success, extract the new AMI ID into the job summary. On failure,
   surface the failure reason from `image.state.reason`.

### 6.3 `golden-image-terraform-destroy.yml` — Tear-down

Provides a controlled path to destroy all module-managed resources via
`terraform destroy`. Should be treated with the same care as `terraform apply`
and protected by the same environment approval gate.

---

## 7. Inputs and Outputs

### 7.1 Required Inputs

| Variable               | Description                                                                                |
|------------------------|--------------------------------------------------------------------------------------------|
| `subnet_id`            | Private subnet with SSM VPC endpoints (or NAT/IGW egress). Build instance is launched here |
| `security_group_ids`   | Security groups attached to the build instance                                             |
| `kms_key_id`           | KMS key ARN used to encrypt the resulting AMI snapshot                                     |
| `github_org`           | GitHub organisation/username owning the repository                                         |
| `github_repo`          | Repository name (without org prefix)                                                       |
| `tf_state_bucket`      | S3 bucket holding the Terraform remote state (created out of band)                         |
| `tf_state_region`      | Region of the state bucket                                                                 |

### 7.2 Optional Inputs (Common)

| Variable               | Default                                          | Notes                                              |
|------------------------|--------------------------------------------------|----------------------------------------------------|
| `name_prefix`          | `golden-win2022`                                 | Used as prefix on every resource name              |
| `aws_region`           | `us-east-1`                                      | Primary build region                               |
| `base_image_arn`       | SSM alias ARN for Windows Server 2022 English    | Always resolves to latest AWS-managed patch baseline |
| `instance_types`       | `["t3.large", "t3a.large"]`                      | Build instance types                               |
| `distribution_accounts`| `[]`                                             | Spoke accounts sharing the AMI                     |
| `distribution_regions`| `{}`                                             | Additional regions and their target account lists  |
| `schedule_cron`        | `cron(0 18 ? * SAT#2 *)`                         | Second Saturday of the month                       |
| `sns_topic_arn`        | `""`                                             | Build notifications                                |
| `allowed_branches`     | `["main"]`                                       | Push events that can assume the OIDC role          |
| `allowed_pr_branches`  | `["*"]`                                          | Pull-request events that can run plan              |
| `allowed_dispatch_branches` | `["*"]`                                     | workflow_dispatch events                           |
| `allowed_environments` | `["golden-image-shared-services"]`               | GitHub Environments overriding the OIDC sub claim  |
| `create_oidc_provider` | `true`                                           | Set `false` if the OIDC provider already exists    |

### 7.3 Outputs

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

## 8. Security Model

### 8.1 Identity

* GitHub Actions uses OIDC exclusively; no long-lived AWS keys are stored in
  GitHub secrets.
* The OIDC trust policy is branch-, event-, and environment-scoped. Widening
  `allowed_pr_branches` or `allowed_dispatch_branches` does **not** widen
  who can push to `main` and trigger `terraform apply`.
* All IAM roles follow the principle of least privilege. The Image Builder
  instance role uses AWS-managed policies for SSM/Image Builder plus a
  single inline policy scoped to the logs bucket.
* The GitHub Actions role's inline policy is split into twelve statements,
  each with a clear purpose and tightest possible resource scoping.

### 8.2 Encryption

* AMI snapshots are encrypted with the customer-managed KMS key specified by
  `kms_key_id`.
* Cross-account distribution requires `kms:Decrypt` on that key from the spoke
  accounts (or per-region keys with explicit grants). This is **not**
  automated; if the spoke accounts are in a different AWS Organization or
  use different keys, add explicit grants.
* The S3 logs bucket blocks all public access and grants the Image Builder
  service principal write access only when invoked from the same account
  (`aws:SourceAccount` condition).

### 8.3 Network

* Build instances run in a customer-provided subnet. They must be able to
  reach SSM endpoints — either via NAT/IGW egress or via VPC endpoints for
  `ssm`, `ssmmessages`, and `ec2messages`. Image Builder does not use SSH or
  RDP; control plane communication is SSM-only.
* Public access on the logs bucket is fully blocked.

### 8.4 Operational Posture

* Build instances are terminated on failure (`terminate_instance_on_failure`).
* Build logs are retained for 180 days by default; tune
  `aws_s3_bucket_lifecycle_configuration.imagebuilder_logs` to match your
  audit retention requirements.
* The SSM parameter is updated **only on success**; failed builds leave the
  previous known-good AMI in place, so downstream workloads never get pointed
  at an unvalidated image.

---

## 9. Operational Runbook

### 9.1 First-Time Bootstrap (Local Sandbox)

The `bootstrap-sandbox.sh` script is self-locating and idempotent for a fresh
environment. It performs, in order:

1. Creates the S3 state bucket (with versioning, encryption, public access
   blocking) and KMS key for state encryption.
2. Generates `backend.hcl` and `terraform.tfvars` from prompts.
3. Runs `terraform init -backend-config=backend.hcl`.
4. Runs `terraform apply` to create all module resources.
5. Pushes GitHub secrets (`AWS_OIDC_ROLE_ARN`, `TF_STATE_BUCKET`,
   `TF_STATE_REGION`, `TF_STATE_KEY`, `GOLDEN_IMAGE_SUBNET_ID`,
   `GOLDEN_IMAGE_SG_IDS`, `GOLDEN_IMAGE_KMS_KEY_ARN`,
   `GOLDEN_IMAGE_DISTRIBUTION_ACCOUNTS`, `GOLDEN_IMAGE_SNS_TOPIC_ARN`).

The corresponding `destroybootstrap-sandbox.sh` reverses every step,
including a 7-to-30-day KMS key purge window.

### 9.2 Triggering a Manual Build

```bash
aws imagebuilder start-image-pipeline-execution \
  --image-pipeline-arn "$(terraform output -raw pipeline_arn)"
```

Or use the **Run workflow** button in GitHub Actions on
`golden-image-build.yml`.

### 9.3 Adding a New Image Builder Component

1. Create the YAML in `golden-image-windows/components/`.
2. Add an `aws_imagebuilder_component` resource in `recipe.tf`.
3. Append the new component to the `component {}` list on
   `aws_imagebuilder_image_recipe.this` (order matters).
4. Bump the component `version` and the recipe `version` to trigger the
   immutable update flow.
5. Push to a branch, open a PR; CI will `terraform plan` automatically.
6. Merge to `main` to apply and trigger a new build (the build workflow
   fires because the components directory changed).

### 9.4 Updating the Lambda

1. Edit `golden-image-windows/lambda/index.py`.
2. Rebuild the deployment package:

   ```bash
   cd golden-image-windows/lambda
   zip -j update_ssm_param.zip index.py
   ```

3. Commit. The `golden-image-terraform.yml` workflow rebuilds the package,
   computes the new SHA256, and includes it in `terraform apply`.

### 9.5 Consuming the Golden AMI Downstream

```hcl
data "aws_ssm_parameter" "golden_ami" {
  name = "/golden-images/golden-win2022/latest-ami-id"
}

resource "aws_instance" "example" {
  ami           = data.aws_ssm_parameter.golden_ami.value
  instance_type = "t3.large"
}
```

Never hardcode AMI IDs in launch templates, auto scaling groups, or other
Terraform modules. The SSM parameter is the contract.

---

## 10. Known Gaps and Extension Points

| Gap                                         | Recommended Approach                                                                                          |
|---------------------------------------------|---------------------------------------------------------------------------------------------------------------|
| Domain join                                 | Add a component that joins AD DS / Azure AD at launch via SSM Association, or bake it in if reused widely. Keep the golden image domain-agnostic when possible. |
| EDR/AV agent                                | Replace the placeholder step in `agent-install.yaml` with the real installer, pulling binaries/tokens from S3 or Secrets Manager. |
| Cross-account KMS grants                    | Add explicit `kms:Grant` resources when spoke accounts are in a different Organization or use different keys. |
| Multi-version support                       | Duplicate the module with a different `name_prefix` and `base_image_arn` per OS version. |
| Full CIS coverage                           | Replace the inline controls in `cis-hardening.yaml` with Microsoft's official CIS GPO baseline via `LGPO.exe`, or call a DSC/Ansible pull from your compliance-as-code repo. |
| Approval gates                              | Configure required reviewers on the `golden-image-shared-services` GitHub Environment for plan/apply/destroy. |

---

## 11. Change History

| Date       | Change                                                                                                          |
|------------|-----------------------------------------------------------------------------------------------------------------|
| Initial    | First production version of the pipeline (Terraform-managed Image Builder + GitHub OIDC).                       |
| Subsequent | Switched state locking from DynamoDB to S3-native (`use_lockfile = true`), Terraform 1.10+.                     |
| Subsequent | Hardened OIDC trust policy with explicit environment-scoped statement to support GitHub Environment approval gates. |
| Subsequent | Added Lambda deployment-package hash wiring so Lambda code changes trigger `terraform apply` reliably.          |

---

## 12. References

* AWS EC2 Image Builder documentation — official user guide and API reference.
* AWS IAM OIDC identity providers — trust policy and condition keys.
* Terraform S3 backend with native locking — `use_lockfile` (1.10+).
* GitHub Actions OIDC — token claims (`sub`, `event_name`, `environment`).
* CIS Microsoft Windows Server 2022 Benchmark — hardening controls applied
  in `cis-hardening.yaml`.
