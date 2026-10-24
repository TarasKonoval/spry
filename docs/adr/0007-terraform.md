# ADR 0007: Sign-in, the weekly report and the agenda parser move to Terraform

- **Status:** Accepted. Migrated by import on 2026-10-24: 36 resources imported,
  3 Lambda permissions re-created, nothing in AWS lost. The plan after the
  migration reads `No changes`.
- **Date:** 2026-10-24
- **Lab:** LAB7, Part 2

## Context

Labs 4–6 added three CloudFormation stacks, `infra/auth.yml` (Cognito),
`infra/reports.yml` (the weekly report) and `infra/ai.yml` (the agenda parser),
deployed from a laptop with `make aws-deploy-*`. They worked, but:

- **They were applied from laptops.** Whoever had keys in `.env` changed
  production; nothing showed what an update would do before it ran, and nothing
  recorded who ran it.
- **The project already reaches beyond AWS.** Sign-in depends on a Google OAuth
  client, and the code lives on GitHub. CloudFormation can describe neither.
- **A second environment is coming,** and with it white-label copies such as
  `prod · rozetka`: one description, many sets of variables.
- **The templates needed workarounds:** the mailer's code was pasted into the
  template by `awk` under CloudFormation's 4096-character inline limit, and the
  reports bucket was named by hand to break a circular dependency between the
  bucket, its notification and the mailer's permission.
- **The resources hold data.** The user pool has every account that ever
  signed up, the bucket every report, and the SES identity a verification
  someone clicked. Re-creating them is not an option.

## Decision

1. **Terraform for the three stacks**, in `infra/*.tf` (`auth.tf`,
   `reports.tf`, `ai.tf`), one root module, AWS provider 6.x. The `ecr`,
   `backend` and `frontend` stacks stay on CloudFormation for now; Terraform
   reads their outputs with `aws_cloudformation_stack` data sources, and the
   Makefile reads Terraform's with `terraform output`.
2. **HCP Terraform runs it.** The state lives in the workspace
   `successfulsuccess-dev`, locked during every run. Plans run on pull requests,
   applies after a merge. There is no `terraform apply` in the Makefile.
3. **No AWS keys in HCP Terraform.** Every run exchanges an OIDC token for
   temporary credentials of the role `hcp-terraform-ooad-taraskonoval`. The
   role and the OIDC provider come from a bootstrap folder outside the
   repository, with a local state, since it has to exist before HCP Terraform
   can do anything.
4. **Terraform owns the shape, the Makefile owns the code.** The report builder
   and the agenda parser run the backend image; Terraform ignores their
   `image_uri` (`lifecycle { ignore_changes = [image_uri] }`), and
   `make aws-deploy-reports` / `make aws-deploy-ai` push the image and call
   `aws lambda update-function-code`. Everything else, including the
   architecture, the environment and the parser's model, is Terraform's.
   The mailer is a single Python file, so Terraform zips
   `backend/app/reports/mailer.py` with `archive_file` and deploys it itself.
5. **Adopt, never re-create.** The resources were imported, not rebuilt
   (below).

### How the migration went

1. Every physical id and output was recorded before anything changed
   (`notes/lab7-ids.md`).
2. `DeletionPolicy: Retain` and `UpdateReplacePolicy: Retain` were added to all
   26 resources. They were applied as change sets reviewed beforehand: only
   static changes to those two attributes, no replacement.
3. The three stacks were deleted. Every resource reported `DELETE_SKIPPED`;
   users (5), reports (4), queues, functions, URL, schedule and the verified SES
   identity were checked before and after, and were identical.
4. `import` blocks handed **36 resources** to Terraform. The four IAM roles
   kept the names CloudFormation generated (`legacy_role_names` in
   `terraform.tfvars`), because a role's name forces replacement.
5. **3 resources were re-created: the Lambda permissions** (the mailer's for
   S3, the parser's two for its public URL). CloudFormation had given them
   generated statement ids, and `statement_id` forces replacement. Re-creating
   them was safe because Terraform added statements with the same action,
   principal and condition *next to* the old ones; only after the apply were
   the old statements removed by hand. There was never a moment without a
   permission, and the parser's URL kept answering.
6. The apply also wrote 3 updates that changed no value: two secrets that
   became marked sensitive, and the app client's `token_validity_units`, which
   an import does not record. The plans were checked against the JSON plan to
   make sure.
7. One plan wanted to **replace the app client**, and with it the managed
   login branding: `generate_secret = false` is not recorded by an import, so
   writing it forced a new client (a new client id, every refresh token
   invalid, the frontend rebuilt). Leaving the argument out fixed it. That is
   why every plan is read before it is applied.

The mailer's code is the one exception kept for the migration: CloudFormation's
zip of the same `mailer.py` has another hash, so the migration ignores
`filename` and `source_code_hash` on the mailer. The next pull request removes
that, and its plan redeploys the identical code once; from then on Terraform
owns it.

## Alternatives considered

- **Stay on CloudFormation.** AWS keeps the state, failed changes roll back by
  themselves, and new services arrive on launch day. But it stops at the edge
  of one AWS account, the preview (change sets) is optional rather than the
  centre of the workflow, and every change still went from a laptop. Fine for
  `ecr`, `backend` and `frontend` for now; they can follow the same import path
  later.
- **AWS CDK.** A real programming language on top, but CloudFormation
  underneath: the same single provider, the same stack mechanics, plus a build
  step and generated templates that a reviewer has to read instead of the
  code. The problem was not the language.
- **OpenTofu.** The open-source fork (MPL) of the same language: these files
  run unchanged with `tofu`. We chose Terraform because the course uses
  HCP Terraform for state, locking, VCS-driven runs and OIDC credentials, and
  Terraform's BSL licence does not limit a project that uses it rather than
  sells it. Switching is a backend change, not a rewrite.
- **Delete the stacks and apply fresh.** Simple, and it would have deleted
  every user account, every report and the SES verification.

## Consequences

**Who can change the infrastructure, and how.** Anyone with access to the
repository opens a pull request; HCP Terraform posts its plan; a reviewer reads
the plan (a `-/+ … forces replacement` on the user pool or the bucket loses data)
and approves; the merge applies it. Nobody needs AWS keys for that. `make
infra-plan` gives the same plan from a laptop and can never be applied. An
apply from a laptop is for emergencies, by someone with workspace admin rights,
and the next plan must show it. Code still ships from `make aws-deploy-*` with
the keys in `.env`; for a change that needs both, the Terraform change merges
first. The bootstrap role has `AdministratorAccess` and trusts every workspace
of the organization: acceptable for the course, the first thing to narrow
(one workspace in the trust condition, and only the services these files use).

**Where the secrets are.** `google_client_secret` and `db_password` are
sensitive variables on the workspace, write-only in its UI, and are not in Git
(`terraform.tfvars` holds no secrets; `reports_email` is a workspace variable
too, to keep a personal address out of the repository). `sensitive = true` only
hides them in plan output. They are in plain text in:

- the **Terraform state** and the **JSON plan** of every run, stored encrypted
  by HCP Terraform but readable by anyone with state access to the workspace;
- **AWS itself:** the Google secret in the Cognito identity provider, the
  database password inside `DATABASE_URL` in the report builder's environment,
  readable by anyone with `lambda:GetFunctionConfiguration`, as on the API
  function;
- **`.env`** on the laptops of whoever deploys code.

`.terraformignore` keeps `.env` out of what a CLI-driven run uploads. Moving
the database password to Secrets Manager, and access to the state to fewer
people, is the next hardening step.

**If HCP Terraform is down.** The application keeps running: HCP Terraform is
not in any request path. Infrastructure changes wait. Code deploys stop too,
because the Makefile reads ids with `terraform output` from the remote state;
the same ids can be read from AWS directly, or from the last
`terraform state pull`, in an emergency. A fix made in the console meanwhile
shows up as drift in the next plan and must be written into the `.tf` files
before that plan is applied, or the apply undoes it. A long outage is handled
by moving the state to another backend (an S3 bucket with locking) from the
latest state version.

**Other consequences.**

- One more tool and one more service to know: plans, imports, `-target` and
  `state rm` for emergencies.
- Terraform has no automatic rollback; a failed apply stops halfway and is fixed
  forward.
- The Lab 5 workaround is gone: the bucket, the mailer's permission and the
  notification are three resources with plain references.
- `prevent_destroy` protects the user pool, the reports bucket, both queues and
  the SES identity; deleting them now takes a reviewed change first, and
  `make aws-destroy` refuses while the Terraform state still holds resources.
- ADR 0006 says to switch the parser's model with `make aws-deploy-ai`; that is
  now `parser_model` in `infra/terraform.tfvars`, through a pull request.
