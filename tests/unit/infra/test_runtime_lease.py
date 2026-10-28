from __future__ import annotations

import pytest

from octop.infra.errors import ErrorCode, OctopError
from octop.infra.runtime_lease import acquire_lease, heartbeat_lease, release_lease


class _Settings:
    def __init__(self) -> None:
        self._data: dict[str, str] = {}

    def get(self, key: str) -> str | None:
        return self._data.get(key)

    def set(self, key: str, value: str) -> None:
        self._data[key] = value

    def delete(self, key: str) -> None:
        self._data.pop(key, None)


def test_acquire_blocks_other_node() -> None:
    settings = _Settings()
    acquire_lease(settings, user_id=1, node_id="a", now=1000)
    with pytest.raises(OctopError) as exc:
        acquire_lease(settings, user_id=1, node_id="b", now=1010)
    assert exc.value.code is ErrorCode.RUNTIME_IN_USE


def test_stale_lease_can_be_stolen() -> None:
    settings = _Settings()
    acquire_lease(settings, user_id=1, node_id="a", now=1000)
    acquire_lease(settings, user_id=1, node_id="b", now=1000 + 91)
    heartbeat_lease(settings, user_id=1, node_id="b", now=2000)
    release_lease(settings, user_id=1, node_id="a")
    acquire_lease(settings, user_id=1, node_id="b", now=2000)
