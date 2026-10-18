"""PUT /api/v1/meetings/{id}/agenda: the save path for typed and parsed agendas."""

import uuid

from sqlalchemy import select

from app.models import Meeting


def agenda_payload(**overrides) -> dict:
    return {
        "items": [
            {"topic": "Нові тарифи Pro", "owner": "Олена", "minutes": 15},
            {"topic": "Фідбек від клієнтів", "owner": "Taras"},
        ],
        "action_items": [
            {"task": "Порівняння з конкурентами", "owner": "Taras", "due": "2026-10-23"}
        ],
    } | overrides


def suggestion(**overrides) -> dict:
    return {
        "suggestion": {
            "title": "Синк по прайсингу",
            "starts_at": "2026-10-19T10:00:00+03:00",
            "duration_minutes": 45,
            "items": [{"topic": "нові тарифи Pro", "owner": "Олена", "minutes": 15}],
            "action_items": [],
            "language": "uk",
        },
        "model": "anthropic.claude-opus-5-5",
        "prompt_version": "agenda-v1",
    } | overrides


async def create_meeting(client, meeting_payload) -> str:
    response = await client.post("/api/v1/meetings", json=meeting_payload)
    assert response.status_code == 201, response.text
    return response.json()["id"]


async def stored(session, meeting_id: str) -> Meeting:
    session.expire_all()
    return await session.scalar(select(Meeting).where(Meeting.id == uuid.UUID(meeting_id)))


async def test_new_meeting_has_no_agenda(client, meeting_payload):
    meeting_id = await create_meeting(client, meeting_payload)

    body = (await client.get(f"/api/v1/meetings/{meeting_id}")).json()

    assert body["agenda"] is None


async def test_put_saves_agenda_and_ai_suggestion(client, session, meeting_payload):
    meeting_id = await create_meeting(client, meeting_payload)

    response = await client.put(
        f"/api/v1/meetings/{meeting_id}/agenda",
        json=agenda_payload(ai_suggestion=suggestion()),
    )

    assert response.status_code == 200, response.text
    agenda = response.json()["agenda"]
    assert [item["topic"] for item in agenda["items"]] == ["Нові тарифи Pro", "Фідбек від клієнтів"]
    assert agenda["items"][1] == {"topic": "Фідбек від клієнтів", "owner": "Taras", "minutes": None}
    assert agenda["action_items"][0]["due"] == "2026-10-23"
    # The suggestion is stored for comparison, not returned to the browser.
    assert "ai_suggestion" not in response.json()

    fetched = (await client.get(f"/api/v1/meetings/{meeting_id}")).json()
    assert fetched["agenda"] == agenda

    row = await stored(session, meeting_id)
    assert row.ai_suggestion == suggestion()
    assert row.agenda == agenda


async def test_put_replaces_agenda_and_keeps_earlier_suggestion(client, session, meeting_payload):
    meeting_id = await create_meeting(client, meeting_payload)
    url = f"/api/v1/meetings/{meeting_id}/agenda"
    await client.put(url, json=agenda_payload(ai_suggestion=suggestion()))

    response = await client.put(url, json={"items": [{"topic": "Річна знижка"}]})

    assert response.status_code == 200, response.text
    assert response.json()["agenda"] == {
        "items": [{"topic": "Річна знижка", "owner": None, "minutes": None}],
        "action_items": [],
    }
    # A later hand edit is still a correction of the same suggestion.
    assert (await stored(session, meeting_id)).ai_suggestion == suggestion()


async def test_put_with_new_suggestion_replaces_the_old_one(client, session, meeting_payload):
    meeting_id = await create_meeting(client, meeting_payload)
    url = f"/api/v1/meetings/{meeting_id}/agenda"
    await client.put(url, json=agenda_payload(ai_suggestion=suggestion()))

    await client.put(url, json=agenda_payload(ai_suggestion=suggestion(prompt_version="agenda-v2")))

    assert (await stored(session, meeting_id)).ai_suggestion["prompt_version"] == "agenda-v2"


async def test_put_strips_text_and_blank_owner(client, meeting_payload):
    meeting_id = await create_meeting(client, meeting_payload)

    response = await client.put(
        f"/api/v1/meetings/{meeting_id}/agenda",
        json={"items": [{"topic": "  Ретро  ", "owner": "   "}]},
    )

    assert response.json()["agenda"]["items"] == [
        {"topic": "Ретро", "owner": None, "minutes": None}
    ]


async def test_put_rejects_empty_items(client, meeting_payload):
    meeting_id = await create_meeting(client, meeting_payload)

    response = await client.put(f"/api/v1/meetings/{meeting_id}/agenda", json={"items": []})

    assert response.status_code == 422
    assert response.json()["error"]["details"][0]["field"] == "items"


async def test_put_rejects_blank_topic(client, meeting_payload):
    meeting_id = await create_meeting(client, meeting_payload)

    response = await client.put(
        f"/api/v1/meetings/{meeting_id}/agenda", json={"items": [{"topic": "   "}]}
    )

    assert response.status_code == 422
    assert response.json()["error"]["details"][0]["field"] == "items.0.topic"


async def test_put_rejects_minutes_out_of_range(client, meeting_payload):
    meeting_id = await create_meeting(client, meeting_payload)

    response = await client.put(
        f"/api/v1/meetings/{meeting_id}/agenda",
        json={"items": [{"topic": "Ретро", "minutes": 0}]},
    )

    assert response.status_code == 422
    assert response.json()["error"]["details"][0]["field"] == "items.0.minutes"


async def test_put_rejects_invalid_ai_suggestion(client, meeting_payload):
    meeting_id = await create_meeting(client, meeting_payload)
    bad = suggestion()
    del bad["suggestion"]["language"]

    response = await client.put(
        f"/api/v1/meetings/{meeting_id}/agenda", json=agenda_payload(ai_suggestion=bad)
    )

    assert response.status_code == 422
    assert response.json()["error"]["details"][0]["field"] == "ai_suggestion.suggestion.language"


async def test_put_on_unknown_meeting_returns_404(client):
    response = await client.put(f"/api/v1/meetings/{uuid.uuid4()}/agenda", json=agenda_payload())

    assert response.status_code == 404


async def test_put_on_someone_elses_meeting_returns_404(
    client, other_client, session, meeting_payload
):
    meeting_id = await create_meeting(client, meeting_payload)

    response = await other_client.put(
        f"/api/v1/meetings/{meeting_id}/agenda", json=agenda_payload()
    )

    assert response.status_code == 404
    assert (await stored(session, meeting_id)).agenda is None


async def test_put_requires_sign_in(anonymous_client):
    response = await anonymous_client.put(
        f"/api/v1/meetings/{uuid.uuid4()}/agenda", json=agenda_payload()
    )

    assert response.status_code == 401
