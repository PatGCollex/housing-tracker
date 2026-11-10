"""Plain-English recaps, impact labels and "what changed" notes, written by Claude."""
import difflib
from typing import Literal

import anthropic
from pydantic import BaseModel, Field

MODEL = "claude-opus-5-5"
MAX_CHARS = 400_000  # bills longer than this are rare; we say so instead of silently cutting

client = anthropic.Anthropic()

AUDIENCE = (
    "You write for Georgia Realtors: busy real estate agents and brokers, not lawyers. "
    "Use plain, everyday words, short sentences, and no legal jargon. "
    "Be neutral and factual. Never invent details that are not in the bill."
)

Impact = Literal[
    "Helps buyers", "Helps sellers", "Helps homeowners", "Helps renters", "Helps landlords",
    "Burdens buyers", "Burdens sellers", "Burdens homeowners", "Burdens landlords",
    "Affects Realtors directly", "Mixed impact", "Neutral",
]


class Recap(BaseModel):
    is_housing_related: bool = Field(description="True only if this bill meaningfully affects housing, real estate, homeownership, renting, mortgages, property, land use, or the real estate profession.")
    headline: str = Field(description="One sentence, max 15 words, saying what the bill does.")
    recap: str = Field(description="3 to 4 plain-English sentences: what it does, who it affects, and why a Realtor might care.")
    impact: Impact = Field(description="The single best label for its main effect on Georgia real estate.")


class Changes(BaseModel):
    summary: str = Field(description="2 to 4 plain-English sentences on what changed in this version and why it matters. If nothing meaningful changed, say so in one sentence.")


def _call(prompt, schema):
    resp = client.messages.parse(
        model=MODEL,
        max_tokens=4000,
        output_config={"effort": "low"},
        system=AUDIENCE,
        messages=[{"role": "user", "content": prompt}],
        output_format=schema,
    )
    if resp.stop_reason == "refusal":
        return None
    return resp.parsed_output


def recap_bill(bill, text):
    note = ""
    if len(text) > MAX_CHARS:
        note = "\n(Note: only the first part of this very long bill is included.)"
        text = text[:MAX_CHARS]
    prompt = (
        f"{bill['jurisdiction']} bill {bill['number']}: {bill['title']}\n"
        f"Current status: {bill['status']}\n\n"
        f"<bill_text>\n{text}\n</bill_text>{note}\n\n"
        "Write the recap."
    )
    return _call(prompt, Recap)


def what_changed(bill, old_name, old_text, new_name, new_text):
    diff = "\n".join(difflib.unified_diff(
        old_text.splitlines(), new_text.splitlines(), old_name, new_name, n=2, lineterm=""))
    if not diff.strip():
        return "The wording did not change from the previous version."
    if len(diff) > MAX_CHARS:
        diff = diff[:MAX_CHARS] + "\n(diff continues)"
    prompt = (
        f"{bill['jurisdiction']} bill {bill['number']}: {bill['title']}\n"
        f"Below is the line-by-line difference between \"{old_name}\" and \"{new_name}\" "
        "(lines starting with - were removed, + were added).\n\n"
        f"<diff>\n{diff}\n</diff>\n\nExplain what changed."
    )
    result = _call(prompt, Changes)
    return result.summary if result else "This version changed the bill. Open the full text for details."


class WeeklyRecap(BaseModel):
    summary: str = Field(description="A short plain-English recap of the week, 4 to 8 sentences, most important items first.")


def weekly_recap(events):
    lines = "\n".join(f"- {e}" for e in events) or "- No housing bill activity this week."
    result = _call(
        "Here is everything that happened to tracked housing bills (federal and Georgia) in the past week:\n"
        f"{lines}\n\nWrite the weekly recap for Georgia Realtors.",
        WeeklyRecap,
    )
    return result.summary if result else "Weekly recap unavailable this week."
