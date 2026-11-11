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


HOUSING_SCOPE = (
    "Count a bill as housing-related if it could affect buying, selling, owning, renting, building, "
    "financing, insuring or taxing homes or land, or the work of real estate professionals, either "
    "directly or indirectly. Indirect examples: property tax and assessment rules, homestead exemptions, "
    "homeowners or flood insurance, utility and water/sewer rates or connection fees, impact fees, "
    "infrastructure and transportation funding that shapes where homes get built, zoning, land use, "
    "annexation and local government powers over development, building codes, permitting, contractor "
    "licensing, construction materials and labor rules, environmental and stormwater rules for "
    "development, eminent domain, liens, deeds, title and closing rules, mortgage lending, credit and "
    "consumer finance, HOAs and condos, landlord-tenant law, evictions, short-term rentals, manufactured "
    "homes, tax credits for housing, disaster recovery, and licensing of agents, brokers, appraisers and "
    "inspectors. Do not count bills whose link to housing is far-fetched."
)

Relevance = Literal["Direct", "Indirect"]


class Recap(BaseModel):
    is_housing_related: bool = Field(description="Whether the bill is housing-related under the scope given in the prompt.")
    relevance: Relevance = Field(description="Direct if housing or real estate is a main subject of the bill; Indirect if it mainly does something else but would still affect housing.")
    why_housing: str = Field(description="One plain sentence, max 25 words, on how this bill touches housing or real estate.")
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
        f"{HOUSING_SCOPE}\n\nWrite the recap."
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


class ScreenItem(BaseModel):
    id: str
    possibly_housing: bool = Field(description="True if the bill could plausibly affect housing directly or indirectly. When unsure, say True.")


class Screen(BaseModel):
    results: list[ScreenItem]


def screen(items):
    """Quick first pass on titles/descriptions. Returns the set of ids worth a full read."""
    keep = set()
    for i in range(0, len(items), 40):
        batch = items[i:i + 40]
        lines = "\n".join(f"{it['id']}: {it['text'][:600]}" for it in batch)
        result = _call(
            f"{HOUSING_SCOPE}\n\nBelow are bill ids with their titles. For each one, say whether it could "
            "plausibly affect housing directly or indirectly. Lean toward True when unsure; a later step "
            "reads the full text.\n\n<bills>\n" + lines + "\n</bills>",
            Screen,
        )
        if result is None:
            keep.update(it["id"] for it in batch)  # if screening is refused, read them all
            continue
        answered = {r.id for r in result.results}
        keep.update(r.id for r in result.results if r.possibly_housing)
        keep.update(it["id"] for it in batch if it["id"] not in answered)
    return keep


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
