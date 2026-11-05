# Lab 9, Part 3: Spry's core on AWS and on Google Cloud, what it costs

List prices in USD, without tax, 730 hours a month, checked 2026-11-05:
- AWS: us-east-1 (as in Lab 4).
- Google Cloud: us-central1, the prices in the Lab 9 text.

Every number below comes from [`costs.py`](costs.py). Change an assumption
there and re-run `python3 docs/cost/costs.py`.

## The setup on each side

| Piece | AWS (Lab 4, Stage 2) | Google Cloud (Lab 9, `gcp/`) |
|---|---|---|
| Frontend + CDN + HTTPS | S3 + CloudFront, Free plan (WAF included) | Firebase Hosting |
| API | Lambda, 512 MB, function URL | Cloud Run, 1 vCPU / 512 MiB, request-based billing, min 0 |
| Database | Aurora Serverless v2, 0–1 ACU, pauses after 300 s idle, ~1 GB | Cloud SQL PostgreSQL db-f1-micro, 10 GB SSD, public IP |
| Registry | ECR, 5 images kept | Artifact Registry, 2 images kept |
| Sign-in, report, parser | Cognito, Scheduler/SQS/S3/SES, Bedrock | the same AWS services (ADR 0008), so left out of both columns |

## The result

| Profile | AWS | GCP, Cloud SQL always on | GCP, stopped when idle | Cheaper |
|---|---|---|---|---|
| Nobody | $0.18 | $9.37 | $9.00 | AWS |
| Class demos (10 × 2 h) | $1.46 | $9.37 | $9.01 | AWS |
| Office hours (8 h × 22 days) | $11.10 | $9.37 | $9.09 | Google Cloud |
| Busy around the clock | $45.36 | $11.60 | $11.60 | Google Cloud |

"Stopped when idle" means Cloud SQL runs only during the active hours. It
still pays its 10 GB SSD, plus **$0.01/h for the public IPv4 while it is
stopped** (ADR 0008). That is why it saves so little compared with the
$1.70 the Lab 9 reference table assumes for a stopped instance.

## Line by line

**Nobody**

| Line | AWS | GCP, always on | GCP, stopped when idle |
|---|---|---|---|
| Database compute | $0.00 | $7.67 | $7.30 |
| Database storage + I/O | $0.10 | $1.70 | $1.70 |
| API | $0.00 | $0.00 | $0.00 |
| Frontend + CDN | $0.00 | $0.00 | $0.00 |
| Registry | $0.08 | $0.00 | $0.00 |
| **Total** | **$0.18** | **$9.37** | **$9.00** |

**Class demos (10 × 2 h)**

| Line | AWS | GCP, always on | GCP, stopped when idle |
|---|---|---|---|
| Database compute | $1.25 | $7.67 | $7.31 |
| Database storage + I/O | $0.13 | $1.70 | $1.70 |
| API | $0.00 | $0.00 | $0.00 |
| Frontend + CDN | $0.00 | $0.00 | $0.00 |
| Registry | $0.08 | $0.00 | $0.00 |
| **Total** | **$1.46** | **$9.37** | **$9.01** |

**Office hours (8 h × 22 days)**

| Line | AWS | GCP, always on | GCP, stopped when idle |
|---|---|---|---|
| Database compute | $10.67 | $7.67 | $7.39 |
| Database storage + I/O | $0.35 | $1.70 | $1.70 |
| API | $0.00 | $0.00 | $0.00 |
| Frontend + CDN | $0.00 | $0.00 | $0.00 |
| Registry | $0.08 | $0.00 | $0.00 |
| **Total** | **$11.10** | **$9.37** | **$9.09** |

**Busy around the clock**

| Line | AWS | GCP, always on | GCP, stopped when idle |
|---|---|---|---|
| Database compute | $43.80 | $7.67 | $7.67 |
| Database storage + I/O | $1.15 | $1.70 | $1.70 |
| API | $0.33 | $2.24 | $2.24 |
| Frontend + CDN | $0.00 | $0.00 | $0.00 |
| Registry | $0.08 | $0.00 | $0.00 |
| **Total** | **$45.36** | **$11.60** | **$11.60** |

## Assumptions

- **Traffic while someone uses the app:** one API call a second
  (3,600 an hour), 100 ms each, and about 30 page loads an hour. The four
  profiles are the ones from Lab 4, in active hours a month:
  - nobody: 0 h;
  - class demos: 10 sessions × 2 h;
  - office hours: 22 days × 8 h;
  - busy around the clock: 730 h.
- **Aurora** holds 0.5 ACU while awake: the configured range is 0–1, and
  this load doesn't push it higher. After each session it stays awake for its
  300-second pause delay. Two storage I/Os per request; backups are within the
  free size. At 1 ACU, the AWS database line doubles.
- **Cloud Run:** billable time is taken as requests × 100 ms, which is an
  upper bound because concurrent requests share an instance. Cold starts are
  not billed beyond that.
- **Cloud SQL stays db-f1-micro** (0.6 GB, shared core) in every profile.
  "Busy around the clock" at this rate fits on it. A heavier busy profile
  would need db-g1-small at $0.035/h, which is $25.55 a month of compute.

## Free tiers used

| Side | Free tier | Effect here |
|---|---|---|
| AWS | Lambda: 1M requests and 400,000 GB-seconds a month, always free | Only "busy" goes past the requests. |
| AWS | CloudFront Free plan: 1M requests and 100 GB; traffic past that is throttled, not billed | Static files only. |
| AWS | ECR: 500 MB | Five ~260 MB images go past it by ~0.8 GB, so $0.08. |
| AWS | New-account credits | Accounts opened after July 2025 get credits instead of the classic 12-month free tier. Not counted. |
| GCP | Cloud Run: 2M requests, 180,000 vCPU-seconds and 360,000 GiB-seconds a month, per billing account | Only "busy" goes past them, by 0.6M requests and ~83,000 vCPU-seconds. |
| GCP | Firebase Hosting: 10 GB stored, 360 MB a day out (~10.9 GB a month) | "Busy" moves ~11 GB, right at the edge. |
| GCP | Artifact Registry 0.5 GB, Secret Manager 6 versions and 10,000 accesses, Cloud Logging 50 GiB | All within. |
| GCP | Cloud SQL | **No free tier.** |
| GCP | $300 Free Trial for 90 days | The trial pays all of this. The table shows the bill after the trial. |

## Which cloud is cheaper, and which line decides it

| Profile | Cheaper | Why |
|---|---|---|
| Nobody | **AWS**, $0.18 vs $9.37 | Aurora is paused, so its compute is $0. Cloud SQL never pauses. |
| Class demos | **AWS**, $1.46 vs $9.37 | About 21 awake hours of Aurora cost $1.25. Cloud SQL bills all 730 hours. |
| Office hours | **Google Cloud**, $9.37 vs $11.10 | About 178 awake hours of Aurora ($10.67) cost more than a month of db-f1-micro ($7.67). |
| Busy around the clock | **Google Cloud**, $11.60 vs $45.36 | Aurora is awake 730 h at $0.06/h, against $0.0105/h for Cloud SQL. |

**The deciding line is database compute in every profile.** The API, CDN and
registry lines are cents or within free tiers on both sides.

The two databases have opposite shapes:
- **Aurora** costs $0.06 an awake hour and $0 asleep.
- **Cloud SQL** costs a flat ~$7.67 (plus $1.70 of disk) whatever the traffic.

They cross at:

- **0.5 ACU:** ~154 awake hours a month, about 7 hours every working day.
- **1 ACU:** ~77 awake hours a month.

Below that line Aurora wins; above it Cloud SQL does. Stopping Cloud SQL
between sessions doesn't move the line much, because a stopped instance still
pays $0.01/h for its IP.

## Where the "kept awake" trap is on Google Cloud

On AWS, the trap was anything that keeps Aurora awake: a health check, a
`rate(5 minutes)` schedule, a connection pool that never closes. An idle
database then costs 730 h × $0.06 = **$43.80** a month, more than a small
provisioned instance. Cloud SQL has nothing to keep awake, since it is always
billing, so the traps on GCP look different:

1. **Believing "stopped" is cheap.** Stopping the instance saves only the
   difference between $0.0105/h running and $0.01/h for the IP stopped: about
   $0.37 a month on db-f1-micro. The fix is to delete the instance, or use a
   private IP only (VPC, private services access, Direct VPC egress).
2. **Paying for warm instances to hide cold starts.** This is the closest
   match to Aurora's minimum capacity. Some rates here are from secondary
   sources; check them in the calculator.
   - Min instances 1 on request-based billing: the idle instance bills
     ~$0.0000025 per vCPU-second, so ~$6.60 a month for 1 vCPU.
   - "CPU always allocated" (instance-based billing): every second of every
     instance bills, at ~$0.000018 per vCPU-second. That's about $43 a month
     for one always-on vCPU, the same order as the Aurora trap.
   - A pinger alone does **not** cost much on Cloud Run with request-based
     billing. Each ping bills about 100 ms, and idle instances that aren't
     min instances are free.
3. **Outgrowing the shared core.** db-f1-micro has no CPU guarantee and
   0.6 GB of memory. The step up, db-g1-small, is 3.3× the price
   ($25.55/month), and a dedicated-core tier is more again.
4. **Firestore instead of Cloud SQL** turns the bill into reads. A list page
   that reads 500 documents per visit spends the 50,000 free daily reads after
   100 visits (Lab 9, Part 3).

## Checking it in the calculators

I couldn't use the Google Cloud Pricing Calculator or the AWS Pricing
Calculator; both are interactive web apps. To check:

- **Google Cloud:** enter Cloud SQL PostgreSQL db-f1-micro, 730 h, 10 GB SSD,
  in us-central1. Then Cloud Run with the request and vCPU-second figures for
  "busy".
- **AWS:** enter Aurora PostgreSQL Serverless v2 with 0.5 ACU for each
  profile's awake hours, 1 GB of storage and the I/O count. Then Lambda with
  the "busy" requests.
- Add both share links here.
