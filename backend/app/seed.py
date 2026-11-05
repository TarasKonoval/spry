"""Insert a few demo meetings on one day for one user who has none that day.

Usage: python -m app.seed <cognito-sub> [YYYY-MM-DD]   (default: today, APP_TIMEZONE)
"""

import asyncio
import logging
import sys
from datetime import date, datetime, time

from sqlalchemy.ext.asyncio import async_sessionmaker

from app.config import settings
from app.db import SessionFactory
from app.models import Meeting, Participant
from app.repositories.meeting import MeetingRepository
from app.repositories.user import UserRepository
from app.services.meeting import day_window

logger = logging.getLogger("meetings.seed")

DEMO = [
    (
        "Sprint planning",
        "Plan the next two weeks and groom the backlog.",
        "Room 3",
        time(10, 0),
        time(11, 0),
        [("Ostap", "ostap@example.com"), ("Iryna", None), ("Maksym", "maksym@example.com")],
    ),
    (
        "Design review",
        "Walk through the new meetings dashboard.",
        "meet.example.com/design",
        time(14, 0),
        time(14, 30),
        [("Sofia", "sofia@example.com"), ("Ostap", None)],
    ),
    (
        "Daily standup",
        "What we did, what we will do, what blocks us.",
        None,
        time(9, 15),
        time(9, 30),
        [("Ostap", None), ("Iryna", None), ("Sofia", None), ("Maksym", None), ("Andrii", None)],
    ),
]


async def seed_if_empty(
    owner_id: str,
    day: date | None = None,
    session_factory: async_sessionmaker = SessionFactory,
) -> None:
    day = day or datetime.now(settings.tz).date()
    async with session_factory() as session:
        # Per day, so a demo can be re-seeded for today without doubling an old one.
        if await MeetingRepository(session, owner_id).count_overlapping(*day_window(day)):
            logger.info("User %s already has meetings on %s; skipping demo seed.", owner_id, day)
            return

        await UserRepository(session).ensure(owner_id)
        for name, description, location, start, end, people in DEMO:
            session.add(
                Meeting(
                    owner_id=owner_id,
                    name=name,
                    description=description,
                    location=location,
                    starts_at=datetime.combine(day, start, tzinfo=settings.tz),
                    ends_at=datetime.combine(day, end, tzinfo=settings.tz),
                    participants=[
                        Participant(name=person, email=email, position=index)
                        for index, (person, email) in enumerate(people)
                    ],
                )
            )
        await session.commit()
        logger.info("Seeded %d demo meetings for %s on %s.", len(DEMO), owner_id, day)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit("Usage: python -m app.seed <cognito-sub> [YYYY-MM-DD]")
    try:
        seed_day = date.fromisoformat(sys.argv[2]) if len(sys.argv) == 3 else None
    except ValueError:
        sys.exit(f"Not a date (YYYY-MM-DD): {sys.argv[2]}")
    logging.basicConfig(level=logging.INFO)
    asyncio.run(seed_if_empty(sys.argv[1], seed_day))
