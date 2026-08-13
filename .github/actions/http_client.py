"""Shared HTTP client for generated-data jobs."""

from __future__ import annotations

from typing import Any

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

DEFAULT_TIMEOUT = (10, 30)


def build_session() -> requests.Session:
    retry = Retry(
        total=3,
        connect=3,
        read=3,
        status=3,
        backoff_factor=0.75,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset({"GET", "HEAD"}),
        respect_retry_after_header=True,
    )
    adapter = HTTPAdapter(max_retries=retry)
    session = requests.Session()
    session.headers["User-Agent"] = "MOFA-generated-data/1.0"
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    return session


_SESSION = build_session()


def get(url: str, **kwargs: Any) -> requests.Response:
    """GET with bounded timeouts and retry behavior unless explicitly overridden."""
    kwargs.setdefault("timeout", DEFAULT_TIMEOUT)
    return _SESSION.get(url, **kwargs)
