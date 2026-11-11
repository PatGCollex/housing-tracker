"""Compare two versions of a bill's text (free, no AI).

Returns a short list of pieces: ["=", text] unchanged, ["+", text] added, ["-", text] removed.
Long unchanged stretches are cut down so the file stays small.
"""
import difflib
import re

CONTEXT_WORDS = 25      # unchanged words kept on each side of a change
MAX_PIECES = 400        # stop after this many pieces on very long bills


def clean(text):
    """Remove line numbers, page headers and extra spaces from bill text."""
    lines = []
    for line in (text or "").splitlines():
        line = re.sub(r"^\s*\d{1,3}\s+", "", line)          # line numbers in the margin
        if re.match(r"^\s*(LC|H\. ?B\.|S\. ?B\.)\s*[\w .-]*$", line) or re.match(r"^\s*-\s*\d+\s*-\s*$", line):
            continue                                          # page headers and page numbers
        lines.append(line)
    return " ".join(" ".join(lines).split())


def compare(old_text, new_text):
    old_words = clean(old_text).split(" ")
    new_words = clean(new_text).split(" ")
    matcher = difflib.SequenceMatcher(None, old_words, new_words, autojunk=False)
    pieces = []

    def add(op, words):
        if not words:
            return
        text = " ".join(words)
        if pieces and pieces[-1][0] == op:
            pieces[-1][1] += " " + text
        else:
            pieces.append([op, text])

    opcodes = matcher.get_opcodes()
    for i, (tag, a1, a2, b1, b2) in enumerate(opcodes):
        if tag == "equal":
            words = old_words[a1:a2]
            first, last = i == 0, i == len(opcodes) - 1
            keep_head = 0 if first else CONTEXT_WORDS
            keep_tail = 0 if last else CONTEXT_WORDS
            if len(words) > keep_head + keep_tail + 10:
                add("=", words[:keep_head])
                pieces.append(["…", f"{len(words) - keep_head - keep_tail:,} words unchanged"])
                add("=", words[len(words) - keep_tail:])
            else:
                add("=", words)
        else:
            if tag in ("replace", "delete"):
                add("-", old_words[a1:a2])
            if tag in ("replace", "insert"):
                add("+", new_words[b1:b2])
        if len(pieces) >= MAX_PIECES:
            pieces.append(["…", "More changes. Open the full versions to see the rest."])
            break

    changed = sum(1 for p in pieces if p[0] in "+-")
    return {"pieces": pieces, "changes": changed}
