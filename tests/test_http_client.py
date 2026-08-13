from __future__ import annotations

import http_client


class FakeSession:
    def __init__(self) -> None:
        self.calls = []

    def get(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return object()


def test_get_supplies_bounded_default_timeout(monkeypatch):
    fake = FakeSession()
    monkeypatch.setattr(http_client, "_SESSION", fake)
    http_client.get("https://example.test/data")
    assert fake.calls == [
        ("https://example.test/data", {"timeout": http_client.DEFAULT_TIMEOUT})
    ]


def test_get_preserves_explicit_timeout(monkeypatch):
    fake = FakeSession()
    monkeypatch.setattr(http_client, "_SESSION", fake)
    http_client.get("https://example.test/data", timeout=5)
    assert fake.calls[0][1]["timeout"] == 5


def test_session_retries_transient_statuses():
    session = http_client.build_session()
    retries = session.get_adapter("https://").max_retries
    assert retries.total == 3
    assert 429 in retries.status_forcelist
    assert 503 in retries.status_forcelist
