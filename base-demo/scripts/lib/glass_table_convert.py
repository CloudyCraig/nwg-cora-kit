#!/usr/bin/env python3
"""Convert the NatWest Card Payments Simple XML dashboard into a native ITSI
Glass Table v3 (Dashboard Studio JSON) object.

Why this exists
---------------
The Simple XML at ``itsi/glass-table/natwest-payments-overview.xml`` renders
beautifully under Splunk Web -> ITSI app -> Dashboards. Executives, however,
look for "Glass Tables" under Service Insights -> Glass Tables, which only
lists *native* ITSI ``glass_table`` objects. Native Glass Tables (v3) are
backed by Dashboard Studio JSON definitions.

This converter:
  1. Parses the Simple XML.
  2. Maps each <single>, <chart>, <table>, <map>, <html> panel to a
     Dashboard Studio visualization JSON.
  3. Lays the panels out in absolute positioning, row-by-row.
  4. Wraps the result in an ITSI ``glass_table`` REST envelope.
  5. Either prints the JSON to stdout or returns the dict for use by
     ``itsi_bootstrap.py``.

Run:
  python3 scripts/lib/glass_table_convert.py \
      --xml itsi/glass-table/natwest-payments-overview.xml \
      --out itsi/glass-table/natwest-payments-overview.glass-table.json
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import sys
import uuid
import xml.etree.ElementTree as ET
from functools import lru_cache
from pathlib import Path
from typing import Any

# Path to the world-countries SVG used by every splunk.choropleth.svg viz
# this converter produces. Resolved relative to the repository root so the
# converter works whether invoked from CI, scripts/, or an ad-hoc REPL.
_REPO_ROOT = Path(__file__).resolve().parents[2]
_WORLD_SVG_PATH = _REPO_ROOT / "splunk-apps" / "leaflet_maps_server" \
    / "appserver" / "static" / "world_countries.svg"


@lru_cache(maxsize=1)
def _load_world_svg_data_uri() -> str:
    """Return the world_countries.svg as a base64 data: URI for inlining
    into the Dashboard Studio choropleth viz's required `svg` option.

    Falls back to an empty 1x1 SVG if the file is missing so the converter
    never crashes during regen — the viz will just render empty rather
    than refusing to load.
    """
    if not _WORLD_SVG_PATH.is_file():
        fallback = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"/>'
        return "data:image/svg+xml;base64," + base64.b64encode(fallback).decode()
    raw = _WORLD_SVG_PATH.read_bytes()
    return "data:image/svg+xml;base64," + base64.b64encode(raw).decode()

# ---------------------------------------------------------------------------
# Layout constants
# ---------------------------------------------------------------------------
CANVAS_WIDTH        = 1920
CANVAS_BACKGROUND   = "#0d1729"          # dark navy aligned with itsi theme
ROW_GAP             = 12
PANEL_GAP           = 12

# Per-viz-type heights (px)
H_HTML              = 56
H_HTML_BANNER       = 140
H_SINGLE            = 200
H_CHART             = 300
H_TABLE             = 360
H_MAP               = 460


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _vid() -> str:
    return "viz_" + uuid.uuid4().hex[:12]


def _did() -> str:
    return "ds_" + uuid.uuid4().hex[:12]


def _coerce_color(raw: str | None) -> str | None:
    """Translate ``0xRRGGBB`` -> ``#RRGGBB``, or pass through if already
    hash-prefixed. Returns None when input is empty.
    """
    if not raw:
        return None
    raw = raw.strip()
    if raw.startswith("0x") or raw.startswith("0X"):
        return "#" + raw[2:].upper()
    if raw.startswith("#"):
        return raw.upper()
    # 6-hex without prefix
    if re.fullmatch(r"[0-9a-fA-F]{6}", raw):
        return "#" + raw.upper()
    return raw


def _coerce_color_list(raw: str | None) -> list[str]:
    """Parse ``["0xAAA","0xBBB"]`` style strings into hex colors."""
    if not raw:
        return []
    try:
        items = json.loads(raw)
    except (TypeError, ValueError):
        return []
    out: list[str] = []
    for x in items:
        c = _coerce_color(str(x))
        if c:
            out.append(c)
    return out


def _coerce_float_list(raw: str | None) -> list[float]:
    if not raw:
        return []
    try:
        items = json.loads(raw)
    except (TypeError, ValueError):
        return []
    return [float(x) for x in items]


def _opt_map(elem: ET.Element) -> dict[str, str]:
    """Return ``{name: text}`` for <option name="..."> children, trimmed."""
    out: dict[str, str] = {}
    for o in elem.findall("option"):
        name = o.get("name")
        if not name:
            continue
        out[name] = (o.text or "").strip()
    return out


def _search_block(viz: ET.Element) -> dict[str, str | None]:
    """Pull a <search> child's query/earliest/latest/refresh into a dict.
    Falls back to placeholder zeros so the dashboard still renders if the
    panel author left a search out (it never should, but we are defensive).
    """
    s = viz.find("search")
    if s is None:
        return {"query": "| stats count", "earliest": "-15m", "latest": "now"}
    return {
        "query":    (s.findtext("query") or "| stats count").strip(),
        "earliest": (s.findtext("earliest") or "-15m").strip(),
        "latest":   (s.findtext("latest") or "now").strip(),
        "refresh":  (s.findtext("refresh") or None),
    }


def _make_search_ds(query: str, earliest: str, latest: str,
                    refresh: str | None = None) -> dict[str, Any]:
    """Build a ``ds.search`` dataSource definition."""
    opts: dict[str, Any] = {
        "query": query,
        "queryParameters": {
            "earliest": earliest,
            "latest":   latest,
        },
    }
    if refresh:
        # Dashboard Studio uses refresh as a top-level option on ds.search.
        opts["refresh"] = refresh
        opts["refreshType"] = "delay"
    return {
        "type":    "ds.search",
        "options": opts,
    }


def _strip_html(text: str) -> str:
    """Remove tags from a Simple XML <html> body so we can render the text in
    a markdown widget. Preserves <br> as newlines and <strong>/<em> as md.
    """
    if not text:
        return ""
    s = text
    # Convert common inline tags to markdown.
    s = re.sub(r"<\s*br\s*/?\s*>", "\n", s, flags=re.IGNORECASE)
    s = re.sub(r"<\s*strong\s*>", "**", s, flags=re.IGNORECASE)
    s = re.sub(r"<\s*/\s*strong\s*>", "**", s, flags=re.IGNORECASE)
    s = re.sub(r"<\s*em\s*>", "*", s, flags=re.IGNORECASE)
    s = re.sub(r"<\s*/\s*em\s*>", "*", s, flags=re.IGNORECASE)
    # <a href="...">text</a> -> [text](url)
    s = re.sub(r"<\s*a[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)<\s*/\s*a\s*>",
               r"[\2](\1)", s, flags=re.IGNORECASE | re.DOTALL)
    # Drop everything else.
    s = re.sub(r"<[^>]+>", "", s)
    # Collapse whitespace.
    s = re.sub(r"[ \t]+", " ", s)
    s = re.sub(r"\n[ \t]+", "\n", s)
    return s.strip()


def _range_value_expr(values: list[float], colors: list[str]) -> str | None:
    """Build a Dashboard Studio ``rangeValue(...)`` expression mapping the
    Simple XML rangeValues / rangeColors pair.

    Simple XML semantics: rangeValues is a sorted list of N thresholds and
    rangeColors is a list of N+1 colors:
        thresholds [t0, t1, t2]   colors [c0, c1, c2, c3]
        v < t0       -> c0
        t0 <= v < t1 -> c1
        t1 <= v < t2 -> c2
        v >= t2      -> c3
    """
    if not values or not colors or len(colors) != len(values) + 1:
        return None
    bounds = [-1e18, *values, 1e18]
    parts = []
    for i, c in enumerate(colors):
        lo = bounds[i]
        hi = bounds[i + 1]
        parts.append(
            "{from:" + repr(lo) + ",to:" + repr(hi) + ",value:" + json.dumps(c) + "}"
        )
    return "> rangeValue(value=primary, ranges=[" + ",".join(parts) + "])"


# ---------------------------------------------------------------------------
# Per-viz converters
# ---------------------------------------------------------------------------
def _convert_single(viz: ET.Element, title: str) -> tuple[dict, dict, int]:
    """Return (viz_def, ds_def, height)."""
    opts = _opt_map(viz)
    s    = _search_block(viz)
    ds_id = _did()
    ds = _make_search_ds(s["query"], s["earliest"], s["latest"], s.get("refresh"))
    unit         = opts.get("unit", "")
    unit_pos     = opts.get("unitPosition", "after")
    precision    = opts.get("numberPrecision", "0")
    use_colors   = opts.get("useColors", "0") in ("1", "true", "True")
    color_list   = _coerce_color_list(opts.get("rangeColors"))
    val_list     = _coerce_float_list(opts.get("rangeValues"))

    options: dict[str, Any] = {
        "majorFontSize": 56,
        "majorColor":    "#FFFFFF",
        "trendDisplay":  "off",
        "sparklineDisplay": "off",
        "unit":          unit,
        "unitPosition":  "before" if unit_pos == "before" else "after",
        "numberPrecision": float(precision) if "." in precision else int(precision)
                          if precision else 0,
        "backgroundColor": "#1a2742",
    }
    if use_colors and color_list and val_list:
        expr = _range_value_expr(val_list, color_list)
        if expr:
            options["majorColor"] = expr

    viz_def = {
        "type":   "splunk.singlevalue",
        "title":  title,
        "options": options,
        "dataSources": {"primary": ds_id},
    }
    return viz_def, {ds_id: ds}, H_SINGLE


_CHART_TYPE_MAP = {
    "line":   "splunk.line",
    "area":   "splunk.area",
    "bar":    "splunk.bar",
    "column": "splunk.column",
    "pie":    "splunk.pie",
}


def _convert_chart(viz: ET.Element, title: str) -> tuple[dict, dict, int]:
    opts = _opt_map(viz)
    s    = _search_block(viz)
    ds_id = _did()
    ds = _make_search_ds(s["query"], s["earliest"], s["latest"], s.get("refresh"))

    sub  = (opts.get("charting.chart") or "line").strip()
    ds_studio_type = _CHART_TYPE_MAP.get(sub, "splunk.line")

    options: dict[str, Any] = {
        "backgroundColor": "#1a2742",
    }
    if "charting.legend.placement" in opts:
        # Dashboard Studio: legendDisplay = right|left|top|bottom|off
        legend = opts["charting.legend.placement"]
        options["legendDisplay"] = legend if legend in ("right","left","top","bottom","off") else "right"

    if opts.get("charting.chart.stackMode") == "stacked":
        options["stackMode"] = "stacked"
    if opts.get("charting.chart.showDataLabels") in ("all", "minmax"):
        options["showLabels"] = True
    if "charting.axisTitleX.text" in opts:
        options["xAxisTitleText"] = opts["charting.axisTitleX.text"]
    if "charting.axisTitleY.text" in opts:
        options["yAxisTitleText"] = opts["charting.axisTitleY.text"]

    # Field colors -> seriesColors (best effort, order not preserved by name).
    fc_raw = opts.get("charting.fieldColors")
    if fc_raw:
        try:
            # Strip 0x prefixes inside the JSON-like blob.
            fc_norm = re.sub(r"0x([0-9A-Fa-f]{6})", r"\"#\1\"", fc_raw)
            fc = json.loads(fc_norm)
            colors = [_coerce_color(str(v)) for v in fc.values() if v]
            if colors:
                options["seriesColors"] = colors
        except (TypeError, ValueError, json.JSONDecodeError):
            pass

    viz_def = {
        "type":   ds_studio_type,
        "title":  title,
        "options": options,
        "dataSources": {"primary": ds_id},
    }
    return viz_def, {ds_id: ds}, H_CHART


def _convert_table(viz: ET.Element, title: str) -> tuple[dict, dict, int]:
    s = _search_block(viz)
    ds_id = _did()
    ds = _make_search_ds(s["query"], s["earliest"], s["latest"], s.get("refresh"))
    viz_def = {
        "type":   "splunk.table",
        "title":  title,
        "options": {
            "backgroundColor": "#1a2742",
            "rowBackgroundColors": ["#1a2742", "#0d1729"],
            "headerBackgroundColor": "#0d1729",
            "headerTextColor": "#E8EDF5",
            "rowTextColors":  ["#E8EDF5"],
            "count": 20,
        },
        "dataSources": {"primary": ds_id},
    }
    return viz_def, {ds_id: ds}, H_TABLE


def _convert_map(viz: ET.Element, title: str) -> tuple[dict, dict, int]:
    """Map -> splunk.choropleth.svg.

    Splunk Dashboard Studio's choropleth.svg viz REQUIRES an `svg` option
    containing the literal SVG content (or a data: URI) — not a URL.
    Pointing at /static/app/<...>/world_countries.svg silently fails
    validation with "Missing property: svg" in the editor and the tile
    renders empty. We inline the SVG from
        splunk-apps/leaflet_maps_server/appserver/static/world_countries.svg
    using a data URI so the viz is fully self-contained inside the Glass
    Table JSON (no runtime dependency on a separate Splunk app being
    installed). Adds ~75 KB to each choropleth viz, which the KV store
    handles fine.
    """
    opts = _opt_map(viz)
    s = _search_block(viz)
    ds_id = _did()
    ds = _make_search_ds(s["query"], s["earliest"], s["latest"], s.get("refresh"))
    options: dict[str, Any] = {
        "backgroundColor": "#1a2742",
        "svg": _load_world_svg_data_uri(),
    }
    if "mapping.choroplethLayer.minimumColor" in opts:
        options["minColor"] = _coerce_color(opts["mapping.choroplethLayer.minimumColor"])
    if "mapping.choroplethLayer.maximumColor" in opts:
        options["maxColor"] = _coerce_color(opts["mapping.choroplethLayer.maximumColor"])
    viz_def = {
        "type":   "splunk.choropleth.svg",
        "title":  title,
        "options": options,
        "dataSources": {"primary": ds_id},
    }
    return viz_def, {ds_id: ds}, H_MAP


def _convert_html(viz: ET.Element, title: str) -> tuple[dict, dict, int]:
    """Render <html> banners as splunk.markdown widgets. We strip tags but
    preserve text and links so section headers and the hero remain.
    """
    raw  = ET.tostring(viz, encoding="unicode", method="xml")
    # Strip the wrapping <html>...</html> element.
    raw  = re.sub(r"^\s*<html[^>]*>", "", raw)
    raw  = re.sub(r"</html>\s*$", "", raw)
    text = _strip_html(raw)
    if title:
        text = f"### {title}\n\n{text}" if text else f"### {title}"
    is_banner = bool(viz.find("img") is not None or
                     re.search(r"hero|banner|natwest", text, re.IGNORECASE))
    height    = H_HTML_BANNER if is_banner and len(text) > 80 else H_HTML
    viz_def = {
        "type":   "splunk.markdown",
        "options": {
            "markdown":        text or "&nbsp;",
            "backgroundColor": "transparent",
            "fontColor":       "#E8EDF5",
        },
    }
    return viz_def, {}, height


# ---------------------------------------------------------------------------
# Top-level conversion
# ---------------------------------------------------------------------------
def convert_xml_to_studio(xml_path: Path) -> dict[str, Any]:
    tree = ET.parse(xml_path)
    root = tree.getroot()

    label = (root.findtext("label") or "NatWest Card Payments").strip()
    descr = (root.findtext("description") or "").strip()

    visualizations: dict[str, Any] = {}
    data_sources: dict[str, Any]   = {}
    structure: list[dict[str, Any]] = []

    cur_y = 16
    for r_idx, row in enumerate(root.findall("row")):
        panels = row.findall("panel")
        if not panels:
            continue
        avail_w  = CANVAS_WIDTH - (PANEL_GAP * (len(panels) + 1))
        panel_w  = avail_w // len(panels)
        row_h    = 0
        cur_x    = PANEL_GAP

        for p in panels:
            title = (p.findtext("title") or "").strip()
            child = next((c for c in p if c.tag in ("single","chart","table","map","html")), None)
            if child is None:
                cur_x += panel_w + PANEL_GAP
                continue

            if   child.tag == "single":  v_def, ds_def, h = _convert_single(child, title)
            elif child.tag == "chart":   v_def, ds_def, h = _convert_chart(child, title)
            elif child.tag == "table":   v_def, ds_def, h = _convert_table(child, title)
            elif child.tag == "map":     v_def, ds_def, h = _convert_map(child, title)
            elif child.tag == "html":    v_def, ds_def, h = _convert_html(child, title)
            else:
                cur_x += panel_w + PANEL_GAP
                continue

            vid = _vid()
            visualizations[vid] = v_def
            data_sources.update(ds_def)
            structure.append({
                "item":     vid,
                "type":     "block",
                "position": {"x": cur_x, "y": cur_y, "w": panel_w, "h": h},
            })
            row_h  = max(row_h, h)
            cur_x += panel_w + PANEL_GAP

        cur_y += row_h + ROW_GAP

    canvas_h = cur_y + ROW_GAP

    definition: dict[str, Any] = {
        "title":         label,
        "description":   descr,
        "visualizations": visualizations,
        "dataSources":    data_sources,
        "defaults": {
            "dataSources": {
                "ds.search": {
                    "options": {
                        "queryParameters": {
                            "latest":   "$global_time.latest$",
                            "earliest": "$global_time.earliest$",
                        },
                    },
                },
            },
            "visualizations": {
                "global": {
                    "showProgressBar": False,
                    "showLastUpdated": True,
                },
            },
        },
        "inputs": {
            "input_global_trp": {
                "type":  "input.timerange",
                "title": "Global Time Range",
                "options": {
                    "token":           "global_time",
                    "defaultValue":    "-60m,now",
                },
            },
        },
        # Layout shape: ITSI 4.21's GlassTableEditorBeta (and the underlying
        # Dashboard Studio renderer that ships with splunk-dashboard-studio 1.23)
        # requires the *multi-tab* layout structure, i.e.
        #   layout.layoutDefinitions["<tabId>"].structure = [...]
        #   layout.tabs.items[]                = [{label, layoutId}, ...]
        # Putting `structure` directly under `layout` (the legacy single-canvas
        # shape) is silently accepted by the REST API but crashes the editor
        # JS on render:
        #   GlassTableEditorBeta.aggregateSearches:
        #     Object.keys(_n.layout.layoutDefinitions)[0]   <-- undefined
        #   TypeError: Cannot convert undefined or null to object
        # ...leaving the canvas blank. We always emit a single tab named
        # "main" so the page renders correctly with no tab UI surfacing.
        "layout": {
            "type": "absolute",
            "options": {
                "width":          CANVAS_WIDTH,
                "height":         canvas_h,
                "backgroundColor": CANVAS_BACKGROUND,
                "showTitleAndDescription": False,
            },
            "layoutDefinitions": {
                "main": {
                    "type": "absolute",
                    "options": {
                        "width":          CANVAS_WIDTH,
                        "height":         canvas_h,
                        "backgroundColor": CANVAS_BACKGROUND,
                        "showTitleAndDescription": False,
                    },
                    "structure":     structure,
                    "globalInputs":  ["input_global_trp"],
                },
            },
            "tabs": {
                "items": [
                    {"label": "Overview", "layoutId": "main"},
                ],
            },
            "globalInputs":     ["input_global_trp"],
        },
    }
    return definition


def wrap_glass_table(
    definition: dict[str, Any],
    key: str,
    title: str,
    description: str,
    *,
    acl_owner: str = "admin",
    namespace_user: str = "nobody",
) -> dict[str, Any]:
    """Wrap a Dashboard Studio definition in an ITSI ``glass_table`` envelope
    suitable for POSTing to /servicesNS/nobody/SA-ITOA/itoa_interface/glass_table.

    ITSI rejects creates when ownership metadata is incomplete: include
    ``identifying_name``, ``_owner``, ``_user``, and set ``acl.owner`` to the
    Splunk account used for REST (typically ``admin``), not ``nobody`` — using
    ``nobody`` only in ``acl`` triggers "owner fields corrupted or missing".
    """
    return {
        "_key":               key,
        "object_type":        "glass_table",
        "title":              title,
        "description":        description,
        "identifying_name":   key,
        "_owner":             namespace_user,
        "_user":              namespace_user,
        "shared":             True,
        "icons":              [],
        "kpi_data":           [],
        "service_data":       [],
        # Dashboard Studio definition lives under "definition". ITSI 4.15+
        # accepts either an inline object or a JSON-encoded string. We send
        # an inline object; the API normalises on read.
        "definition":         definition,
        "definition_version": "1.1.0",
        # acl.owner is the Splunk object owner for permissions; REST namespace
        # remains nobody via URL path and _owner/_user above.
        "acl": {
            "owner":      acl_owner,
            "app":        "itsi",
            "sharing":    "global",
            "perms":      {"read": ["*"], "write": ["admin", "itoa_admin"]},
        },
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--xml", default="itsi/glass-table/natwest-payments-overview.xml",
                    help="Path to the source Simple XML dashboard")
    ap.add_argument("--out", default="itsi/glass-table/natwest-payments-overview.glass-table.json",
                    help="Where to write the rendered glass_table JSON envelope")
    ap.add_argument("--key", default="nwpay_glass_table_overview",
                    help="Stable _key for the ITSI glass_table object")
    ap.add_argument("--title", default=None, metavar="TITLE",
                    help="Glass Tables list title (default: Simple XML <label>)")
    ap.add_argument("--description", default=
                    "Executive overview of the NatWest Card Payments service: "
                    "lifecycle, tiers, geography, chaos, DORA, PSD2 SCA, ATM "
                    "estate, Open Banking, FinOps, BGP path visibility.",
                    help="Description shown in the Glass Tables list")
    args = ap.parse_args()

    xml_path = Path(args.xml)
    out_path = Path(args.out)
    if not xml_path.is_file():
        print(f"[error] Simple XML not found: {xml_path}", file=sys.stderr)
        return 2

    definition = convert_xml_to_studio(xml_path)
    if args.title is not None and str(args.title).strip():
        gt_title = str(args.title).strip()
    else:
        gt_title = (definition.get("title") or "").strip() or "NatWest Card Payments - Glass Table"
    envelope = wrap_glass_table(definition, args.key, gt_title, args.description)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(envelope, indent=2))
    print(f"[ok] wrote {out_path}  ({len(definition['visualizations'])} viz, "
          f"{len(definition['dataSources'])} ds, "
          f"canvas {definition['layout']['options']['width']}x"
          f"{definition['layout']['options']['height']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
