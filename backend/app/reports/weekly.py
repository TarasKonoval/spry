"""The weekly meetings report: one ISO week in, one CSV out. No AWS in here.

The week is always a parameter, so an old report can be rebuilt at any time, and
one week always maps to one file name, so building it twice overwrites the same
file. The CSV holds no build timestamp: the same data gives the same bytes.

Usage: python -m app.reports.weekly [2026-W41]   (CSV to stdout; default: last week)
"""

import asyncio
import csv
import io
import re
import sys
from datetime import date, datetime, time, timedelta
from decimal import Decimal

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config import settings
from app.db import SessionFactory, engine
from app.models import Meeting, Participant, User

WEEK_PATTERN = re.compile(r"(\d{4})-W(\d{2})")
TOP_N = 5
NO_OWNER = "(no owner)"

# A meeting belongs to the week it starts in, so none is counted in two weeks.
DURATION = Meeting.ends_at - Meeting.starts_at
HOURS = func.extract("epoch", DURATION) / 3600


def parse_week(week: str) -> date:
    """Return the Monday of an ISO week such as "2026-W41"."""
    match = WEEK_PATTERN.fullmatch(week)
    if match is None:
        raise ValueError(f"A week looks like 2026-W41, not {week!r}.")
    try:
        return date.fromisocalendar(int(match[1]), int(match[2]), 1)
    except ValueError as exc:
        raise ValueError(f"{week} is not a week of {match[1]}.") from exc


def format_week(day: date) -> str:
    year, week, _ = day.isocalendar()
    return f"{year}-W{week:02d}"


def previous_week(week: str | None = None) -> str:
    """The ISO week before `week`, or before the current week in the app timezone."""
    day = parse_week(week) if week else datetime.now(settings.tz).date()
    return format_week(day - timedelta(days=7))


def week_window(week: str) -> tuple[datetime, datetime]:
    """Return [Monday 00:00, next Monday 00:00) of an ISO week in the app timezone."""
    monday = parse_week(week)
    start = datetime.combine(monday, time.min, tzinfo=settings.tz)
    end = datetime.combine(monday + timedelta(days=7), time.min, tzinfo=settings.tz)
    return start, end


def report_key(week: str) -> str:
    """The one S3 key a week's report is stored under."""
    parse_week(week)
    return f"reports/{week}.csv"


def _hours(value) -> Decimal:
    return Decimal(value or 0).quantize(Decimal("0.01"))


def _change_pct(current: Decimal, previous: Decimal) -> str:
    if not previous:
        return ""
    return f"{(current - previous) * 100 / previous:.1f}"


async def _totals(session: AsyncSession, start: datetime, end: datetime) -> tuple[int, Decimal]:
    row = (
        await session.execute(
            select(func.count(Meeting.id), func.sum(HOURS)).where(
                Meeting.starts_at >= start, Meeting.starts_at < end
            )
        )
    ).one()
    return int(row[0]), _hours(row[1])


async def _longest(session: AsyncSession, start: datetime, end: datetime):
    return (
        await session.execute(
            select(Meeting.name, Meeting.starts_at, HOURS, func.count(Participant.id))
            .outerjoin(Participant, Participant.meeting_id == Meeting.id)
            .where(Meeting.starts_at >= start, Meeting.starts_at < end)
            .group_by(Meeting.id)
            .order_by(DURATION.desc(), Meeting.starts_at, Meeting.name, Meeting.id)
            .limit(TOP_N)
        )
    ).all()


async def _per_organiser(
    session: AsyncSession, previous_start: datetime, start: datetime, end: datetime
):
    """Meetings and hours per owner in this week and the one before."""
    this_week = Meeting.starts_at >= start
    meetings = func.count(Meeting.id).filter(this_week)
    hours = func.sum(HOURS).filter(this_week)
    return (
        await session.execute(
            select(
                func.coalesce(User.name, User.email, Meeting.owner_id, NO_OWNER),
                meetings,
                hours,
                func.count(Meeting.id).filter(~this_week),
                func.sum(HOURS).filter(~this_week),
            )
            .outerjoin(User, User.id == Meeting.owner_id)
            .where(Meeting.starts_at >= previous_start, Meeting.starts_at < end)
            .group_by(Meeting.owner_id, User.name, User.email)
            .order_by(
                func.coalesce(hours, 0).desc(),
                meetings.desc(),
                User.name,
                User.email,
                Meeting.owner_id,
            )
        )
    ).all()


async def build_weekly_report(
    week: str, session_factory: async_sessionmaker = SessionFactory
) -> bytes:
    """Query the meetings of one ISO week (e.g. "2026-W40") and return the CSV."""
    start, end = week_window(week)
    before = previous_week(week)
    previous_start, _ = week_window(before)

    async with session_factory() as session:
        count, hours = await _totals(session, start, end)
        previous_count, previous_hours = await _totals(session, previous_start, start)
        longest = await _longest(session, start, end)
        organisers = await _per_organiser(session, previous_start, start, end)

    out = io.StringIO()
    writer = csv.writer(out)
    writer.writerow(["week", "previous_week", "from", "to", "timezone"])
    writer.writerow(
        [
            week,
            before,
            start.date().isoformat(),
            (end - timedelta(days=1)).date().isoformat(),
            settings.app_timezone,
        ]
    )
    writer.writerow([])
    writer.writerow(["metric", "this_week", "previous_week", "change", "change_pct"])
    writer.writerow(
        [
            "meetings",
            count,
            previous_count,
            count - previous_count,
            _change_pct(Decimal(count), Decimal(previous_count)),
        ]
    )
    writer.writerow(
        [
            "total_hours",
            hours,
            previous_hours,
            hours - previous_hours,
            _change_pct(hours, previous_hours),
        ]
    )
    writer.writerow([])
    writer.writerow(["rank", "title", "starts_at", "duration_hours", "participants"])
    for rank, (name, starts_at, duration, participants) in enumerate(longest, start=1):
        writer.writerow(
            [
                rank,
                name,
                starts_at.astimezone(settings.tz).strftime("%Y-%m-%d %H:%M"),
                _hours(duration),
                participants,
            ]
        )
    writer.writerow([])
    writer.writerow(["organiser", "meetings", "hours", "previous_meetings", "previous_hours"])
    for organiser, meetings, hours_, prev_meetings, prev_hours in organisers:
        writer.writerow([organiser, meetings, _hours(hours_), prev_meetings, _hours(prev_hours)])

    # The BOM makes Excel read the file as UTF-8, so Cyrillic titles survive.
    return out.getvalue().encode("utf-8-sig")


async def _main(week: str) -> None:
    try:
        sys.stdout.buffer.write(await build_weekly_report(week))
    finally:
        await engine.dispose()


if __name__ == "__main__":
    if len(sys.argv) > 2:
        sys.exit("Usage: python -m app.reports.weekly [2026-W41]")
    target = sys.argv[1] if len(sys.argv) == 2 else previous_week()
    try:
        parse_week(target)
    except ValueError as exc:
        sys.exit(str(exc))
    asyncio.run(_main(target))
