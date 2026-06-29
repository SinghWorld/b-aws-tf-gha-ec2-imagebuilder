based on the Summary of AWS Resources Created

This Terraform module creates a complete EC2 Image Builder pipeline for building and distributing hardened Windows Server 2022 Golden AMIs. Here's the complete inventory:

---
Core Image Builder Resources

┌───────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────────────────────────┐
│                   Resource                    │                                        Purpose                                        │
├───────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
│ aws_imagebuilder_image_pipeline               │ Orchestrates the full build pipeline (recipe + infra + distribution + schedule)       │
├───────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
│ aws_imagebuilder_image_recipe                 │ Defines what gets built: base AMI + ordered components + block device config          │
├───────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
│ aws_imagebuilder_infrastructure_configuration │ Build/test EC2 environment: instance type, subnet, SG, IAM profile, logging bucket    │
├───────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
│ aws_imagebuilder_distribution_configuration   │ Where the finished AMI goes: regions, target accounts, KMS encryption, launch         │
│                                               │ permissions                                                                           │
├───────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────┤
│ aws_imagebuilder_component (×4)               │ Build components: Windows Updates, CIS Hardening, Agent Install, Validation Tests     │
└───────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────────────────────────┘

---

### **Custom Build Components (YAML → Image Builder Components)**

| Component File | Purpose |
|----------------|---------|
| `components/windows-updates.yaml` | Installs latest Windows Updates at build time |
| `components/cis-hardening.yaml` | Applies CIS Benchmark hardening (disable SMBv1, Guest account, WDigest, enable Firewall) |
| `components/agent-install.yaml` | Installs/validates SSM Agent + CloudWatch Agent |
| `components/validation-test.yaml` | Pester test suite (validates hardening, agents, services, patch state) |

---

### **IAM Resources**

| Resource | Purpose |
|----------|---------|
| `aws_iam_role.imagebuilder_instance_role` | Role assumed by build EC2 instance (SSM + Image Builder managed policies) |
| `aws_iam_role_policy_attachment.ssm_managed_instance_core` | Attaches `AmazonSSMManagedInstanceCore` |
| `aws_iam_role_policy_attachment.imagebuilder_instance_policy` | Attaches `EC2InstanceProfileForImageBuilder` |
| `aws_iam_role_policy_attachment.imagebuilder_ecr_logs` | Attaches `EC2InstanceProfileForImageBuilderECRContainerBuilds` |
| `aws_iam_instance_profile.imagebuilder_profile` | Instance profile attached to build instances |

---

### **Event-Driven Post-Build Automation**

| Resource | Purpose |
|----------|---------|
| `aws_cloudwatch_event_rule.image_state_change` | EventBridge rule: catches `AVAILABLE` / `FAILED` Image Builder events |
| `aws_cloudwatch_event_target.invoke_update_lambda` | Targets the Lambda function |
| `aws_lambda_permission.allow_eventbridge` | Allows EventBridge to invoke Lambda |
| `aws_iam_role.lambda_update_role` | Lambda execution role |
| `aws_iam_role_policy.lambda_update_policy` | Inline policy: SSM PutParameter, ImageBuilder GetImage, SNS Publish, CloudWatch Logs |
| `aws_lambda_function.update_golden_ami_parameter` | Python 3.12 Lambda: updates SSM param with new AMI ID + SNS notification |

---

### **Storage & Logging**

| Resource | Purpose |
|----------|---------|
| `aws_s3_bucket.imagebuilder_logs` | S3 bucket for build/test logs (named `golden-win2022-imagebuilder-logs-<acct-id>`) |
| `aws_s3_bucket_lifecycle_configuration.imagebuilder_logs` | 180-day log expiration |
| `aws_s3_bucket_public_access_block.imagebuilder_logs` | Blocks all public access |

---

### **Parameter Store (Golden AMI Pointer)**

| Resource | Purpose |
|----------|---------|
| `aws_ssm_parameter.golden_ami_latest` | SSM parameter `/golden-images/golden-win2022/latest-ami-id` — always points to latest validated AMI (updated by Lambda post-build) |

---

### **GitHub Actions OIDC Integration**

| Resource | Purpose |
|----------|---------|
| `aws_iam_openid_connect_provider.github` | GitHub OIDC provider (`token.actions.githubusercontent.com`) |
| `aws_iam_role.github_actions` | Role GitHub Actions assumes via OIDC (scoped to specific repo/branches) |
| `aws_iam_role_policy.github_actions_permissions` | Least-privilege inline policy for: Image Builder, EC2, IAM (scoped), S3 (logging bucket), KMS (AMI key), SSM (golden AMI param), Lambda/EventBridge, CloudWatch Logs, SNS |

---

### **Key Inputs (variables.tf)**

| Variable | Required? | Default |
|----------|-----------|---------|
| `name_prefix` | No | `golden-win2022` |
| `aws_region` | No | `us-east-1` |
| `base_image_arn` | No | AWS Windows 2022 base image SSM alias |
| `instance_types` | No | `["t3.large", "t3a.large"]` |
| `subnet_id` | **Yes** | — |
| `security_group_ids` | **Yes** | — |
| `instance_profile_name` | No | `golden-win2022-imagebuilder-profile` |
| `kms_key_id` | **Yes** | — |
| `distribution_accounts` | No | `[]` |
| `distribution_regions` | No | `{}` |
| `schedule_cron` | No | `cron(0 18 ? * SAT#2 *)` (2nd Saturday monthly) |
| `sns_topic_arn` | No | `""` |
| `github_org` | **Yes** (for OIDC) | — |
| `github_repo` | **Yes** (for OIDC) | — |

---

### **Outputs**

| Output | Description |
|--------|-------------|
| `pipeline_arn` | ARN to trigger manual builds from GitHub Actions |
| `recipe_arn` | Image recipe ARN |
| `golden_ami_ssm_parameter_name` | SSM param name for downstream Terraform to consume |
| `logging_bucket` | S3 bucket name for build logs |
| `infrastructure_configuration_arn` | Infra config ARN |
| `distribution_configuration_arn` | Distribution config ARN |
| `github_actions_role_arn` | ARN to put in `AWS_OIDC_ROLE_ARN` GitHub secret |
| `github_oidc_provider_arn` | OIDC provider ARN |

---

### **GitHub Actions Workflows**

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `.github/workflows/golden-image-build.yml` | Push to main (components/), workflow_dispatch, schedule | Triggers pipeline build, polls for completion |
| `.github/workflows/golden-image-terraform.yml` | Push to main (Terraform files) | Runs `terraform plan` → manual approval → `terraform apply` |

---

### **Architecture Summary**

```
┌─────────────────────────────────────────────────────────────────────┐
│                        GITHUB ACTIONS (OIDC)                        │
│  ┌──────────────────┐    ┌──────────────────────────────────────┐  │
│  │  Terraform Apply │───▶│  Creates all AWS resources below    │  │
│  │  (golden-image-  │    │                                      │  │
│  │   terraform.yml) │    │                                      │  │
│  └──────────────────┘    └──────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     EC2 IMAGE BUILDER PIPELINE                      │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────────────┐   │
│  │   Recipe    │──▶│ Infrastructure│──▶│ Distribution Config    │   │
│  │ (components)│   │  Config     │   │ (multi-account/region)   │   │
│  └─────────────┘   └──────────────┘   └──────────────────────────┘   │
│        │                   │                        │               │
│        ▼                   ▼                        ▼               │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  BUILD INSTANCE (t3.large in private subnet w/ SSM access)   │   │
│  │  1. Windows Updates                                          │   │
│  │  2. CIS Hardening                                            │   │
│  │  3. SSM Agent + CloudWatch Agent                             │   │
│  │  4. Validation Tests (Pester)                                │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                              │                                       │
│                              ▼                                       │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  AMI created → copied to target accounts/regions (encrypted) │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    EVENTBRIDGE → LAMBDA → SSM PARAMETER             │
│  Image State Change (AVAILABLE) ──▶ Lambda ──▶ /golden-images/.../  │
│                                                          latest-ami-id│
│                              │                                       │
│                              ▼                                       │
│                        SNS Notification                              │
└─────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    DOWNSTREAM CONSUMERS                             │
│  Terraform modules (ASG, Launch Template, EC2) read AMI from SSM   │
└─────────────────────────────────────────────────────────────────────┘
```

---

### **Required Pre-Requisites (Not Created by This Module)**

You must provide/provision **before** applying:
1. **VPC Subnet** (`subnet_id`) with SSM VPC endpoints or NAT Gateway
2. **Security Groups** (`security_group_ids`) allowing outbound to SSM/S3/KMS
3. **KMS Key** (`kms_key_id`) for AMI encryption
4. **SNS Topic** (`sns_topic_arn`) for notifications (optional but recommended)
5. **Target AWS Account IDs** for cross-account AMI sharing (`distribution_accounts`, `distribution_regions`)
6. **GitHub OIDC** configured (or set `create_oidc_provider = false` + provide existing ARN)

This is a production-ready, enterprise-grade golden image pipeline with automated testing, cross-account distribution, and GitHub OIDC integration.