"""Attach this process to one user's agents / cron / channels (shared PG)."""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from octop.infra.runtime_lease import (
    acquire_lease,
    heartbeat_lease,
    release_lease,
    runtime_node_id,
)

logger = logging.getLogger(__name__)

_HEARTBEAT_SECONDS = 30


def shared_control_plane(server: Any) -> bool:
    services = getattr(server, "services", None)
    if services is None:
        return False
    return str(services.db.dialect) == "postgresql"


async def attach_desktop_user(server: Any, user_id: int) -> None:
    """Start this user's runtime on a shared control plane. No-op for SQLite."""
    if not shared_control_plane(server) or server.app_runtime is None:
        return
    node_id = runtime_node_id(server.paths.root)
    acquire_lease(server.services.settings_repo, user_id=user_id, node_id=node_id)
    attached: set[int] = getattr(server, "_desktop_attached_users", set())
    attached.add(int(user_id))
    server._desktop_attached_users = attached
    registry = server.app_runtime.agent_registry
    await registry.start_agents_for_user(user_id)
    await server.app_runtime.cron_manager.attach_user(user_id)
    await server.app_runtime.gateway.attach_user_channels(user_id)
    await server.app_runtime.proactive_scheduler.start_for_user(user_id)
    _ensure_heartbeat(server, user_id, node_id)


async def detach_desktop_user(server: Any, user_id: int) -> None:
    if not shared_control_plane(server) or server.app_runtime is None:
        return
    node_id = runtime_node_id(server.paths.root)
    tasks: dict[int, asyncio.Task[None]] = getattr(server, "_desktop_heartbeats", {})
    task = tasks.pop(int(user_id), None)
    if task is not None:
        task.cancel()
    attached: set[int] = getattr(server, "_desktop_attached_users", set())
    attached.discard(int(user_id))
    try:
        await server.app_runtime.gateway.detach_user_channels(user_id)
        await server.app_runtime.cron_manager.detach_user(user_id)
        await server.app_runtime.agent_registry.unload_agents_for_user(user_id)
        server.app_runtime.proactive_scheduler.stop_for_user(user_id)
    finally:
        release_lease(server.services.settings_repo, user_id=user_id, node_id=node_id)


async def detach_all_desktop_users(server: Any) -> None:
    attached = list(getattr(server, "_desktop_attached_users", set()))
    for user_id in attached:
        try:
            await detach_desktop_user(server, int(user_id))
        except Exception:
            logger.exception("detach desktop user %s failed", user_id)


def _ensure_heartbeat(server: Any, user_id: int, node_id: str) -> None:
    tasks: dict[int, asyncio.Task[None]] = getattr(server, "_desktop_heartbeats", {})
    existing = tasks.get(int(user_id))
    if existing is not None and not existing.done():
        return

    async def _loop() -> None:
        try:
            while True:
                await asyncio.sleep(_HEARTBEAT_SECONDS)
                heartbeat_lease(
                    server.services.settings_repo,
                    user_id=user_id,
                    node_id=node_id,
                )
        except asyncio.CancelledError:
            return

    tasks[int(user_id)] = asyncio.create_task(_loop(), name=f"desktop-lease-{user_id}")
    server._desktop_heartbeats = tasks
