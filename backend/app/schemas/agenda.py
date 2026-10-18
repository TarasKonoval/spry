"""A meeting's agenda, and the ParsedAgenda contract the LLM parser must meet.

The same AgendaItem and ActionItem validate what the model returns
(app.ai.agenda) and what the user saves (PUT /api/v1/meetings/{id}/agenda).
"""

from datetime import date
from typing import Annotated

from pydantic import AfterValidator, BaseModel, Field

MAX_AGENDA_ITEMS = 50


def _required_text(value: str) -> str:
    stripped = value.strip()
    if not stripped:
        raise ValueError("must not be blank")
    return stripped


def _optional_text(value: str | None) -> str | None:
    if value is None:
        return None
    return value.strip() or None


RequiredText = Annotated[str, AfterValidator(_required_text)]
OptionalText = Annotated[str | None, AfterValidator(_optional_text)]


class AgendaItem(BaseModel):
    topic: RequiredText = Field(min_length=1, max_length=300)
    owner: OptionalText = Field(
        default=None, max_length=200, description="A name or an email, exactly as written"
    )
    minutes: int | None = Field(default=None, ge=1, le=480)


class ActionItem(BaseModel):
    task: RequiredText = Field(min_length=1, max_length=500)
    owner: OptionalText = Field(
        default=None, max_length=200, description="A name or an email, exactly as written"
    )
    due: date | None = None


class ParsedAgenda(BaseModel):
    """What the parser returns. Its JSON schema is the record_agenda tool's input."""

    title: str | None = None
    starts_at: str | None = Field(
        default=None, description="ISO 8601 with the user's UTC offset, if the text says when"
    )
    duration_minutes: int | None = Field(default=None, ge=1, le=600)
    items: list[AgendaItem]
    action_items: list[ActionItem] = []
    language: str = Field(description='The language of the text: "uk", "en", ...')


class AiSuggestion(BaseModel):
    """The parser's answer as the browser received it, sent back on Save."""

    suggestion: ParsedAgenda
    model: str = Field(min_length=1, max_length=100)
    prompt_version: str = Field(min_length=1, max_length=50)


class AgendaWrite(BaseModel):
    items: list[AgendaItem] = Field(min_length=1, max_length=MAX_AGENDA_ITEMS)
    action_items: list[ActionItem] = Field(default_factory=list, max_length=MAX_AGENDA_ITEMS)
    # Present only when the agenda started from a parse.
    ai_suggestion: AiSuggestion | None = None


class AgendaRead(BaseModel):
    items: list[AgendaItem]
    action_items: list[ActionItem]
