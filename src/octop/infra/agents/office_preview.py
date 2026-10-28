"""Extract text from chat-upload Office/PDF files on the company server."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

MAX_CHARS = 24_000
MAX_ROWS = 80
MAX_COLS = 30

OFFICE_TEXT_EXTENSIONS = frozenset(
    {".xlsx", ".xlsm", ".xls", ".docx", ".pptx", ".pdf", ".doc", ".ppt"}
)
IMAGE_EXTENSIONS = frozenset({".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"})


def clip(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if len(text) > MAX_CHARS:
        return text[:MAX_CHARS] + "\n... (truncated)"
    return text


def dump_office(path: Path) -> str:
    ext = path.suffix.lower()
    if ext in {".xlsx", ".xlsm"}:
        return _dump_xlsx(path)
    if ext == ".xls":
        return _dump_xls(path)
    if ext == ".docx":
        return _dump_docx(path)
    if ext == ".pptx":
        return _dump_pptx(path)
    if ext == ".pdf":
        return _dump_pdf(path)
    if ext in {".doc", ".ppt"}:
        return _dump_legacy_office(path)
    raise ValueError(f"unsupported type {ext}")


def _dump_xlsx(path: Path) -> str:
    from openpyxl import load_workbook

    wb = load_workbook(path, read_only=True, data_only=True)
    parts = [f"Spreadsheet: {path.name}"]
    try:
        for name in wb.sheetnames:
            sheet = wb[name]
            parts.append(f"\n## Sheet: {name}")
            for index, row in enumerate(sheet.iter_rows(values_only=True)):
                if index >= MAX_ROWS:
                    parts.append("... (truncated rows)")
                    break
                cells = ["" if cell is None else str(cell) for cell in row[:MAX_COLS]]
                parts.append("\t".join(cells))
                if sum(len(item) for item in parts) > MAX_CHARS:
                    parts.append("... (truncated)")
                    return "\n".join(parts)
        return "\n".join(parts)
    finally:
        wb.close()


def _dump_xls(path: Path) -> str:
    import xlrd

    book = xlrd.open_workbook(str(path))
    parts = [f"Spreadsheet: {path.name}"]
    for sheet in book.sheets():
        parts.append(f"\n## Sheet: {sheet.name}")
        rows = min(sheet.nrows, MAX_ROWS)
        for row_idx in range(rows):
            cells = [
                str(sheet.cell_value(row_idx, col)) for col in range(min(sheet.ncols, MAX_COLS))
            ]
            parts.append("\t".join(cells))
        if sheet.nrows > MAX_ROWS:
            parts.append("... (truncated rows)")
        if sum(len(item) for item in parts) > MAX_CHARS:
            parts.append("... (truncated)")
            break
    return "\n".join(parts)


def _dump_docx(path: Path) -> str:
    from docx import Document

    doc = Document(str(path))
    parts = [f"Document: {path.name}"]
    for para in doc.paragraphs:
        if para.text.strip():
            parts.append(para.text)
    for table in doc.tables:
        parts.append("")
        for row in table.rows:
            parts.append("\t".join(cell.text.strip() for cell in row.cells))
    return clip("\n".join(parts))


def _dump_pptx(path: Path) -> str:
    from pptx import Presentation

    prs = Presentation(str(path))
    parts = [f"Presentation: {path.name}"]
    for index, slide in enumerate(prs.slides, start=1):
        parts.append(f"\n## Slide {index}")
        for shape in slide.shapes:
            if shape.has_text_frame:
                text = shape.text_frame.text.strip()
                if text:
                    parts.append(text)
            if getattr(shape, "has_table", False):
                table = shape.table
                for row in table.rows:
                    parts.append("\t".join(cell.text.strip() for cell in row.cells))
        if sum(len(item) for item in parts) > MAX_CHARS:
            parts.append("... (truncated)")
            break
    return clip("\n".join(parts))


def _soffice_bin() -> str | None:
    return shutil.which("soffice") or shutil.which("libreoffice")


def _dump_legacy_office(path: Path) -> str:
    target = ".docx" if path.suffix.lower() == ".doc" else ".pptx"
    soffice = _soffice_bin()
    if soffice is None:
        return (
            f"{path.name}: cannot parse {path.suffix} without LibreOffice (soffice) "
            f"or Microsoft Office. Save as {target} and try again."
        )
    try:
        converted = _soffice_convert(path, target, soffice)
    except RuntimeError as exc:
        return str(exc)
    try:
        if target == ".docx":
            return _dump_docx(converted)
        return _dump_pptx(converted)
    finally:
        converted.unlink(missing_ok=True)
        if converted.parent.exists():
            shutil.rmtree(converted.parent, ignore_errors=True)


def _soffice_convert(path: Path, target_ext: str, soffice: str) -> Path:
    outdir = Path(tempfile.mkdtemp(prefix="octop-soffice-"))
    env = {**os.environ, "HOME": str(outdir), "SAL_USE_VCLPLUGIN": "svp"}
    fmt = "docx" if target_ext == ".docx" else "pptx"
    try:
        subprocess.run(
            [
                soffice,
                "--headless",
                "--norestore",
                "--nolockcheck",
                "--convert-to",
                fmt,
                "--outdir",
                str(outdir),
                str(path),
            ],
            check=True,
            capture_output=True,
            timeout=90,
            env=env,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        shutil.rmtree(outdir, ignore_errors=True)
        raise RuntimeError(f"LibreOffice failed to convert {path.name}: {exc}") from exc
    matches = sorted(outdir.glob(f"*{target_ext}"))
    if not matches:
        shutil.rmtree(outdir, ignore_errors=True)
        raise RuntimeError(f"LibreOffice produced no {target_ext} for {path.name}")
    return matches[0]


def _dump_pdf(path: Path) -> str:
    from pypdf import PdfReader

    reader = PdfReader(str(path))
    parts = [f"PDF: {path.name} ({len(reader.pages)} pages)"]
    for index, page in enumerate(reader.pages, start=1):
        text = (page.extract_text() or "").strip()
        parts.append(f"\n## Page {index}")
        parts.append(text)
        if sum(len(item) for item in parts) > MAX_CHARS:
            parts.append("... (truncated)")
            break
    return clip("\n".join(parts))
