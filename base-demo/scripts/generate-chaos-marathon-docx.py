#!/usr/bin/env python3
"""Build Word document from chaos marathon markdown + JSON results."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
OPS = REPO / "docs" / "operations"
MD = OPS / "chaos-scenario-test-results.md"
JSON = OPS / "chaos-scenario-test-results.json"
OUT = OPS / "chaos-scenario-test-results.docx"


def _appendix_md(data: dict) -> str:
    lines = [
        "\\newpage",
        "",
        "# Appendix: metric samples (raw JSON data)",
        "",
        "Four samples per scenario during the 20-minute dwell window "
        "(every 5 minutes). Metrics from `index=otel_traces` on Splunk Enterprise.",
        "",
    ]
    for r in data.get("results", []):
        lines.append(f"## {r.get('name', r['id'])} (`{r['id']}`)")
        lines.append("")
        lines.append(
            f"- Outcome: **{r.get('outcome', '?')}** | "
            f"Inject: {'OK' if r.get('inject_ok') else 'FAIL'} | "
            f"Clear: {'OK' if r.get('clear_ok') else 'FAIL'}"
        )
        lines.append("")
        samples = r.get("samples") or []
        if not samples:
            lines.append("_No samples recorded._")
            lines.append("")
            continue
        lines.append(
            "| Time (s) | Gateway 5xx % | Gateway requests | "
            "Target errors | Target traces | Pods |"
        )
        lines.append(
            "|---------:|----------------:|-----------------:|"
            "--------------:|--------------:|-----:|"
        )
        for s in samples:
            gw = s.get("gateway_5xx_pct")
            gw_s = f"{gw:.1f}" if gw is not None else "—"
            gw_req = s.get("gateway_requests")
            gw_req_s = str(gw_req) if gw_req is not None else "—"
            te = s.get("target_errors")
            te_s = str(te) if te is not None else "—"
            tt = s.get("target_traces")
            tt_s = str(tt) if tt is not None else "—"
            pods = s.get("pods_ready") or "—"
            lines.append(
                f"| {s.get('at_s', '—')} | {gw_s} | {gw_req_s} | "
                f"{te_s} | {tt_s} | {pods} |"
            )
        lines.append("")
        if r.get("notes"):
            lines.append(f"**Notes:** {'; '.join(r['notes'])}")
            lines.append("")
    return "\n".join(lines)


def main() -> int:
    if not MD.is_file():
        print(f"missing {MD}", file=sys.stderr)
        return 1
    if not JSON.is_file():
        print(f"missing {JSON}", file=sys.stderr)
        return 1

    data = json.loads(JSON.read_text())
    appendix = _appendix_md(data)

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".md", delete=False, encoding="utf-8"
    ) as tmp:
        tmp.write(appendix)
        appendix_path = Path(tmp.name)

    try:
        subprocess.run(
            [
                "pandoc",
                str(MD),
                str(appendix_path),
                "-o",
                str(OUT),
                "--from",
                "markdown",
                "--to",
                "docx",
                "--metadata",
                f"title=NatWest Chaos Scenario Marathon Results",
                "--metadata",
                f"date={data['run'].get('ended_at', '')[:10]}",
            ],
            check=True,
        )
    finally:
        appendix_path.unlink(missing_ok=True)

    print(f"Wrote {OUT} ({OUT.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
