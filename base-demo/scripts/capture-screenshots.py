#!/usr/bin/env python3
"""Headless capture of UI panels for the exec top-down deck.

Reads ``scripts/lib/exec_topdown_screenshots.json`` and produces one PNG
per panel under ``docs/presentation/screenshots/<panel_id>.png``. Those
files are then picked up automatically by
``scripts/generate-deck.py --profile exec-topdown``, which switches the
relevant timeline slides to a bullets + screenshot layout when a PNG is
present and falls back to text-only otherwise.

Two auth surfaces are supported:

  * ``enterprise``    - Splunk Web (ITSI). Username defaults to ``admin``.
                        Password from ``TF_VAR_splunk_enterprise_admin_password``
                        (or ``SPLUNK_ENTERPRISE_ADMIN_PASSWORD``). Host
                        from terraform output ``splunk_enterprise_web_url``
                        (or env ``SPLUNK_ENTERPRISE_WEB_URL``).
  * ``observability`` - Splunk Observability Cloud. The web UI requires
                        SSO/MFA so we **do not** automate the login.
                        Instead, run once interactively to record a
                        storage-state file:

                            python3 scripts/capture-screenshots.py login \\
                              --surface observability \\
                              --realm <eu0|us1|...> \\
                              --state-file ~/.cache/splunk-obs-state.json

                        A browser window will open; complete SSO + MFA;
                        the cookies are persisted. Subsequent capture
                        runs reuse the state automatically (env var
                        ``SPLUNK_OBSERVABILITY_STATE_FILE``).

Usage:

  # capture every panel for which the surface is reachable
  python3 scripts/capture-screenshots.py capture

  # capture only the four enterprise (ITSI) panels - works without
  # storage state for Observability
  python3 scripts/capture-screenshots.py capture --only-surface enterprise

  # record Observability cookies once (opens a real browser)
  python3 scripts/capture-screenshots.py login --surface observability \\
    --realm eu0

Output: ``docs/presentation/screenshots/<panel_id>.png``. Files are
gitignored.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    from playwright.async_api import async_playwright, TimeoutError as PWTimeout
except ImportError as e:  # pragma: no cover
    sys.stderr.write(
        "playwright is required. Install with: "
        ".venv/bin/pip install playwright && "
        ".venv/bin/python3 -m playwright install --with-deps chromium\n"
    )
    raise SystemExit(1) from e

# Optional .env loader so the script picks up TF_VAR_ values without the
# operator having to re-export them every shell.
try:
    from dotenv import load_dotenv

    load_dotenv(dotenv_path=Path(__file__).resolve().parent.parent / ".env")
except ImportError:
    pass

logging.basicConfig(format="%(asctime)s %(levelname)-7s %(message)s", level=logging.INFO)
log = logging.getLogger("capture-screenshots")

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = REPO_ROOT / "scripts" / "lib" / "exec_topdown_screenshots.json"
OUTPUT_DIR = REPO_ROOT / "docs" / "presentation" / "screenshots"
DEFAULT_OBS_STATE = Path.home() / ".cache" / "splunk-obs-state.json"


@dataclass
class Panel:
    id: str
    surface: str
    url_path: str
    viewport: dict[str, int]
    settle_ms: int
    wait_selector: str | None = None
    scroll_to_selector: str | None = None
    full_page: bool = False
    fallback_url_paths: list[str] | None = None


def _load_panels() -> list[Panel]:
    with open(CONFIG_PATH, "r", encoding="utf-8") as fh:
        raw = json.load(fh)
    panels: list[Panel] = []
    for p in raw.get("panels", []):
        panels.append(
            Panel(
                id=p["id"],
                surface=p["surface"],
                url_path=p["url_path"],
                viewport=p.get("viewport", {"width": 1920, "height": 1200}),
                settle_ms=int(p.get("settle_ms", 5000)),
                wait_selector=p.get("wait_selector"),
                scroll_to_selector=p.get("scroll_to_selector"),
                full_page=bool(p.get("full_page", False)),
                fallback_url_paths=p.get("fallback_url_paths"),
            )
        )
    return panels


def _enterprise_base_url() -> str:
    """Resolve the Splunk Web base URL for the enterprise surface.

    Precedence: explicit env ``SPLUNK_ENTERPRISE_WEB_URL``, then
    terraform output ``splunk_enterprise_web_url``. Aborts loudly if
    neither is set; we deliberately avoid silently falling back to
    ``localhost`` because that would 200 against an unrelated service.
    """
    env_url = os.environ.get("SPLUNK_ENTERPRISE_WEB_URL", "").strip()
    if env_url:
        return env_url.rstrip("/")
    # Lazy import; terraform call is the slow path.
    import subprocess

    try:
        out = subprocess.check_output(
            ["terraform", "-chdir=terraform", "output", "-raw",
             "splunk_enterprise_web_url"],
            stderr=subprocess.DEVNULL, text=True, cwd=REPO_ROOT,
        ).strip()
    except Exception as e:
        raise SystemExit(
            f"could not resolve Splunk Enterprise web URL: {e}. "
            "Set SPLUNK_ENTERPRISE_WEB_URL or run 'terraform apply' first."
        )
    if not out:
        raise SystemExit(
            "splunk_enterprise_web_url is empty. Set SPLUNK_ENTERPRISE_WEB_URL."
        )
    return out.rstrip("/")


def _observability_base_url(realm: str | None) -> str:
    realm = (realm or os.environ.get("SPLUNK_REALM", "")).strip()
    if not realm:
        raise SystemExit(
            "SPLUNK_REALM is required for the observability surface "
            "(e.g. 'eu0', 'us1'). Set SPLUNK_REALM or pass --realm."
        )
    return f"https://app.{realm}.signalfx.com"


# ---------------------------------------------------------------------------
# Enterprise (Splunk Web / ITSI) auth + capture
# ---------------------------------------------------------------------------


async def _enterprise_login(context: Any, base_url: str) -> None:
    """Submit the Splunk Web login form. Idempotent: a no-op if already
    authenticated (we detect that by checking for the post-login
    Splunk app shell selector before submitting the form)."""
    password = os.environ.get(
        "SPLUNK_ENTERPRISE_ADMIN_PASSWORD",
        os.environ.get("TF_VAR_splunk_enterprise_admin_password", ""),
    ).strip()
    if not password:
        raise SystemExit(
            "missing SPLUNK_ENTERPRISE_ADMIN_PASSWORD (or "
            "TF_VAR_splunk_enterprise_admin_password) in the environment."
        )
    username = os.environ.get("SPLUNK_ENTERPRISE_ADMIN_USER", "admin").strip()
    page = await context.new_page()
    try:
        await page.goto(
            f"{base_url}/en-US/account/login",
            wait_until="networkidle", timeout=20_000,
        )
        # If already logged in, Splunk redirects away from /account/login.
        if "/account/login" not in page.url:
            log.info("enterprise auth: session already valid (%s)", page.url)
            return
        # Wait for the login form to be interactive. Splunk Web is a SPA
        # so the inputs only bind after the React tree mounts.
        await page.wait_for_selector(
            "input[name=username]", state="visible", timeout=15_000,
        )
        await page.fill("input[name=username]", username)
        await page.fill("input[name=password]", password)
        # Splunk Web's submit is an <input type="submit"> (NOT a button),
        # with no name/id. The cval hidden input is auto-populated from
        # the cval cookie - we don't need to set it. Try selectors in
        # order of specificity, then fall back to pressing Enter.
        submit_selectors = [
            "input[type=submit]",
            "button[type=submit]",
            "input.splButton-primary",
            "button.splButton-primary",
        ]
        submitted = False
        for sel in submit_selectors:
            try:
                await page.click(sel, timeout=1_500)
                submitted = True
                break
            except PWTimeout:
                continue
        if not submitted:
            await page.press("input[name=password]", "Enter")
        # Splunk redirects on success: /account/login -> /app/<default>.
        # Wait for the URL to change away from the login path; netidle
        # alone is insufficient because the form post returns 200 JSON
        # and the JS then triggers the navigation.
        try:
            await page.wait_for_url(
                lambda url: "/account/login" not in url, timeout=15_000,
            )
        except PWTimeout:
            # Final fallback: at least let any in-flight requests settle.
            await page.wait_for_load_state("networkidle", timeout=10_000)
        if "/account/login" in page.url:
            raise SystemExit(
                f"enterprise auth: still on login page after submit "
                f"({page.url}). Check the admin password "
                f"(TF_VAR_splunk_enterprise_admin_password / "
                f"SPLUNK_ENTERPRISE_ADMIN_PASSWORD)."
            )
        log.info("enterprise auth: login OK; landed on %s", page.url)
    finally:
        await page.close()


async def _capture_one(context: Any, base_url: str, panel: Panel) -> Path | None:
    """Navigate, wait, and screenshot one panel. Returns the output path
    or None on failure (logged, not raised, so other panels still run)."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUTPUT_DIR / f"{panel.id}.png"
    url_paths = [panel.url_path] + (panel.fallback_url_paths or [])
    page = await context.new_page()
    try:
        await page.set_viewport_size(panel.viewport)
        last_error: str | None = None
        for path in url_paths:
            url = path if path.startswith("http") else f"{base_url}{path}"
            log.info("[%s] navigating to %s", panel.id, url)
            try:
                resp = await page.goto(url, wait_until="domcontentloaded", timeout=30_000)
                status = resp.status if resp else 0
                if status >= 400:
                    last_error = f"HTTP {status}"
                    log.warning("[%s] %s -> %s, trying fallback", panel.id, url, last_error)
                    continue
                if panel.wait_selector:
                    try:
                        await page.wait_for_selector(
                            panel.wait_selector.split(",")[0].strip(),
                            timeout=15_000,
                        )
                    except PWTimeout:
                        # Best-effort: continue even if the selector
                        # didn't appear; settle_ms below gives the
                        # dashboard one more chance.
                        log.warning(
                            "[%s] wait_selector '%s' did not appear; falling "
                            "back to settle_ms wait",
                            panel.id, panel.wait_selector,
                        )
                if panel.scroll_to_selector:
                    for sel in [s.strip() for s in panel.scroll_to_selector.split(",")]:
                        try:
                            await page.locator(sel).first.scroll_into_view_if_needed(
                                timeout=5_000,
                            )
                            break
                        except Exception:
                            continue
                await page.wait_for_timeout(panel.settle_ms)
                await page.screenshot(path=str(out_path), full_page=panel.full_page)
                log.info("[%s] wrote %s (%d KB)", panel.id, out_path,
                         out_path.stat().st_size // 1024)
                return out_path
            except PWTimeout as e:
                last_error = f"timeout: {e}"
                continue
            except Exception as e:  # noqa: BLE001
                last_error = f"{type(e).__name__}: {e}"
                continue
        log.error("[%s] all url paths exhausted (last error: %s)",
                  panel.id, last_error)
        return None
    finally:
        await page.close()


# ---------------------------------------------------------------------------
# Observability (SignalFx) capture - cookie-jar based
# ---------------------------------------------------------------------------


async def _observability_login(state_file: Path, realm: str) -> None:
    """Open an interactive Chromium window so the operator can complete
    SSO + MFA. Persists cookies + localStorage to ``state_file``."""
    base = _observability_base_url(realm)
    state_file.parent.mkdir(parents=True, exist_ok=True)
    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=False)
        context = await browser.new_context()
        page = await context.new_page()
        await page.goto(base, wait_until="domcontentloaded")
        print(
            "\n>>> Complete SSO and MFA in the opened browser window.\n"
            ">>> When you see the Splunk Observability home page, return "
            "to this terminal and press Enter.\n",
            flush=True,
        )
        # Block on operator confirmation. Playwright's page is alive in
        # the meantime; the user can navigate freely.
        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, input, "press Enter when logged in: ")
        await context.storage_state(path=str(state_file))
        log.info("wrote observability state to %s", state_file)
        await context.close()
        await browser.close()


# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------


async def _capture(only_surface: str | None) -> int:
    panels = _load_panels()
    enterprise_panels = [p for p in panels if p.surface == "enterprise"]
    observability_panels = [p for p in panels if p.surface == "observability"]
    if only_surface == "enterprise":
        observability_panels = []
    if only_surface == "observability":
        enterprise_panels = []

    captured: list[Path] = []
    skipped: list[str] = []

    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True)

        # --- enterprise / ITSI ----------------------------------------
        if enterprise_panels:
            base_url = _enterprise_base_url()
            log.info("enterprise base url: %s", base_url)
            ctx_kwargs: dict[str, Any] = {
                "viewport": {"width": 1920, "height": 1200},
                "ignore_https_errors": True,
            }
            context = await browser.new_context(**ctx_kwargs)
            try:
                await _enterprise_login(context, base_url)
                for panel in enterprise_panels:
                    out = await _capture_one(context, base_url, panel)
                    if out:
                        captured.append(out)
                    else:
                        skipped.append(panel.id)
            finally:
                await context.close()

        # --- observability / SignalFx ---------------------------------
        if observability_panels:
            state_env = os.environ.get(
                "SPLUNK_OBSERVABILITY_STATE_FILE",
                str(DEFAULT_OBS_STATE),
            )
            state_path = Path(state_env).expanduser()
            if not state_path.exists():
                log.warning(
                    "observability storage-state not found at %s. "
                    "Run: python3 scripts/capture-screenshots.py login "
                    "--surface observability --realm <realm>. "
                    "Skipping %d observability panel(s).",
                    state_path, len(observability_panels),
                )
                skipped.extend(p.id for p in observability_panels)
            else:
                realm = os.environ.get("SPLUNK_REALM", "").strip()
                if not realm:
                    log.warning(
                        "SPLUNK_REALM is not set; skipping observability "
                        "panels."
                    )
                    skipped.extend(p.id for p in observability_panels)
                else:
                    base_url = _observability_base_url(realm)
                    log.info("observability base url: %s", base_url)
                    context = await browser.new_context(
                        viewport={"width": 1920, "height": 1200},
                        storage_state=str(state_path),
                        ignore_https_errors=True,
                    )
                    try:
                        for panel in observability_panels:
                            out = await _capture_one(context, base_url, panel)
                            if out:
                                captured.append(out)
                            else:
                                skipped.append(panel.id)
                    finally:
                        await context.close()

        await browser.close()

    log.info("done. captured %d panel(s); skipped %d.", len(captured), len(skipped))
    if skipped:
        log.info("skipped: %s", ", ".join(skipped))
    return 0 if captured else 4


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub_cap = sub.add_parser("capture", help="capture every panel in the config")
    sub_cap.add_argument(
        "--only-surface",
        choices=["enterprise", "observability"],
        default=None,
        help="Restrict capture to a single auth surface. Useful when "
             "the observability storage state is not yet recorded.",
    )

    sub_login = sub.add_parser(
        "login",
        help="record a Playwright storage-state file by completing SSO "
             "interactively. Required once before observability capture.",
    )
    sub_login.add_argument(
        "--surface", choices=["observability"], required=True,
    )
    sub_login.add_argument("--realm", default=os.environ.get("SPLUNK_REALM", ""))
    sub_login.add_argument(
        "--state-file",
        default=str(DEFAULT_OBS_STATE),
        help=f"output storage-state path (default: {DEFAULT_OBS_STATE})",
    )

    args = parser.parse_args()
    if args.cmd == "capture":
        return asyncio.run(_capture(args.only_surface))
    if args.cmd == "login":
        if args.surface != "observability":
            log.error("unsupported login surface: %s", args.surface)
            return 2
        asyncio.run(_observability_login(Path(args.state_file).expanduser(), args.realm))
        return 0
    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
