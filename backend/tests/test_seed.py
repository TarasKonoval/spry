"""The demo seed: three meetings on one day, and only on a day that has none."""

from datetime import date

from sqlalchemy import func, select

from app.models import Meeting
from app.seed import DEMO, seed_if_empty

OWNER = "seed-user"


async def _days(session) -> dict[date, int]:
    day = func.date(func.timezone("Europe/Kyiv", Meeting.starts_at))
    rows = await session.execute(
        select(day, func.count()).where(Meeting.owner_id == OWNER).group_by(day)
    )
    return dict(rows.all())


async def test_seeds_the_given_day(session):
    await seed_if_empty(OWNER, date(2026, 11, 6))
    assert await _days(session) == {date(2026, 11, 6): len(DEMO)}


async def test_a_day_with_meetings_is_left_alone(session):
    await seed_if_empty(OWNER, date(2026, 11, 6))
    await seed_if_empty(OWNER, date(2026, 11, 6))
    assert await _days(session) == {date(2026, 11, 6): len(DEMO)}


async def test_meetings_on_another_day_do_not_block_a_new_day(session):
    await seed_if_empty(OWNER, date(2026, 11, 5))
    await seed_if_empty(OWNER, date(2026, 11, 6))
    assert await _days(session) == {date(2026, 11, 5): len(DEMO), date(2026, 11, 6): len(DEMO)}


async def test_other_users_meetings_do_not_count(session):
    await seed_if_empty("someone-else", date(2026, 11, 6))
    await seed_if_empty(OWNER, date(2026, 11, 6))
    assert await _days(session) == {date(2026, 11, 6): len(DEMO)}
