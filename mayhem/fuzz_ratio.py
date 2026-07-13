"""Fuzz harness body for thefuzz's pure-Python fuzzy string matching.

Ported from the original Atheris harness (mayhem/ratio.py on
archive/original-master): the fuzzed code paths are identical — the
fuzz.* scorers (ratio / partial_ratio / token_sort_ratio / token_set_ratio /
QRatio / UQRatio / WRatio / UWRatio) and process.extract / process.extractOne.

This module is invoked from the native libFuzzer driver
(mayhem/fuzz_ratio_driver.c), which embeds CPython and calls
`TestOneInput(data: bytes)` once per input. A tiny FuzzedDataProvider
replacement carves the selector + strings out of the raw bytes so the input
mapping stays deterministic without depending on Atheris.

Expected, documented rejections of bad input (TypeError on non-string args is
not reachable here; thefuzz's scorers accept any strings) are not findings —
anything that escapes TestOneInput is reported by the driver as a defect.
"""

from thefuzz import fuzz
from thefuzz import process

SCORERS = [
    fuzz.ratio,
    fuzz.partial_ratio,
    fuzz.token_sort_ratio,
    fuzz.token_set_ratio,
    fuzz.UQRatio,
    fuzz.QRatio,
    fuzz.UWRatio,
    fuzz.WRatio,
]


def _split_strings(data: bytes, n: int):
    """Deterministically carve `n` strings out of `data`."""
    if n <= 0:
        return []
    chunk = max(1, len(data) // n)
    parts = []
    for i in range(n):
        raw = data[i * chunk:(i + 1) * chunk][:32]
        parts.append(raw.decode("utf-8", "replace"))
    return parts


def TestOneInput(data: bytes) -> None:
    if len(data) < 2:
        return
    sel = data[0]
    body = data[1:]

    if sel & 0x80:
        # process.* paths (the old TestOneProcess).
        strs = _split_strings(body, 5)
        query, choices = strs[4], strs[:4]
        if sel & 0x40:
            limit = (sel & 0x1F) - 10  # -10..21, covers the old -10..10 range
            process.extract(query, choices, limit=limit)
        else:
            process.extractOne(query, choices)
    else:
        # fuzz.* scorer paths (the old TestOneCompare).
        scorer = SCORERS[sel & 0x07]
        s1, s2 = _split_strings(body, 2)
        scorer(s1, s2)
