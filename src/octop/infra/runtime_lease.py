"""One live desktop runtime per user on a shared PostgreSQL control plane."""

from __future__ import annotations

import json
import time
import uuid
from pathlib import Path
from typing import Any

from octop.infra.errors import ErrorCode, OctopError

LEASE_TTL_SECONDS = 90
_KEY_PREFIX = "desktop_runtime_lease:"


def lease_key(user_id: int) -> str:
    return f"{_KEY_PREFIX}{int(user_id)}"


def runtime_node_id(root: Path) -> str:
    path = Path(root) / "runtime_node_id"
    if path.is_file():
        text = path.read_text(encoding="utf-8").strip()
        if text:
            return text
    node_id = uuid.uuid4().hex
    path.write_text(node_id, encoding="utf-8")
    return node_id


def _parse(raw: str | None) -> dict[str, Any] | None:
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict):
        return None
    return data


def acquire_lease(
    settings: Any,
    *,
    user_id: int,
    node_id: str,
    now: int | None = None,
) -> None:
    """Claim this user for *node_id*, or steal a stale lease.

    Raises ``RUNTIME_IN_USE`` when another live node holds the user.
    """
    stamp = int(now if now is not None else time.time())
    key = lease_key(user_id)
    current = _parse(settings.get(key))
    if current is not None:
        held = str(current.get("node_id") or "")
        seen = int(current.get("heartbeat") or 0)
        if held and held != node_id and stamp - seen < LEASE_TTL_SECONDS:
            host = str(current.get("hostname") or held)
            raise OctopError(
                ErrorCode.RUNTIME_IN_USE,
                "this account is already signed in on another computer",
                details={"node_id": held, "hostname": host},
            )
    settings.set(
        key,
        json.dumps({"node_id": node_id, "heartbeat": stamp}, separators=(",", ":")),
    )


def heartbeat_lease(
    settings: Any,
    *,
    user_id: int,
    node_id: str,
    now: int | None = None,
) -> None:
    acquire_lease(settings, user_id=user_id, node_id=node_id, now=now)


def release_lease(settings: Any, *, user_id: int, node_id: str) -> None:
    key = lease_key(user_id)
    current = _parse(settings.get(key))
    if current is None:
        return
    if str(current.get("node_id") or "") != node_id:
        return
    settings.delete(key)
