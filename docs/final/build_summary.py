#!/usr/bin/env python3
"""Build docs/final/OwoRail-portfolio-summary.pdf from summary.html with headless Chrome."""
from __future__ import annotations

import html
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUT = HERE / "OwoRail-portfolio-summary.pdf"
CHROME_PATHS = [r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
                "google-chrome", "chromium", "chrome"]


def figure(match: re.Match) -> str:
    path, caption = match.group(1).strip(), html.escape(match.group(2).strip())
    image = REPO / path
    if image.exists():
        body = f'<img src="{image.as_uri()}" alt="{caption}">'
    else:
        body = f'<div class="placeholder">Screenshot to add:<br>{html.escape(path)}</div>'
    return f"<figure>{body}<figcaption>{caption}</figcaption></figure>"


def chrome() -> str:
    for candidate in CHROME_PATHS:
        if Path(candidate).exists() or shutil.which(candidate):
            return candidate
    sys.exit("Chrome or Chromium not found")


def main() -> int:
    source = (HERE / "summary.html").read_text(encoding="utf-8")
    built = re.sub(r"<!--fig:([^|]+)\|(.+?)-->", figure, source)
    missing = len(re.findall("Screenshot to add", built))
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "summary.html"
        page.write_text(built, encoding="utf-8")
        subprocess.run([chrome(), "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                        f"--print-to-pdf={OUT}", page.as_uri()], check=True, capture_output=True)
    print(f"wrote {OUT.relative_to(REPO)}; screenshots still to add: {missing}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
