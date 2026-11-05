# ADR 0008: The core of Spry on Google Cloud, and what stays on AWS

- **Status:** Accepted 2026-11-05; being built on the `lab9` branch
- **Date:** 2026-11-05
- **Lab:** LAB9, Parts 1–2

## Context

Spry runs on AWS (Labs 4–7): a static Next.js export on S3 + CloudFront, the
FastAPI API on Lambda behind a function URL, Aurora Serverless v2 in a private
VPC, Cognito sign-in, a weekly report (EventBridge Scheduler → Lambda → S3 →
Lambda → SES) and an agenda parser (Lambda → Bedrock). LAB9 asks what it takes
to run the same system on Google Cloud, and to move the core — frontend, API,
database — to the project `spry-taras-2026` in `us-central1`.

What the code already gives us:

- **The frontend is a static export** (`NEXT_OUTPUT=export`, `trailingSlash`),
  so any static host serves it. `NEXT_PUBLIC_API_BASE_URL` is read at build time;
  an empty value makes every call relative (`/api/v1/...`).
- **The API is a plain ASGI app.** Only `app/lambda_handler.py` (Mangum) and
  `Dockerfile.lambda` are Lambda-specific. `backend/Dockerfile` runs uvicorn on
  port 8000 and needs no change.
- **Database config is one string,** `DATABASE_URL`
  (`postgresql+asyncpg://…`). asyncpg accepts a Unix socket directory as
  `?host=/cloudsql/<connection-name>`, which is what Cloud Run mounts.
- **Auth is verified in the API,** not at the edge: every `/api/v1/*` route
  needs a Cognito *access token*, checked against the pool's JWKS (fetched over
  the internet when `COGNITO_JWKS` is empty). Nothing in the check depends on
  where the API or the site runs. Only the browser side does: the frontend signs
  in through Cognito's managed login (authorization code + PKCE), so the new
  site origin must be in the app client's callback and logout URLs.
- `/health` runs `SELECT 1` against the database without a token.

## Decision

### Service by service

| Spry on AWS | On Google Cloud | Decision for Spry | Why |
|---|---|---|---|
| S3 + CloudFront (Free plan) + WAF, static frontend | Firebase Hosting | **Replace** | Free plan, CDN and certificate included, and a rewrite of `/api/**` to Cloud Run gives one origin and no CORS, as CloudFront did. No WAF; acceptable for a lab. |
| Lambda + function URL, FastAPI | Cloud Run | **Replace** | Runs the existing `backend/Dockerfile` unchanged; scales to zero (min instances 0). Mangum and `Dockerfile.lambda` stay in the repo for AWS, unused here. |
| ECR | Artifact Registry | **Replace** | One Docker repository, cleanup policy keeps the last 2 images to stay under the 0.5 GB free tier. Images are built by **Cloud Build** (`gcloud builds submit`), not pushed from the laptop: only `backend/` (a few hundred KB) is uploaded. |
| Aurora Serverless v2, 0–1 ACU, pauses | Cloud SQL for PostgreSQL, db-f1-micro | **Replace**, stopped when not in use | See *The database* below. |
| DynamoDB | Firestore | **Drop** (not used) | Spry is relational; see below. |
| Cognito user pool + Google | Identity Platform | **Keep Cognito** (multicloud), Identity Platform is the stretch goal | The API's token check works unchanged from Cloud Run; the only change is two callback/logout URLs on the AWS side. Moving users would mean a new `sub` for everyone and a new owner id on every meeting. |
| EventBridge Scheduler | Cloud Scheduler | **Keep on AWS** (stretch) | The weekly report is not part of the core. |
| SQS | Pub/Sub (push to Cloud Run) | **Keep on AWS** (stretch) | Same. Pub/Sub push is the closer fit to "SQS → Lambda". |
| S3 event → Lambda | Cloud Storage + Eventarc → Cloud Run | **Keep on AWS** (stretch) | Same. |
| SES | no Google service | **Keep SES** | See *E-mail* below. |
| Bedrock (Claude) | Vertex AI (Gemini, Claude via Model Garden) | **Keep on AWS** (stretch) | The trial credit does not pay for Claude on Vertex, and the parser already works. |
| SSM / Secrets Manager | Secret Manager | **Replace** | Holds the database URL with the Terraform-generated password; Cloud Run reads it as an env var. |
| CloudWatch Logs | Cloud Logging | **Replace** (automatic) | Cloud Run's stdout goes there; within the 50 GiB free tier. |
| IAM roles | Service accounts + IAM roles | **Replace** | A Terraform SA (roles below, no Owner/Editor) and a separate runtime SA for Cloud Run; never the default compute SA. |
| Terraform aws provider | Terraform google provider | **Replace**, separate state | `gcp/` with its own HCP Terraform workspace, so one plan cannot break both clouds. |

### The database

| Option | Latency from Cloud Run | Bill (idle month) | Code |
|---|---|---|---|
| Cloud SQL 24/7 | ~1 ms, same region, Unix socket | ≈ $9.40 (compute $7.67 + 10 GB SSD $1.70) | none |
| **Cloud SQL, stopped when not in use** | same while running; the API returns 503 while stopped | ≈ $9.00: $1.70 storage + the public IPv4, ≈ $0.01/h while stopped (see below) | none |
| Firestore | low, serverless | $0 within the daily free quota | rewrite models, repositories, migrations; the weekly report's SQL aggregation too |
| Keep Aurora, call across clouds | ~20–40 ms per query us-central1 → us-east-1, several queries per request; plus Aurora's resume (~15 s) | Aurora ≈ $0.30 + AWS egress $0.09/GB | none, but Aurora is in a private VPC: it would need a public endpoint or a VPN, which undoes Lab 4's network design |

**Chosen: Cloud SQL for PostgreSQL 16, db-f1-micro (Enterprise edition — the
shared-core tiers are not offered on Enterprise Plus), 10 GB SSD, public IP with
no authorised networks (reachable only through the Cloud SQL connector and IAM),
no automated backups (the data is re-creatable from migrations + seed).**

It is started and stopped with `gcloud` (`make gcp-db-start` / `gcp-db-stop`);
Terraform ignores the activation policy, so a plan never restarts a stopped
instance. The code does not change: `DATABASE_URL` only points to a socket
instead of a host.

**Stopping saves less than Part 3's table suggests.** Cloud SQL bills a
public IPv4 address about $0.01 an hour *while the instance is off*. That is
almost the db-f1-micro rate ($0.0105/h), so a stopped instance costs ≈ $9.00 a
month, not $1.70. The fix is a private IP only: a VPC, private services access
and Direct VPC egress from Cloud Run. That needs network roles beyond Part 0
and more resources, which isn't worth it for a lab that lasts days. So for this
lab:

- Stopping is only worth it as a safety switch: it stops the instance taking
  connections.
- **Destroy is the real off switch.** When the lab is over, `terraform destroy`
  in `gcp/` removes the instance, and with it the disk and the IP.
- In a longer-lived environment, switch to a private IP. That makes "stopped
  at night" a real saving (≈ $1.70 a month).

### Loading the data

**Migrations + seed on the empty database, through a Cloud Run job. No
`pg_dump` from Aurora.** Aurora sits in a private VPC with no bastion and no
public endpoint, so a dump would need a temporary EC2 host or a VPN, and it
would wake the cluster. The schema is fully defined by the Alembic migrations,
and the only data worth having is a few demo meetings.

The job `spry-migrate` runs the API image with `RUN_MIGRATIONS_ON_START=true`.
The entrypoint applies `alembic upgrade head`, then runs the job's args:

- by default, `alembic current` (`make gcp-migrate`);
- with a seed, `python -m app.seed <cognito-sub>` (`make gcp-seed owner=…`).

Cognito is kept, so the seeded meetings belong to the same `sub` that signs in
on AWS. The Cloud Run service runs with `RUN_MIGRATIONS_ON_START=false`, so cold
starts don't check migrations.

### E-mail

Not moved. The weekly report stays on AWS and keeps sending through SES, whose
identity is already verified. If the report moves (stretch), the plan is
**SendGrid** (free tier, plain HTTPS API), its API key in **Secret Manager**,
read by the report's Cloud Run service through its own runtime service account
— never in the repository, the image or a Terraform variable file.

### What we do not move, and why

- **Sign-in (Cognito):** migrating users changes every `sub`, and so the
  owner of every meeting. Keeping it costs one callback URL.
- **The weekly report:** five AWS services wired together; moving it is a
  rewrite of its triggers, not of its code. Stretch goal.
- **The agenda parser:** stays on Bedrock; Claude on Vertex AI is not covered by
  the trial credit. The frontend keeps calling its Lambda URL, whose CORS gets
  the Firebase origin.
- **WAF and the custom domain:** the site runs on `*.web.app` for the lab.

## Consequences

- **The API is multicloud for now.** Every signed-in request fetches nothing
  from AWS after the first (JWKS are cached), but sign-in and the parser still
  depend on us-east-1. This is a migration state, not a target.
- **Two Terraform states, two workspaces.** `infra/` (AWS) gets one small
  change: the Firebase origins join Cognito's callback/logout URLs and the
  parser's CORS.
- **Cloud SQL does not pause, and stopping it saves only the compute and not the IP.**
  A forgotten instance costs ≈ $9 a month whether it runs or not. The README
  has the cost of the whole lab (≈ $0.30 a day while the instance exists) and
  the destroy steps.
- **Cloud Build:** the build runs as its own account `spry-build`, which can
  write logs, read the source bucket and push to the `spry` repository, and
  nothing else. Bootstrap creates the account, the bucket and the log role;
  `gcp/` enables the Cloud Build API and grants the push.
- **No service account keys exist.** HCP Terraform reaches GCP through Workload
  Identity Federation, restricted to this organisation's workspace; the laptop
  uses application default credentials.
