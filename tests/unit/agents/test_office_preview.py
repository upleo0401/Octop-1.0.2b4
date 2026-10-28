from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

from octop.infra.agents.office_preview import dump_office


def test_doc_without_soffice(tmp_path: Path, monkeypatch: object) -> None:
    from octop.infra.agents import office_preview as mod

    monkeypatch.setattr(mod.shutil, "which", lambda _name: None)
    path = tmp_path / "old.doc"
    path.write_bytes(b"OLE")
    text = dump_office(path)
    assert "LibreOffice" in text
    assert path.name in text


def test_doc_with_mocked_soffice(tmp_path: Path, monkeypatch: object) -> None:
    from docx import Document

    from octop.infra.agents import office_preview as mod

    source = tmp_path / "old.doc"
    source.write_bytes(b"OLE")

    def fake_run(cmd: list[str], **_kwargs: object) -> SimpleNamespace:
        outdir = Path(cmd[cmd.index("--outdir") + 1])
        converted = outdir / "old.docx"
        document = Document()
        document.add_paragraph("从doc转来的文字")
        document.save(converted)
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(mod.shutil, "which", lambda name: "/usr/bin/soffice" if name == "soffice" else None)
    monkeypatch.setattr(mod.subprocess, "run", fake_run)
    text = dump_office(source)
    assert "从doc转来的文字" in text
