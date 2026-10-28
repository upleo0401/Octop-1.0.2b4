"""Block ``read_file`` on binary inbound attachments (PDF, Office, …).

``.xlsx`` / ``.xlsm`` on the workspace are previewed as TSV so chat
uploads are readable without dumping binary into the model context.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from langchain.agents.middleware import AgentMiddleware
from langchain_core.messages import ToolMessage
from langgraph.prebuilt.tool_node import ToolCallRequest
from langgraph.types import Command

from octop.infra.agents.office_preview import (
    IMAGE_EXTENSIONS,
    OFFICE_TEXT_EXTENSIONS,
    dump_office,
)

logger = logging.getLogger(__name__)

_READ_FILE_TOOL = "read_file"
_SPREADSHEET_EXTENSIONS = frozenset({".xlsx", ".xlsm"})
_BLOCKED_EXTENSIONS = frozenset(
    {
        ".pdf",
        ".doc",
        ".docx",
        ".xls",
        ".xlsx",
        ".ppt",
        ".pptx",
        ".zip",
        ".bin",
        ".gif",
        ".webp",
        ".jpg",
        ".jpeg",
        ".png",
    }
)
_TEXT_EXTENSIONS = frozenset(
    {
        ".txt",
        ".md",
        ".markdown",
        ".json",
        ".csv",
        ".py",
        ".ts",
        ".tsx",
        ".js",
        ".jsx",
        ".html",
        ".xml",
        ".yaml",
        ".yml",
        ".sql",
        ".sh",
    }
)


def _read_file_path_from_args(params: dict[str, Any]) -> str:
    for key in ("file_path", "path"):
        raw = params.get(key)
        if isinstance(raw, str) and raw.strip():
            return raw.strip()
    return ""


def _extension(path: str) -> str:
    cleaned = path.split("?", 1)[0].split("#", 1)[0]
    return Path(cleaned).suffix.lower()


def _is_inbound_attachment(path: str) -> bool:
    normalized = path.replace("\\", "/").lower()
    return normalized.startswith("inbound/") or "/inbound/" in normalized


def read_file_block_reason(path: str) -> str | None:
    """Return a rejection message when *path* must not be read via ``read_file``."""
    if not path:
        return None
    ext = _extension(path)
    if ext == ".pdf":
        return (
            f"read_file blocked for binary PDF `{path}`. "
            "Use execute_shell_command with the pdf skill (pdftotext, pdfplumber, etc.) instead."
        )
    if ext in _BLOCKED_EXTENSIONS:
        if ext in _SPREADSHEET_EXTENSIONS:
            return (
                f"read_file blocked for spreadsheet `{path}`. "
                "Run python with openpyxl on this workspace path "
                "(chat uploads live under inbound/ on the server)."
            )
        return (
            f"read_file blocked for binary file `{path}`. "
            "Use execute_shell_command or the matching skill instead."
        )
    if _is_inbound_attachment(path) and ext and ext not in _TEXT_EXTENSIONS:
        return (
            f"read_file blocked for inbound attachment `{path}`. "
            "Use execute_shell_command or the matching skill instead."
        )
    return None


def _workspace_file(workspace_dir: Path, path: str) -> Path | None:
    raw = path.replace("\\", "/").strip()
    if not raw:
        return None
    if raw.startswith("\\\\") or (len(raw) >= 2 and raw[1] == ":"):
        candidate = Path(path.strip())
        return candidate if candidate.is_file() else None
    rel = raw.lstrip("/")
    parts = [piece for piece in rel.split("/") if piece]
    if not parts or ".." in parts:
        return None
    try:
        root = workspace_dir.resolve()
        candidate = (root.joinpath(*parts)).resolve()
        candidate.relative_to(root)
    except (OSError, ValueError):
        return None
    if candidate.is_file():
        return candidate
    return None


def preview_spreadsheet_bytes(data: bytes, *, name: str = "workbook.xlsx") -> str:
    import tempfile

    suffix = Path(name).suffix.lower() or ".xlsx"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as handle:
        handle.write(data)
        tmp_path = Path(handle.name)
    try:
        text = preview_spreadsheet(tmp_path)
        marker = f"Spreadsheet: {tmp_path.name}"
        return text.replace(marker, f"Spreadsheet: {name}", 1)
    finally:
        tmp_path.unlink(missing_ok=True)


def preview_spreadsheet(path: Path) -> str:
    return dump_office(path)


class BinaryReadGuardMiddleware(AgentMiddleware[Any, Any]):
    """Reject read_file on PDF/Office inbound attachments before bytes hit context."""

    def __init__(self, workspace_dir: Path | str | None = None) -> None:
        super().__init__()
        self._workspace_dir = Path(workspace_dir) if workspace_dir else None

    def _workspace_hit(self, path: str) -> Path | None:
        if self._workspace_dir is None:
            return None
        return _workspace_file(self._workspace_dir, path)

    def _preview_message(self, path: str) -> str | None:
        ext = _extension(path)
        if ext not in OFFICE_TEXT_EXTENSIONS:
            return None
        found = self._workspace_hit(path)
        if found is None:
            return None
        try:
            return dump_office(found)
        except Exception as exc:  # noqa: BLE001
            logger.info("office preview failed for %s: %s", path, exc)
            return None

    async def awrap_tool_call(
        self,
        request: ToolCallRequest,
        handler: Callable[[ToolCallRequest], Awaitable[ToolMessage | Command[Any]]],
    ) -> ToolMessage | Command[Any]:
        tool_call = request.tool_call
        tool_name = str(tool_call.get("name") or "")
        if tool_name != _READ_FILE_TOOL:
            return await handler(request)

        params = tool_call.get("args") or {}
        if not isinstance(params, dict):
            params = {}
        path = _read_file_path_from_args(params)
        preview = self._preview_message(path)
        if preview is not None:
            return ToolMessage(
                content=preview,
                tool_call_id=str(tool_call.get("id") or ""),
            )
        ext = _extension(path)
        if ext in IMAGE_EXTENSIONS and self._workspace_hit(path) is not None:
            return await handler(request)
        reason = read_file_block_reason(path)
        if reason is None:
            return await handler(request)

        logger.info("BinaryReadGuard blocked read_file on %s", path)
        return ToolMessage(
            content=reason,
            tool_call_id=str(tool_call.get("id") or ""),
            status="error",
        )


__all__ = [
    "BinaryReadGuardMiddleware",
    "preview_spreadsheet",
    "preview_spreadsheet_bytes",
    "read_file_block_reason",
]
