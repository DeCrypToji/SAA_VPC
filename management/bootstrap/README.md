# Management Account — Terraform State Bootstrap

Creates the S3 bucket that stores Terraform state for the management account,
using local state only long enough to build it, then migrating that state into
the bucket so it is remote, versioned, encrypted and locked.

## Why a bootstrap?

Terraform must store its state somewhere before it can create anything — but the
secure place for that state (an S3 bucket) is itself infrastructure that
Terraform needs to create. This is the chicken-and-egg problem.

The bootstrap solves it by applying once with **local state**, creating the
bucket, then adding a backend block and migrating the state **into the bucket it
just created**. Local state is a risk (lost laptop = lost state, no locking, no
versioning), so it only exists for that first apply.

## What it creates

| Resource | Purpose |
|---|---|
| `aws_s3_bucket` | The state bucket; name includes the account ID for global uniqueness; `prevent_destroy` enabled |
| `aws_s3_bucket_versioning` | Keeps every previous state version so a corrupted state can be rolled back |
| `aws_s3_bucket_server_side_encryption_configuration` | Encrypts state at rest with SSE-S3 (AES-256) |
| `aws_s3_bucket_public_access_block` | All 4 settings on — the bucket can never be made public |
| `aws_s3_bucket_policy` | Denies any request not made over TLS (`aws:SecureTransport = false`) |

## How it works

```
STEP 1  No backend block ── terraform apply
        state: LOCAL (terraform.tfstate on laptop)
          └──► creates the S3 bucket + its settings

STEP 2  Add backend "s3" block ── terraform init -migrate-state
          └──► state copied INTO the bucket it created

STEP 3  Verify
        S3: bootstrap/terraform.tfstate ✓
        local terraform.tfstate: 0 bytes ✓
        terraform plan: "No changes" ✓
```

## Design decisions

| Decision | Choice | Why | Trade-off accepted |
|---|---|---|---|
| Encryption | SSE-S3 | Free, no key management; access is already controlled by IAM + bucket policy | No independent `kms:Decrypt` gate and no per-decrypt CloudTrail audit that SSE-KMS gives |
| State locking | S3 native (`use_lockfile = true`) | Prevents two concurrent applies corrupting state; no DynamoDB table needed (deprecated method since Terraform 1.10) | Requires Terraform ≥ 1.10 |
| Backend values | Literal strings | The backend is read during `init`, before variables, data sources or resources are evaluated | Bucket name and account ID are duplicated rather than referenced |
| Deletion protection | `prevent_destroy` + versioning | Terraform refuses any plan that destroys the bucket; a versioned bucket can't be deleted until every version is removed | Does **not** stop deletion via console/CLI, or a plan after the resource block itself is removed |
| Account safety | Named `mgmt` profile + `allowed_account_ids` | Terraform refuses to run if credentials point at any other account — prevents silently building a copy in the wrong account | Account ID hardcoded in config |
| Resource ordering | `depends_on` public access block → bucket policy | Avoids S3 `OperationAborted` errors from concurrent writes to the same bucket | One explicit dependency Terraform can't infer itself |
| State location | One state bucket per account | Each account self-contained; workloads credentials never need access into the management account | Two bootstraps to maintain |

## Security controls

- **TLS-only bucket policy** — explicit deny when `aws:SecureTransport` is `false`.
  Proven by sending an HTTP request, which was denied (see Verification).
- **Public access block** — all 4 settings enabled:
  - `block_public_acls` — rejects requests that add public ACLs
  - `ignore_public_acls` — ignores any public ACLs that exist
  - `block_public_policy` — rejects bucket policies that grant public access
  - `restrict_public_buckets` — limits access to AWS principals even if a public policy exists
- **Encryption at rest** — SSE-S3; SSE-C uploads are blocked by AWS default.
- **No secrets in git** — `*.tfstate*`, `.terraform/` and `*.tfvars` are gitignored;
  `.terraform.lock.hcl` is committed to pin provider versions and checksums.

## Prerequisites

- **Terraform ≥ 1.10** — required for S3-native state locking (`use_lockfile`). Built with 1.16.6.
- **AWS provider `~> 6.0`** — any 6.x release, never a breaking 7.0.
- **AWS CLI v2** with a profile named `mgmt` pointing at the management account.
  Confirm before every apply:
```bash
  aws sts get-caller-identity --profile mgmt
```

## Run order (from scratch)

1. Configure credentials: `aws configure --profile mgmt`, then confirm with `aws sts get-caller-identity --profile mgmt`.
2. **Comment out the `backend "s3"` block** — the bucket doesn't exist yet.
3. `terraform init` → `terraform plan` (expect **5 to add**) → `terraform apply`.
4. Restore the backend block, then `terraform init -migrate-state` and answer `yes` to copying existing state.
5. Run the verification checks below.
6. Only once the S3 copy is verified: delete the local `terraform.tfstate` and `terraform.tfstate.backup` (the backup is a full plaintext copy of state).

## Verification

| Command | Proves |
|---|---|
| `aws s3api get-bucket-versioning --bucket $B --profile mgmt` | Versioning `Enabled` |
| `aws s3api get-bucket-encryption --bucket $B --profile mgmt` | `AES256` at rest |
| `aws s3api get-public-access-block --bucket $B --profile mgmt` | All 4 settings `true` |
| `aws s3 ls s3://$B --profile mgmt --endpoint-url http://s3.eu-west-2.amazonaws.com` | **Must fail** — TLS-only policy works |
| `aws s3 ls s3://$B --recursive --profile mgmt` | State file exists in S3 |
| `terraform state list` | All 5 resources still tracked after migration |
| `terraform plan` | `No changes` — code, state and AWS agree |

A failure is a success on the HTTP test: the policy denies unencrypted traffic,
and HTTP is unencrypted, so being denied proves the policy is enforced:

```
AccessDenied ... User: arn:aws:iam::<account-id>:user/EggMan is not authorized
to perform: s3:ListBucket ... with an explicit deny in a resource-based policy
```

Note the user is an admin — the request still fails because an **explicit deny
always overrides any allow**.

## Incidents & lessons

### State migration silently did nothing
- **Symptom:** `terraform init -migrate-state` succeeded but never asked to copy state; the bucket stayed empty.
- **Root cause:** My edits (backend block, `mgmt` profile) never reached the file Terraform was reading — `main.tf` was last modified the day before.
- **How I found it:** The init output was missing the "copy existing state?" prompt and the "Successfully configured the backend" line; `ls -la` timestamps and `grep` confirmed the file was unchanged.
- **Fix / prevention:** Moved the code into one clean directory with `mv` (not `cp`, to avoid duplicates). I now `grep` the file for expected changes before running `init` or `apply`.

### "Variables not allowed" in the backend block
- **Symptom:** `init` failed with `Variables not allowed` on the bucket name.
- **Root cause:** I used `data.aws_caller_identity` inside the backend block. The backend is read during `init`, before any data source is evaluated.
- **How I found it:** The error pointed at the exact line.
- **Fix / prevention:** Literal values only in backend blocks. Also caught a prefix typo (`mgmt-` vs the real `mngm-`), which taught me to copy resource names from AWS, not retype them.

### The $0.90 Systems Manager charge
- **Symptom:** An unexplained Systems Manager line on the bill.
- **Root cause:** A Systems Manager Quick Setup patch policy, created during a demo in May in **eu-central-1**, was running a remediation runbook **every hour** (~750 executions/month) against no instances.
- **How I found it:** Cost Explorer grouped by usage type (505 automation steps) → no executions in eu-west-2 → looped over every region → ~753 executions in Frankfurt → `list-associations` showed the hourly schedule.
- **Fix / prevention:** Deleted the configuration through Quick Setup (the tool that created it), then cleaned up the leftover CloudFormation stack, IAM roles and a 4,000+ version log bucket. Verified `list-associations` returned `[]`. A **region-deny SCP** (planned in the governance layer) would have blocked this from being created outside approved regions.

## Cost

Effectively **$0.00/month** — one state file of ~9 KB plus a handful of API
requests per plan/apply. Kept in the account permanently.

## Known limitations / tech debt

- **Long-lived IAM user access keys** for the `mgmt` profile → replace with IAM Identity Center short-lived credentials once the Organization exists.
- **Another project still runs in the management account**, outside SCP protection → plan to migrate it to its own member account.
- **Deletion protection is Terraform-only** → add a bucket policy deny on `s3:DeleteBucket`, and consider MFA Delete.
- **No lifecycle rule on noncurrent versions** → old state versions accumulate forever (negligible cost at this size, but should be expired).
- **Account ID hardcoded** in the backend block and `allowed_account_ids`.