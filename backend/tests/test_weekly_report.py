"""Tests for the weekly report: week arithmetic, the numbers in the CSV, and idempotency."""

import csv
import io
from datetime import date, datetime, timedelta

import pytest

from app.config import settings
from app.models import Meeting, Participant, User
from app.reports.weekly import build_weekly_report, parse_week, previous_week, report_key


def _at(day: date, hour: int, minute: int = 0) -> datetime:
    return datetime(day.year, day.month, day.day, hour, minute, tzinfo=settings.tz)


def _meeting(
    name: str, starts_at: datetime, minutes: int, owner_id: str | None, people: int = 0
) -> Meeting:
    return Meeting(
        owner_id=owner_id,
        name=name,
        starts_at=starts_at,
        ends_at=starts_at + timedelta(minutes=minutes),
        participants=[
            Participant(name=f"Person {index}", position=index) for index in range(people)
        ],
    )


def _sections(report: bytes) -> list[list[list[str]]]:
    """Split the CSV into its blocks; the first row of each block is its header."""
    sections: list[list[list[str]]] = [[]]
    for row in csv.reader(io.StringIO(report.decode("utf-8-sig"))):
        if row:
            sections[-1].append(row)
        else:
            sections.append([])
    return sections


MONDAY = date(2026, 10, 5)  # 2026-W41
SUNDAY = MONDAY + timedelta(days=6)
PREVIOUS_MONDAY = MONDAY - timedelta(days=7)  # 2026-W40


@pytest.fixture
async def week_of_meetings(session) -> None:
    session.add_all(
        [
            User(id="user-a", name="Ostap", email="ostap@example.com"),
            User(id="user-b", email="iryna@example.com"),
            User(id="user-c", name="Sofia"),
        ]
    )
    await session.flush()
    session.add_all(
        [
            # 2026-W41: 4 meetings, 2 + 1 + 0.5 + 2 = 5.5 hours.
            _meeting("Sprint planning", _at(MONDAY, 10), 120, "user-a", people=3),
            # 01:00 in Kyiv is still Sunday in UTC: the week is the app timezone's.
            _meeting("Early sync", _at(MONDAY, 1), 60, "user-b", people=1),
            _meeting("Design review", _at(MONDAY + timedelta(days=2), 14), 30, "user-a"),
            # Crosses into the next week: counted, in full, in the week it starts.
            _meeting("Late release", _at(SUNDAY, 23), 120, None, people=2),
            # 2026-W40: 1 meeting, 1 hour, by someone with nothing in W41.
            _meeting("Old retro", _at(PREVIOUS_MONDAY + timedelta(days=6), 23), 60, "user-c"),
            # 2026-W42 starts at midnight: not in the report.
            _meeting("Next week", _at(SUNDAY + timedelta(days=1), 0), 60, "user-a"),
        ]
    )
    await session.commit()


def test_parse_week_returns_the_iso_monday():
    assert parse_week("2026-W41") == MONDAY
    assert parse_week("2026-W01") == date(2025, 12, 29)
    assert parse_week("2026-W53") == date(2026, 12, 28)


@pytest.mark.parametrize("week", ["2026-41", "2026-W1", "2026-W41 ", "2025-W53", "2026-W00"])
def test_parse_week_rejects_malformed_or_impossible_weeks(week):
    with pytest.raises(ValueError):
        parse_week(week)


def test_previous_week_crosses_the_year_boundary():
    assert previous_week("2026-W41") == "2026-W40"
    assert previous_week("2026-W01") == "2025-W52"


def test_report_key_is_one_file_per_week():
    assert report_key("2026-W41") == "reports/2026-W41.csv"
    with pytest.raises(ValueError):
        report_key("../2026-W41")


async def test_summary_compares_with_the_week_before(week_of_meetings):
    header, summary, _, _ = _sections(await build_weekly_report("2026-W41"))

    assert header[1] == ["2026-W41", "2026-W40", "2026-10-05", "2026-10-11", "Europe/Kyiv"]
    assert summary == [
        ["metric", "this_week", "previous_week", "change", "change_pct"],
        ["meetings", "4", "1", "3", "300.0"],
        ["total_hours", "5.50", "1.00", "4.50", "450.0"],
    ]


async def test_longest_meetings_are_ranked_with_participant_counts(week_of_meetings):
    _, _, longest, _ = _sections(await build_weekly_report("2026-W41"))

    assert longest == [
        ["rank", "title", "starts_at", "duration_hours", "participants"],
        ["1", "Sprint planning", "2026-10-05 10:00", "2.00", "3"],
        ["2", "Late release", "2026-10-11 23:00", "2.00", "2"],
        ["3", "Early sync", "2026-10-05 01:00", "1.00", "1"],
        ["4", "Design review", "2026-10-07 14:00", "0.50", "0"],
    ]


async def test_only_the_five_longest_are_listed(session):
    session.add(User(id="user-a"))
    await session.flush()
    session.add_all(
        _meeting(f"Meeting {minutes}", _at(MONDAY, 9), minutes, "user-a")
        for minutes in (10, 20, 30, 40, 50, 60)
    )
    await session.commit()

    _, summary, longest, _ = _sections(await build_weekly_report("2026-W41"))

    assert summary[1][1] == "6"
    assert [row[1] for row in longest[1:]] == [
        "Meeting 60",
        "Meeting 50",
        "Meeting 40",
        "Meeting 30",
        "Meeting 20",
    ]


async def test_totals_are_broken_down_per_organiser(week_of_meetings):
    _, _, _, organisers = _sections(await build_weekly_report("2026-W41"))

    assert organisers == [
        ["organiser", "meetings", "hours", "previous_meetings", "previous_hours"],
        ["Ostap", "2", "2.50", "0", "0.00"],
        ["(no owner)", "1", "2.00", "0", "0.00"],
        ["iryna@example.com", "1", "1.00", "0", "0.00"],
        ["Sofia", "0", "0.00", "1", "1.00"],
    ]


async def test_an_empty_week_has_no_percentage_change():
    _, summary, longest, organisers = _sections(await build_weekly_report("2026-W41"))

    assert summary[1:] == [
        ["meetings", "0", "0", "0", ""],
        ["total_hours", "0.00", "0.00", "0.00", ""],
    ]
    assert len(longest) == 1 and len(organisers) == 1


async def test_the_same_week_gives_the_same_bytes(week_of_meetings):
    assert await build_weekly_report("2026-W41") == await build_weekly_report("2026-W41")
