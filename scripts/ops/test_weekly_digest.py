"""synthesise() must refuse an incomplete model answer instead of returning it.

Only the HTTP transport is faked; synthesise() itself runs unmodified.
Run: python3 -m pytest scripts/ops/test_weekly_digest.py
"""
import io
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(__file__))
import weekly_digest as wd  # noqa: E402

PRS = [{"repo": "r", "title": "t", "url": "u"}]


def _answer(monkeypatch, payload):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "x")
    monkeypatch.setattr(wd.urllib.request, "urlopen",
                        lambda req, timeout: io.BytesIO(json.dumps(payload).encode()))


@pytest.mark.parametrize("stop", ["max_tokens", "refusal"])
def test_incomplete_answer_raises(monkeypatch, stop):
    _answer(monkeypatch, {"stop_reason": stop,
                          "content": [{"type": "text", "text": "<ul><li>cut"}]})
    with pytest.raises(RuntimeError, match=stop):
        wd.synthesise(PRS, "2026-09-21", "m")


def test_empty_answer_raises(monkeypatch):
    _answer(monkeypatch, {"stop_reason": "end_turn", "content": []})
    with pytest.raises(RuntimeError):
        wd.synthesise(PRS, "2026-09-21", "m")


def test_complete_answer_is_returned(monkeypatch):
    _answer(monkeypatch, {"stop_reason": "end_turn",
                          "content": [{"type": "text", "text": " <p>ok</p> "}]})
    assert wd.synthesise(PRS, "2026-09-21", "m") == "<p>ok</p>"
