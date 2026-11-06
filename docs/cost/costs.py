"""Spry's core on AWS and on Google Cloud, per month, for the four Lab 4 traffic profiles.

    python3 docs/cost/costs.py        # prints the tables in docs/cost/lab9-aws-vs-gcp.md

List prices in USD, without tax, 730 hours a month: AWS us-east-1, Google Cloud
us-central1, checked 2026-11-05. Change an assumption below and re-run; the
standard library is all it needs.
"""

HOURS = 730

# --- traffic: what one active hour looks like -------------------------------------
REQUESTS_PER_HOUR = 3_600  # one API call a second while someone uses the app
REQUEST_SECONDS = 0.1  # average handling time per call
MEMORY_GB = 0.5  # Lambda MemorySize 512 / Cloud Run limit 512Mi

# (name, active hours a month, separate sessions: each ends with Aurora's pause delay)
PROFILES = [
    ("Nobody", 0, 0),
    ("Class demos (10 × 2 h)", 20, 10),
    ("Office hours (8 h × 22 days)", 176, 22),
    ("Busy around the clock", HOURS, 1),
]

# --- AWS (Lab 4, Stage 2: Lambda + function URL, Aurora Serverless v2, CloudFront) --
ACU_HOUR = 0.12  # Aurora Serverless v2, Aurora Standard
ACU_WHILE_AWAKE = 0.5  # 0–1 ACU configured; light load holds the floor of 0.5
AUTO_PAUSE_SECONDS = 300  # DbAutoPauseSeconds: awake this long after the last query
AURORA_STORAGE_GB = 1
AURORA_STORAGE_GB_MONTH = 0.10
AURORA_IO_PER_MILLION = 0.20
IOS_PER_REQUEST = 2  # most reads hit the buffer cache

LAMBDA_PER_MILLION = 0.20
LAMBDA_GB_SECOND = 0.0000166667
LAMBDA_FREE_REQUESTS = 1_000_000  # always free
LAMBDA_FREE_GB_SECONDS = 400_000

ECR_IMAGES_GB = 5 * 0.26  # lifecycle keeps five ~260 MB images
ECR_FREE_GB = 0.5
ECR_GB_MONTH = 0.10
# CloudFront on the flat-rate Free plan (WAF included): $0, overage is throttled, not billed.

# --- Google Cloud (this lab: Firebase Hosting, Cloud Run, Cloud SQL) ----------------
SQL_HOUR = 0.0105  # db-f1-micro while running
SQL_IP_HOUR_STOPPED = 0.01  # the public IPv4 of a stopped instance
SQL_SSD_GB = 10
SQL_SSD_GB_MONTH = 0.17

RUN_PER_MILLION = 0.40  # request-based billing
RUN_VCPU_SECOND = 0.000024
RUN_GIB_SECOND = 0.0000025
RUN_FREE_REQUESTS = 2_000_000
RUN_FREE_VCPU_SECONDS = 180_000
RUN_FREE_GIB_SECONDS = 360_000
# Firebase Hosting (10 GB stored, ~10.9 GB a month out at no cost), Artifact Registry
# (0.5 GB; two images kept), Secret Manager (one version) and Cloud Logging stay free.


def over(used: float, free: float) -> float:
    return max(0.0, used - free)


def aws(active_hours: float, sessions: int) -> dict[str, float]:
    requests = active_hours * REQUESTS_PER_HOUR
    awake = min(HOURS, active_hours + sessions * AUTO_PAUSE_SECONDS / 3600)
    gb_seconds = requests * REQUEST_SECONDS * MEMORY_GB
    return {
        "Database compute": awake * ACU_WHILE_AWAKE * ACU_HOUR,
        "Database storage + I/O": AURORA_STORAGE_GB * AURORA_STORAGE_GB_MONTH
        + requests * IOS_PER_REQUEST / 1e6 * AURORA_IO_PER_MILLION,
        "API": over(requests, LAMBDA_FREE_REQUESTS) / 1e6 * LAMBDA_PER_MILLION
        + over(gb_seconds, LAMBDA_FREE_GB_SECONDS) * LAMBDA_GB_SECOND,
        "Frontend + CDN": 0.0,
        "Registry": over(ECR_IMAGES_GB, ECR_FREE_GB) * ECR_GB_MONTH,
    }


def gcp(active_hours: float, stop_when_idle: bool) -> dict[str, float]:
    requests = active_hours * REQUESTS_PER_HOUR
    # Request-based billing counts an instance only while it handles requests;
    # one call at a time makes this an upper bound.
    vcpu_seconds = requests * REQUEST_SECONDS
    running = active_hours if stop_when_idle else HOURS
    return {
        "Database compute": running * SQL_HOUR + (HOURS - running) * SQL_IP_HOUR_STOPPED,
        "Database storage + I/O": SQL_SSD_GB * SQL_SSD_GB_MONTH,
        "API": over(requests, RUN_FREE_REQUESTS) / 1e6 * RUN_PER_MILLION
        + over(vcpu_seconds, RUN_FREE_VCPU_SECONDS) * RUN_VCPU_SECOND
        + over(vcpu_seconds * MEMORY_GB, RUN_FREE_GIB_SECONDS) * RUN_GIB_SECOND,
        "Frontend + CDN": 0.0,
        "Registry": 0.0,
    }


def money(value: float) -> str:
    return f"${value:,.2f}"


def main() -> None:
    lines = list(aws(0, 0))
    print("| Profile | AWS | GCP, Cloud SQL always on | GCP, stopped when idle | Cheaper |")
    print("|---|---|---|---|---|")
    details = []
    for name, active, sessions in PROFILES:
        a, g, s = aws(active, sessions), gcp(active, False), gcp(active, True)
        totals = sum(a.values()), sum(g.values()), sum(s.values())
        cheaper = "AWS" if totals[0] < min(totals[1:]) else "Google Cloud"
        print(f"| {name} | {' | '.join(money(t) for t in totals)} | {cheaper} |")
        details.append((name, a, g, s))

    for name, a, g, s in details:
        print(f"\n**{name}**\n")
        print("| Line | AWS | GCP, always on | GCP, stopped when idle |")
        print("|---|---|---|---|")
        for line in lines:
            print(f"| {line} | {money(a[line])} | {money(g[line])} | {money(s[line])} |")
        print(
            f"| **Total** | **{money(sum(a.values()))}** | **{money(sum(g.values()))}** "
            f"| **{money(sum(s.values()))}** |"
        )

    # Where Aurora's awake hours cost as much as a Cloud SQL instance that never stops.
    fixed_gcp = HOURS * SQL_HOUR + SQL_SSD_GB * SQL_SSD_GB_MONTH
    for acu in (0.5, 1.0):
        hours = (fixed_gcp - AURORA_STORAGE_GB * AURORA_STORAGE_GB_MONTH) / (acu * ACU_HOUR)
        print(f"\nBreak-even at {acu} ACU: {hours:.0f} awake hours a month")


if __name__ == "__main__":
    main()
