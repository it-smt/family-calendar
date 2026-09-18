"""The expansion algorithm, run against the standard's answers.

There is no Swift toolchain here, so `recurrence_transcription.py` holds the
same algorithm in the same shape as the Swift. Running it against fixtures that
python-dateutil has already validated tests the part that can actually be wrong
in a subtle way — the loop, the period boundaries, the skipped months — and
leaves Xcode to catch anything that is merely Swift.
"""

from __future__ import annotations

import pytest

from tests.recurrence_transcription import occurrences
from tests.test_recurrence_fixtures import CASES, wire


@pytest.mark.parametrize("case", CASES, ids=[case["name"] for case in CASES])
def test_the_transcribed_algorithm_matches_the_fixture(case):
    assert [wire(moment) for moment in occurrences(case)] == case["expected"]
