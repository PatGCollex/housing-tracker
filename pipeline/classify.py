"""Decide whether a bill touches housing, using word lists only (free, no AI).

Direct: housing or real estate is the main subject.
Indirect: the bill is about something else (taxes, utilities, insurance, building rules...)
that still affects buying, selling, owning, renting or building homes.

To catch more (or fewer) bills, add or remove phrases below. Matching ignores case.
"""
import re

DIRECT = {
    "housing": r"housing",
    "real estate": r"real estate|real property|realtor",
    "homebuyers": r"home ?buyers?|home ?ownership|homeowners?\b|first[- ]time buyer",
    "mortgages": r"mortgages?|home loans?|fannie mae|freddie mac|\bFHA\b|federal housing",
    "renting": r"\brent(al|als|ers?|ed|ing)?\b|tenants?|landlords?|\blease(s|hold)?\b",
    "evictions": r"evictions?|dispossessory|squatters?|intruders? (on|in) (real )?property",
    "zoning": r"zoning|rezon",
    "HOAs and condos": r"homeowners'? associations?|property owners'? associations?|\bHOAs?\b|condominiums?",
    "manufactured homes": r"manufactured homes?|mobile homes?|modular homes?",
    "short-term rentals": r"short[- ]term rentals?|vacation rentals?",
    "housing aid": r"\bHUD\b|low[- ]income housing|affordable housing|housing voucher|section 8|homeless",
    "real estate licensing": r"real estate (brokers?|agents?|salespersons?|commission)|appraisers?|appraisals?|home inspectors?",
}

INDIRECT = {
    "property taxes": r"property tax|ad valorem|homestead|millage|tax assessors?|assessed value|property assessments?",
    "transfer and closing costs": r"transfer tax|closing costs?|escrow|title insurance|\bdeeds?\b|recording fees?",
    "insurance": r"(homeowners'?|property|flood|hazard|windstorm|hurricane) insurance|insurance (premiums?|rates?) for (homes?|property)",
    "flooding": r"flood ?plains?|flood zones?|flood maps?|stormwater",
    "water and sewer": r"sewer|wastewater|septic|water (and|&) sewer|water (connection|tap|hookup)|tap fees?",
    "utilities": r"utility (connection|hookup|rates?)|electric (membership|cooperative)|broadband (expansion|deployment)",
    "impact fees": r"impact fees?|development fees?",
    "land use": r"land use|annex(ation|ing|ed)?|subdivisions?|\bplats?\b|comprehensive plans?|planning commissions?|land banks?|blight",
    "building rules": r"building codes?|energy codes?|(building|construction|development) permits?|code enforcement|inspections? of (buildings?|structures?)",
    "construction": r"(residential|home|housing) construction|construction (contractors?|industry|materials?|lending)|contractor licens|general contractors?|residential contractors?",
    "eminent domain": r"eminent domain|condemnation of (land|property)",
    "liens": r"\bliens?\b|foreclos",
    "lending and credit": r"\blenders?\b|\blending\b|consumer credit|credit reports?|interest rates? on loans",
    "development and infrastructure": r"infrastructure|community development|block grants?|\bCDBG\b|opportunity zones?|tax increment|redevelopment",
    "disaster recovery": r"disaster (recovery|relief|assistance)|\bFEMA\b",
    "property owners": r"property owners?|landowners?|private property",
}

_DIRECT = {k: re.compile(v, re.IGNORECASE) for k, v in DIRECT.items()}
_INDIRECT = {k: re.compile(v, re.IGNORECASE) for k, v in INDIRECT.items()}


def classify(*texts, policy_area=None):
    """Returns (relevance, why) or (None, None) if the bill doesn't look housing-related."""
    text = " ".join(t for t in texts if t)
    direct = [k for k, rx in _DIRECT.items() if rx.search(text)]
    indirect = [k for k, rx in _INDIRECT.items() if rx.search(text)]
    if policy_area == "Housing and Community Development" and not direct:
        direct = ["housing"]
    if direct:
        return "Direct", "Deals with " + _join(direct + indirect) + "."
    if indirect:
        return "Indirect", "Not mainly a housing bill, but deals with " + _join(indirect) + "."
    return None, None


def _join(items):
    items = list(dict.fromkeys(items))[:4]
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1]
