# SuccessfulSuccess — Meetings

[![Style](https://github.com/dobosevych/SuccessfulSuccess/actions/workflows/style.yml/badge.svg)](https://github.com/dobosevych/SuccessfulSuccess/actions/workflows/style.yml)

A small web app for today's meetings: see what is on today (name, description,
participants) and add a new one from the UI. Built to `SPEC.md`.

- **Frontend** — Next.js (App Router) + shadcn/ui, styled after Canva's visual language
- **Backend** — FastAPI + SQLAlchemy 2 (async) + Alembic
- **Database** — PostgreSQL 17

## Quick start

```bash
cp .env.example .env
docker compose up --build
```

Then open:

| What | URL |
|------|-----|
| App | http://localhost:3000 |
| API docs (Swagger) | http://localhost:8000/docs |
| Health check | http://localhost:8000/health |

The backend applies migrations on start.

### Sign-in (Cognito)

Every page except the login page, and every `/api/v1` endpoint, needs a
signed-in user, and each user sees only their own meetings. Sign-in is an AWS
Cognito user pool (`infra/auth.tf`): email + password, and Google when it is
configured. Even for local development the pool lives in AWS (it is free at
this scale). It is managed by Terraform (see
[Infrastructure: Terraform](#infrastructure-terraform)); `localhost:3000` is
always among its redirect URLs.

```bash
make infra-init        # once: connect infra/ to the HCP Terraform workspace (after terraform login)
make aws-auth-env      # prints COGNITO_* lines: paste them into .env
docker compose up -d   # restart so the API and the frontend pick them up
```

**Google sign-in** (optional): in Google Cloud console create an OAuth client of
type *Web application*. Put its id in `infra/terraform.tfvars` as
`google_client_id`, and its secret in the HCP Terraform workspace as the
sensitive variable `google_client_secret`. Once the change is applied,
`make aws-auth-info` prints the redirect URI
(`https://<prefix>.auth.<region>.amazoncognito.com/oauth2/idpresponse`) to add
to the client's *Authorized redirect URIs*. With `google_client_id` empty the
Google button says Google sign-in is not enabled.

The first time someone signs in, the frontend sends their ID token to
`POST /api/v1/me/sync`, which stores their profile (email, name, picture,
provider, last login) in the `users` table. Meetings reference `users.id`, the
Cognito `sub`.

Demo data is per user: `make seed owner=<sub>` adds a few meetings for today to
that user (their `sub` is on the user's page in the Cognito console, or `id` in
`GET /api/v1/me`).

> **Ports already in use?** Every host port is configurable in `.env`
> (`FRONTEND_PORT`, `BACKEND_PORT`, `POSTGRES_PORT`). If you change the frontend
> or backend port, update `CORS_ORIGINS` and `NEXT_PUBLIC_API_BASE_URL` to match —
> the browser talks to the published host port, not the compose service name.

## Common tasks

```bash
make up          # start the stack
make down        # stop it
make down-v      # stop it and drop the database volume
make test        # backend test suite (creates meetings_test automatically)
make lint        # ruff + eslint
make migrate     # alembic upgrade head
make seed owner=<sub>  # demo meetings for today for one user
make psql        # psql shell against the app database
make help        # everything else
```

## Windows

The same `make` targets work on Windows, with Docker Desktop (WSL 2 backend)
and [Git for Windows](https://git-scm.com/download/win) installed. There is no
need to install GNU make first: `make.cmd` in the repository root runs the
Makefile, and when `make.exe` is missing it offers to install it with winget
(`ezwinports.make`) and carries on.

```powershell
Copy-Item .env.example .env
.\make help        # PowerShell only runs scripts from the current folder with .\
.\make up-build
```

In `cmd.exe`, plain `make help` finds `make.cmd`; once make is installed,
`make help` works everywhere.

Every recipe runs in Git's bash (`C:/Program Files/Git` by default; pass
`GIT_HOME=...` if it is installed elsewhere), so `make test`, `make seed`, the
`aws-*` targets and the rest behave as on macOS and Linux. Inside WSL, plain
`make` works as on Linux.

Things that are already taken care of, and why:

- `.gitattributes` checks every file out with LF line endings. Git on Windows
  converts to CRLF by default, and a CRLF `entrypoint.sh` stops the backend
  container with `exec /app/entrypoint.sh: no such file or directory`. A clone
  made before `.gitattributes` existed keeps its CRLF files until you run
  `git rm --cached -r . && git reset --hard` (this discards local changes).
- File-change events from a Windows folder do not reach the containers, so hot
  reload polls: `WATCHPACK_POLLING` for Next.js, `WATCHFILES_FORCE_POLLING` for
  uvicorn. For faster reloads keep the clone inside WSL rather than on `C:\`.
- Git's bash rewrites arguments that look like paths (`/aws` becomes
  `C:/Program Files/Git/aws`); the Makefile turns that off with
  `MSYS_NO_PATHCONV`.
- Keep `.env` with LF line endings (copying `.env.example` does): `make` reads
  it directly, and a CRLF `.env` leaves a stray `\r` on every value.

## Deploy to AWS

`infra/` holds two kinds of infrastructure code:

- **Terraform** (`*.tf`), applied by HCP Terraform: Cognito sign-in
  (`auth.tf`), the weekly report (`reports.tf`) and the agenda parser
  (`ai.tf`). See [Infrastructure: Terraform](#infrastructure-terraform).
- **CloudFormation** templates, deployed by `make`: `ecr.yml` (image registry),
  `backend.yml` (API and database) and `frontend.yml` (site). Terraform reads
  their outputs.

`make` reads `.env`, so the `aws-*` targets pick up the credentials and
settings from there; `.env` is gitignored, so real keys never reach the
repository. The AWS CLI runs in the `amazon/aws-cli` container, so nothing has
to be installed on the host besides Docker and, for `terraform output`,
Terraform (`AWS=aws make aws-deploy` uses a local CLI instead, which is
noticeably faster).

```
browser ──https──→ CloudFront (optional custom domain) → private S3 bucket (Next.js static export)
   └────https──→ Lambda function URL → Lambda → Aurora Serverless v2 :5432
```

Every resource lives in `AWS_REGION`, **us-east-1** by default, which is also
where CloudFront reads its certificates from. There is no API Gateway or load
balancer: the browser calls the API on its function URL, and FastAPI's CORS
settings allow it.

Every resource carries the tag `PROJECT_NAME=<value of PROJECT_NAME>`: the
templates and the stacks set it, and Terraform's `default_tags` does the same.
Filter by it in Cost Explorer or Resource Groups to see everything the project
owns.

### Infrastructure: Terraform

Sign-in, the weekly report and the agenda parser are written in Terraform in
`infra/` and live in one HCP Terraform workspace, `successfulsuccess-dev`
(organization `ooad-taraskonoval`, working directory `infra`). Nobody applies
them from a laptop. The workspace is connected to this repository
(Settings → Version Control, working directory `infra`), so:

1. Change the `.tf` files or `infra/terraform.tfvars` on a branch, and open a
   pull request.
2. HCP Terraform posts a plan on the pull request. Review the **plan**, not just
   the diff: a `-/+ … # forces replacement` on the user pool or the reports
   bucket loses every account or every report.
3. Merging to `main` starts the apply in HCP Terraform.

`make infra-plan` runs the same plan from your laptop, still in HCP Terraform
(speculative: it can never be applied). `make infra-fmt` formats and validates.
There is no `terraform apply` in the Makefile.

**Credentials.** HCP Terraform has no AWS keys. For every run it gets an OIDC
token and exchanges it for temporary credentials of the IAM role
`hcp-terraform-ooad-taraskonoval` (`TFC_AWS_PROVIDER_AUTH`,
`TFC_AWS_RUN_ROLE_ARN`, environment variables of the workspace). The role and
its OIDC provider come from a small bootstrap folder outside this repository,
with its own local state.

**Variables.** Everything that is not secret is in `infra/terraform.tfvars`.
Three are set on the workspace instead, as Terraform variables:

| Variable | Sensitive | Value |
|----------|-----------|-------|
| `db_password` | yes | The Aurora password, the same as `AWS_DB_PASSWORD` in `.env` |
| `google_client_secret` | yes | The Google OAuth client's secret |
| `reports_email` | no | The verified SES address the report goes from and to |

Sensitive values are hidden in plans, not in the state: the state, kept and
encrypted by HCP Terraform, holds them in plain text, and `DATABASE_URL` is
readable in the report builder's configuration.

**Values from CloudFormation.** Terraform reads the `ecr`, `backend` and
`frontend` stacks with `aws_cloudformation_stack` data sources: the image
repository, the database endpoint, the API function's VPC, subnets and security
group (the report builder joins them), and the site's origins (Cognito's
redirect URLs and the parser's CORS). A new site URL therefore reaches
Cognito with the next HCP run; `make aws-deploy-frontend` says when one is due.

**Code is not Terraform's.** The report builder and the agenda parser run the
backend image, and Terraform ignores their `image_uri`: `make aws-deploy-reports`
and `make aws-deploy-ai` push the image and call `aws lambda
update-function-code`. Everything else about those functions (memory, timeout,
VPC, environment, the parser's model) is Terraform's. The report mailer is the
exception: Terraform zips `backend/app/reports/mailer.py` and deploys it itself.

When a change needs both roads, for example a new environment variable that new
code reads, merge the Terraform change first and deploy the code after it.

| Command | What it does |
|---------|--------------|
| `make infra-init` | Connect `infra/` to the workspace (once, after `terraform login`) |
| `make infra-plan` | Plan in HCP Terraform; never applies |
| `make aws-auth-env` / `make aws-auth-info` | Cognito settings for `.env` / plus the Google redirect URI |
| `make aws-deploy-reports` | New code for the report builder |
| `make report-now [WEEK=2026-W41]` | Queue a report build (default: last week) |
| `make aws-deploy-ai` | New code for the agenda parser; `make aws-ai-url` prints its URL |
| `make aws-reports-logs`, `make aws-ai-logs` | Follow those functions' logs |

The weekly schedule is `schedule_expression` in `infra/terraform.tfvars`
(Monday 07:00, `app_timezone`). To test, set it to `rate(5 minutes)` in a
pull request, then set it back: every run wakes Aurora.

The decision and its trade-offs are in
[ADR 0007](docs/adr/0007-terraform.md).

### One command

```bash
make aws-whoami   # check the credentials work
make aws-deploy   # the backend, the agenda parser, then the frontend built against them
```

`aws-deploy` deploys code into infrastructure that already exists: the
Terraform part comes from HCP Terraform (above). It runs the steps below in
order: the backend checks tokens from the user pool, and the frontend bakes the
API URL, the pool's ids and the parser's URL into its build. Each step can also
run on its own.

The backend Lambda sits in a VPC with no internet access, so it cannot download
the pool's signing keys itself; `aws-deploy-backend` fetches them
(`<issuer>/.well-known/jwks.json`) and passes them in as `COGNITO_JWKS`.

Fill these in `.env` first:

```bash
AWS_ACCESS_KEY_ID=...        # an IAM user, not root access keys
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=us-east-1
PROJECT_NAME=successfulsuccess   # prefixes every resource name, and the PROJECT_NAME tag
AWS_DB_PASSWORD=...          # 8-41 chars, [A-Za-z0-9_-] only; also db_password in the workspace
AWS_CORS_ORIGINS=            # empty: follow the frontend's URLs (* until it exists)
REPORTS_EMAIL=               # optional: lets make aws-deploy-reports check the SES identity
AWS_FRONTEND_DOMAIN=         # optional, e.g. app.example.com
```

### 1. Backend — Lambda function URL, Aurora Serverless v2

```bash
make aws-deploy-backend   # ECR + build & push + create/update the stack + migrate, prints the URL
```

The API runs as a **Lambda function** from a container image
(`backend/Dockerfile.lambda`): the same FastAPI app, adapted to Lambda by
[Mangum](https://github.com/Kludex/mangum) in `app/lambda_handler.py`. Requests
reach it through its **function URL** (`https://<id>.lambda-url.<region>.on.aws`),
Lambda's own public HTTPS endpoint, and that URL is the backend URL the frontend
is built with. FastAPI keeps doing the routing, CORS and error envelope exactly
as it does locally. `backend/Dockerfile` stays the local/compose image.

The database is an **Aurora Serverless v2** PostgreSQL cluster with one
`db.serverless` writer at the smallest size Aurora allows: it scales between
0 and 1 ACU (`DbMinCapacity`, `DbMaxCapacity`) and **pauses after 5 idle
minutes** (also the minimum), so an unused deployment
pays only for storage. The first connection after a pause waits ~15 s while it
resumes; the function's 60 s timeout covers that.

The function sits in the account's **default VPC**, next to the cluster, so the
database is never public: its security group only accepts the function's. The
function needs nothing else on the network, so there is no NAT gateway.

Migrations run in the same function: invoked directly with
`{"action": "migrate"}` it applies them instead of serving a request. Function
URL events never carry that key, so no web request can trigger it.
`make aws-deploy-backend` invokes it after every deploy, so migrations run once
per deploy rather than racing on each cold start.

The first deploy takes ~15 minutes; Aurora is the slow part. It is idempotent —
run it again to ship a new version. The image is passed to the stack by digest,
not by tag, so every push really does update the function. If the stack is
still busy with an earlier update, the target waits for it rather than failing.

| Command | What it does |
|---------|--------------|
| `make aws-url` | Print the API URL (`/docs` for Swagger, `/health` for the check) |
| `make aws-status` | Stack outputs plus the API function's state |
| `make aws-logs` | Follow the function logs from CloudWatch |
| `make aws-migrate` | Apply migrations again on their own |
| `make aws-destroy` | Delete the CloudFormation stacks (asks first — the database goes too); refuses while the Terraform state still holds resources |

The image is built for `AWS_LAMBDA_ARCH` (`x86_64` by default).
`AWS_LAMBDA_ARCH=arm64 make aws-deploy-backend` is ~20% cheaper and builds
natively on Apple Silicon. The image platform follows this variable, so the two
cannot drift apart. The build passes `--provenance=false` because Lambda rejects
the multi-manifest image index that BuildKit otherwise pushes.

### 2. Frontend — S3 + CloudFront

```bash
make aws-deploy-frontend   # create/update the stack, build against the API URL, upload
make aws-frontend-url      # print the site URL
```

The target refuses to run until the backend stack exists. It reads the
backend's function URL from that stack, builds the Next.js **static export** in
Docker with `NEXT_PUBLIC_API_BASE_URL` set to it, syncs the files to a
**private S3 bucket** and invalidates the **CloudFront** distribution in front
of it. The site is served over HTTPS at `https://<id>.cloudfront.net`. A new
distribution takes ~5 minutes to come up.

- The distribution is on CloudFront's **flat-rate Free plan**
  (`AWS::PricingPlanManager::Subscription`): $0 a month for 1M requests and
  100 GB, with no overage charges, WAF and DDoS protection included. The plan
  requires a web ACL of its own, so the stack creates one that allows
  everything. AWS allows 3 Free plans per account and refuses them while the
  account is on the AWS Free Tier; set `AWS_CLOUDFRONT_PLAN=PAY_AS_YOU_GO` there.
  `PricingPlanStatus` in the stack outputs reads `ACTIVE` once it applies.
- The bucket blocks all public access. CloudFront reads it through **origin
  access control**, and the bucket policy admits only this distribution.
- The export is built with `trailingSlash`, so each route is a folder with an
  `index.html` (`/meetings/new/`). A small CloudFront Function maps clean URLs
  onto those files, since S3's REST endpoint has no index documents. Anything
  missing gets the export's `404.html` with a 404 status.
  `output` stays `standalone` for the compose/production image and switches to
  `export` only when `NEXT_OUTPUT=export` is set, which is the deploy target's
  job.
- HTML is uploaded with `no-cache` and the hashed assets with a one-year
  immutable header, and every deploy invalidates `/*`, so a new version shows up
  on the next page load.
- With `AWS_CORS_ORIGINS` empty, the backend allows exactly the frontend's
  origins (the CloudFront URL and the custom domain). On the very first
  `make aws-deploy` the frontend does not exist yet, so the API starts with `*`;
  the frontend step says so, and the next `make aws-deploy-backend` locks it down.

### 3. Custom domain for the frontend (optional)

```bash
# .env
AWS_FRONTEND_DOMAIN=app.example.com

make aws-frontend-cert      # request + DNS-validate the certificate in us-east-1
make aws-deploy-frontend    # attach the domain to the distribution
make aws-deploy-backend     # add the new origin to the API's CORS
```

CloudFront only reads ACM certificates from **us-east-1**, and that is where
everything is deployed. `make aws-frontend-cert` (`infra/certificate.sh`) reuses
an issued or pending certificate for the domain, or requests one, then waits for
DNS validation. If the domain's Route 53 hosted zone is in this account, it
writes the validation record itself, and the frontend stack adds the A/AAAA
alias records pointing at the distribution. Otherwise both print the records
to add at your DNS provider: the validation CNAME, then a CNAME from the domain
to the distribution's `*.cloudfront.net` name.

The API keeps its function URL: a function URL cannot take a custom domain.

### Cost

- **Lambda** — 1M requests and 400,000 GB-seconds a month, always free. The
  function URL costs nothing beyond the invocation.
- **Aurora Serverless v2** is not in the free tier. It bills per ACU-hour while
  awake, nothing for compute while paused, plus storage and I/O. A demo that
  sits idle costs cents a month.
- **CloudFront** — the flat-rate Free plan: $0, 1M requests and 100 GB a month,
  never an overage charge (traffic past it may be slowed, not billed).
  **S3** — 5 GB and 20,000 GETs in the free tier; CloudFront caches most reads.
  ACM certificates are free.
- **ECR** — 500 MB in the free tier; the lifecycle policy keeps five images.

`make aws-destroy` deletes everything, database included, with no snapshot left
behind. Accounts opened after July 2025 get credits instead of the classic free
tier — check your billing console rather than assuming.

### Known trade-offs

- **No custom domain on the API**: function URLs cannot take one. Putting one on
  it would need API Gateway or a second CloudFront distribution in front.
- The database password reaches the function as a plain environment variable.
  Moving it to SSM Parameter Store or Secrets Manager is the first thing to
  harden.
- **Cold starts**: the first request after a few idle minutes waits ~1–2 s while
  Lambda starts the container, and up to ~15 s more if Aurora has paused.
- Every warm instance holds one database connection. Nothing is reserved by
  default (`MaxConcurrency=0`): new accounts have a Lambda concurrency limit of
  10 in total and Lambda refuses to reserve any of it, so that limit is the cap,
  well under the cluster's connection limit. Once the limit is raised, set
  `MaxConcurrency` to keep a spike off the database; requests beyond it get
  HTTP 429. RDS Proxy is the proper fix, and it is not free.
- The function URL is public: FastAPI checks the Cognito access token on every
  `/api/v1` request, but there is no request throttling in front of it beyond
  the concurrency limit.
- Cognito sends its emails (sign-up codes, password resets) itself, capped at 50
  a day. Switch the pool to SES before real traffic.
- Signing up with a password and later with Google under the same email makes
  two separate Cognito users, with separate meetings. Linking them needs a
  pre-sign-up Lambda trigger.
- Deleting the backend stack takes ~20 minutes: Lambda releases its VPC network
  interfaces slowly, and the security groups wait for them.
- One Aurora instance: there is no reader to fail over to.

## API

Base path `/api/v1`. Full schema at `/docs`. Everything under it needs
`Authorization: Bearer <Cognito access token>` (`401` otherwise) and only ever
touches the caller's own meetings: someone else's meeting is a `404`.

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/meetings?date=&q=&limit=&offset=` | Meetings overlapping a day (today by default) |
| `GET` | `/meetings/{id}` | One meeting |
| `POST` | `/meetings` | Create a meeting |
| `PUT` | `/meetings/{id}` | Replace a meeting's details and participants |
| `DELETE` | `/meetings/{id}` | Delete a meeting and its participants |
| `GET` | `/me` | The signed-in user's profile |
| `POST` | `/me/sync` | Store the profile from the user's ID token (after sign-in) |
| `GET` | `/health` | Liveness + database check |

Every error uses one envelope:

```json
{ "error": { "code": "validation_error", "message": "…", "details": [{ "field": "ends_at", "message": "…" }] } }
```

### Time handling

Timestamps are stored in UTC and **served with the application timezone's offset**
(`APP_TIMEZONE`, default `Europe/Kyiv`). "Today" is that timezone's calendar day,
and a meeting is listed if it *overlaps* the day — so a 23:00–00:30 meeting appears
on both days. The UI reads the wall-clock time straight from the offset the API
sent, so every client shows the same time as the day it was listed under.

## Layout

```
backend/    FastAPI app (api → services → repositories → models), Alembic, tests
frontend/   Next.js app, shadcn/ui primitives in components/ui
infra/      Terraform (*.tf, applied by HCP Terraform) and the CloudFormation
            templates behind the aws-* targets
docker-compose.yml
```

## Continuous integration

`.github/workflows/style.yml` runs on every push to `main` and gates style only:

| Job | Runs | Against |
|-----|------|---------|
| Backend — ruff | `ruff check` (GitHub annotations) + `ruff format --diff` | `backend/` |
| Frontend — ESLint | `npm ci` + `npm run lint` | `frontend/` |

Ruff is pinned to the version the backend image ships (0.16.6) and Node matches
the container's Node 22, so CI and local containers agree on what passes.

Reproduce either job locally:

```bash
make lint                                   # both, through the running containers
cd backend  && uvx ruff@0.16.6 check . && uvx ruff@0.16.6 format --diff .
cd frontend && npm ci && npm run lint
```

GitHub Actions does not deploy. The Terraform part of the infrastructure is
planned on every pull request and applied after a merge by HCP Terraform (see
[Infrastructure: Terraform](#infrastructure-terraform)); the code is deployed
with the `aws-deploy-*` targets.

## Development notes

- The backend bind-mounts `./backend`, so `uvicorn --reload` picks up edits live.
- The frontend runs `next dev` in the container with the same bind mount.
- Backend tests run against a real Postgres (`meetings_test`), truncating tables
  between tests; `make test` creates that database if it is missing.
