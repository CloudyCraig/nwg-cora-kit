#!/usr/bin/env python3
# itsi_bootstrap.py - render itsi/service-tree.yaml into ITSI REST objects.
#
# Idempotent: every object is upserted by deterministic _key. Fails fast on
# auth or schema errors but continues past per-object failures so a partial
# tree always lands.

from __future__ import annotations

import argparse
import base64
import json
import logging
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Iterable

import yaml

LOG = logging.getLogger("itsi_bootstrap")

# Severity palette used by ITSI's UI. Stick to the documented values so
# health-score colours render correctly in the service analyzer.
SEV_NORMAL    = {"severityValue": 2, "severityLabel": "normal",   "severityColor": "#99D18B", "severityColorLight": "#D5EBD2"}
SEV_LOW       = {"severityValue": 3, "severityLabel": "low",      "severityColor": "#F8BE34", "severityColorLight": "#FCDF80"}
SEV_MEDIUM    = {"severityValue": 4, "severityLabel": "medium",   "severityColor": "#F58F39", "severityColorLight": "#FBCEAB"}
SEV_HIGH      = {"severityValue": 5, "severityLabel": "high",     "severityColor": "#B50101", "severityColorLight": "#E5A6A6"}
SEV_CRITICAL  = {"severityValue": 6, "severityLabel": "critical", "severityColor": "#B50101", "severityColorLight": "#E5A6A6"}

# `aggregation_method` codes for service severity_aggregation in ITSI.
AGG_MAP = {
    "max":           "max",
    "weighted_avg":  "weighted_avg",
    "min":           "min",
    "avg":           "avg",
}


def safe_field(name: str) -> str:
    """ITSI's entity API rejects field names containing `.` `/` `:` etc.

    OTel resource attributes (`service.name`, `app.kubernetes.io/name`,
    `host.name`) and Kubernetes labels (`kubernetes.service`) all contain
    those characters, so we transparently rewrite to underscore form when
    using them as ITSI entity identifiers / aliases. The KPI base searches
    add a matching `rename` step so the field shows up with the same
    underscored name in search results.
    """
    return name.replace(".", "_").replace("/", "_").replace(":", "_")


# ---------------------------------------------------------------------------
# HTTP client
# ---------------------------------------------------------------------------
class ItsiClient:
    # Most ITSI custom objects (kpi_base_search, service, entity, glass_table,
    # ...) live under SA-ITOA/itoa_interface, but a handful of notable-event
    # objects (notable_event_aggregation_policy in particular) live under
    # SA-ITOA/event_management_interface. Hitting the wrong interface returns
    # 404 silently for both GET and POST. This mapping lets ``upsert`` /
    # ``get`` route per-object-type to the right REST namespace.
    _INTERFACE_BY_OBJECT_TYPE: dict[str, str] = {
        "notable_event_aggregation_policy": "event_management_interface",
    }
    _DEFAULT_INTERFACE = "itoa_interface"

    def __init__(self, host: str, port: int, user: str, password: str, verify_tls: bool = False):
        self.host_root = f"https://{host}:{port}"
        self.base = f"{self.host_root}/servicesNS/nobody/SA-ITOA/{self._DEFAULT_INTERFACE}"
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        self.headers = {
            "Authorization": f"Basic {token}",
            "Content-Type":  "application/json",
            "Accept":        "application/json",
        }
        # Splunk ships self-signed certs by default. Demo path: skip verify
        # but keep it as an explicit toggle so production callers can set it
        # to True after pinning the CA bundle.
        if verify_tls:
            self.ssl_ctx = ssl.create_default_context()
        else:
            self.ssl_ctx = ssl._create_unverified_context()

    def _request(self, method: str, path: str, body: Any = None, query: dict | None = None) -> tuple[int, Any]:
        url = f"{self.base}/{path.lstrip('/')}"
        if query:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(query)
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(url, data=data, method=method, headers=self.headers)
        try:
            with urllib.request.urlopen(req, context=self.ssl_ctx, timeout=60) as resp:
                raw = resp.read().decode("utf-8")
                code = resp.getcode()
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", errors="replace")
            code = e.code
        try:
            return code, (json.loads(raw) if raw else None)
        except json.JSONDecodeError:
            return code, raw

    def get(self, path: str, query: dict | None = None):
        return self._request("GET", path, query=query)

    def post(self, path: str, body: Any, query: dict | None = None):
        return self._request("POST", path, body=body, query=query)

    def put(self, path: str, body: Any, query: dict | None = None):
        return self._request("PUT", path, body=body, query=query)

    # ------------------------------------------------------------------
    # Splunk core endpoints (data/ui/views/...) live outside the SA-ITOA
    # namespace. Use a separate request method that hits /services* directly
    # and POSTs form-encoded payloads (the data/ui/views API does not accept
    # JSON).
    # ------------------------------------------------------------------
    def _form_request(self, method: str, full_path: str, form: dict[str, str] | None = None) -> tuple[int, str]:
        # Strip the SA-ITOA itoa_interface prefix - we need to talk to /services*
        # at the host root.
        host_part = self.base.split("/servicesNS/")[0]
        url = f"{host_part}/{full_path.lstrip('/')}"
        body = urllib.parse.urlencode(form or {}).encode()
        headers = {
            "Authorization": self.headers["Authorization"],
            "Content-Type":  "application/x-www-form-urlencoded",
            "Accept":        "application/json",
        }
        req = urllib.request.Request(url, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, context=self.ssl_ctx, timeout=60) as resp:
                return resp.getcode(), resp.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", errors="replace")

    def upsert_saved_search(self, app: str, name: str, params: dict) -> bool:
        """Create or update a Splunk saved search in <app>.

        Used for the o11y-to-ITSI correlation search. ITSI Episode Review
        materialises notable events from any saved search whose `actions`
        include `itsi_event_generator`.
        """
        # Probe.
        code, _ = self._form_request("GET", f"servicesNS/nobody/{app}/saved/searches/{urllib.parse.quote(name)}?output_mode=json")
        if code == 200:
            form = {k: v for k, v in params.items() if k != "name"}
            code, payload = self._form_request(
                "POST",
                f"servicesNS/nobody/{app}/saved/searches/{urllib.parse.quote(name)}?output_mode=json",
                form=form,
            )
            verb = "update"
        else:
            form = dict(params)
            form["name"] = name
            code, payload = self._form_request(
                "POST",
                f"servicesNS/nobody/{app}/saved/searches?output_mode=json",
                form=form,
            )
            verb = "create"
        if 200 <= code < 300:
            LOG.info("  [ok]   %s saved-search app=%s name=%s", verb, app, name)
            return True
        LOG.error("  [fail] %s saved-search app=%s name=%s code=%s body=%s", verb, app, name, code, payload[:300])
        return False

    def upsert_view(self, app: str, name: str, xml_body: str) -> bool:
        """Create or update a Simple XML dashboard in <app>."""
        # Probe for existing view.
        code, _ = self._form_request("GET", f"servicesNS/nobody/{app}/data/ui/views/{name}?output_mode=json")
        if code == 200:
            code, payload = self._form_request(
                "POST",
                f"servicesNS/nobody/{app}/data/ui/views/{name}?output_mode=json",
                form={"eai:data": xml_body},
            )
            verb = "update"
        else:
            code, payload = self._form_request(
                "POST",
                f"servicesNS/nobody/{app}/data/ui/views?output_mode=json",
                form={"name": name, "eai:data": xml_body},
            )
            verb = "create"
        if 200 <= code < 300:
            LOG.info("  [ok]   %s view app=%s name=%s", verb, app, name)
            return True
        LOG.error("  [fail] %s view app=%s name=%s code=%s body=%s", verb, app, name, code, payload[:300])
        return False

    # ------------------------------------------------------------------
    # Form-wrapped-JSON request. The notable-event endpoints under
    # ``event_management_interface`` (notable_event_aggregation_policy
    # in particular) reject raw JSON bodies with "Unparsable URI-encoded
    # request data" and instead require the JSON to be wrapped in an
    # ``application/x-www-form-urlencoded`` body under a single
    # ``data=<json>`` field. This is the same trick the ITSI UI uses
    # internally for those endpoints.
    # ------------------------------------------------------------------
    _FORM_WRAPPED_OBJECT_TYPES = frozenset({"notable_event_aggregation_policy"})

    def _base_url_for(self, object_type: str) -> str:
        interface = self._INTERFACE_BY_OBJECT_TYPE.get(object_type, self._DEFAULT_INTERFACE)
        return f"{self.host_root}/servicesNS/nobody/SA-ITOA/{interface}"

    def _request_at(
        self,
        method: str,
        base_url: str,
        path: str,
        body: Any = None,
        query: dict | None = None,
        form_wrapped: bool = False,
    ) -> tuple[int, Any]:
        url = f"{base_url}/{path.lstrip('/')}"
        if query:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(query)
        if form_wrapped:
            data = urllib.parse.urlencode({"data": json.dumps(body)}).encode("utf-8")
            headers = {
                "Authorization": self.headers["Authorization"],
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            }
        else:
            data = None if body is None else json.dumps(body).encode("utf-8")
            headers = self.headers
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, context=self.ssl_ctx, timeout=60) as resp:
                raw = resp.read().decode("utf-8")
                code = resp.getcode()
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", errors="replace")
            code = e.code
        try:
            return code, (json.loads(raw) if raw else None)
        except json.JSONDecodeError:
            return code, raw

    def upsert(self, object_type: str, key: str, body: dict) -> bool:
        """POST to /object_type if not present; otherwise PUT to /object_type/{key}.

        Routes through the right REST interface and request envelope based on
        ``object_type`` (see ``_INTERFACE_BY_OBJECT_TYPE`` and
        ``_FORM_WRAPPED_OBJECT_TYPES``).
        """
        base = self._base_url_for(object_type)
        form_wrapped = object_type in self._FORM_WRAPPED_OBJECT_TYPES
        # GET probe uses raw JSON regardless; only the write side may need the
        # form-wrapped envelope.
        code, payload = self._request_at("GET", base, f"{object_type}/{key}")
        exists = (code == 200 and isinstance(payload, dict) and payload.get("_key") == key)
        if exists:
            code, payload = self._request_at(
                "POST", base, f"{object_type}/{key}", body=body, form_wrapped=form_wrapped
            )
            verb = "update"
        else:
            code, payload = self._request_at(
                "POST", base, object_type, body=body, form_wrapped=form_wrapped
            )
            verb = "create"
        if 200 <= code < 300:
            LOG.info("  [ok]   %s %s _key=%s", verb, object_type, key)
            return True
        LOG.error("  [fail] %s %s _key=%s code=%s body=%s", verb, object_type, key, code, payload)
        return False

    def delete(self, object_type: str, key: str) -> bool:
        """DELETE /object_type/{key}. Returns True on 2xx or 404."""
        base = self._base_url_for(object_type)
        code, payload = self._request_at("DELETE", base, f"{object_type}/{key}")
        if code == 404:
            return True
        if 200 <= code < 300:
            LOG.info("  [ok]   delete %s _key=%s", object_type, key)
            return True
        LOG.error("  [fail] delete %s _key=%s code=%s body=%s", object_type, key, code, payload)
        return False


STALE_TE_ENTITY_KEYS = (
    "ent_te_dce_spa_avail",
    "ent_te_dce_spa_response_time",
    "ent_te_dce_api_gateway_avail",
    "ent_te_dce_spa_page_load",
    "ent_te_dce_journey_success",
    "ent_te_dce_journey_time",
    "ent_te_dce_dns",
    "ent_te_dce_synth_post",
)

STALE_INFRA_ENTITY_KEYS = (
    "ent_postgres_natwest",
    "ent_kafka_natwest",
    "ent_splunk_otel_collector",
    "ent_splunk_enterprise_ec2",
)

STALE_OBSERVABILITY_STACK_SERVICE_KEYS = (
    "nwpay_l4_otel_collector",
    "nwpay_l4_splunk_enterprise",
    "nwpay_l5_aws_security",
)

STALE_TIER_SERVICE_KEYS = (
    "nwpay_tier_bronze",
    "nwpay_tier_silver",
    "nwpay_tier_gold",
)

STALE_CHANNEL_SERVICE_KEYS = (
    "nwpay_l2_channel",
    "nwpay_l3_web_frontend",
)

STALE_CHANNEL_ENTITY_KEYS = (
    "ent_web_frontend",
)

# ThousandEyes base searches used exclusively by nwpay_l2_dce. In demo
# steady-state green we roll these up globally (no per-agent breakdown)
# so a single slow probe cannot paint Digital Customer Experience yellow.
DCE_STEADY_STATE_BASE_SEARCH_IDS = frozenset({
    "kbs_te_spa_avail",
    "kbs_te_api_gateway_avail",
    "kbs_te_spa_response_time",
    "kbs_te_spa_page_load",
    "kbs_te_journey_success",
    "kbs_te_journey_time",
    "kbs_te_dns",
})

STALE_L2_API_GATEWAY_KEYS = (
    "nwpay_l2_api_gateway",
)


def delete_demo_green_kpi_rebuild_services(
    client: ItsiClient, services_in: list[dict], demo_green: bool
) -> int:
    """Delete services whose KPIs carry immutable ITSI flags we must recreate.

    ITSI 4.21 does not honour POST updates to ``is_entity_breakdown`` on
    existing KPIs. For demo steady-state green we disable entity breakdown
    on DCE ThousandEyes KPIs; delete+recreate is the only reliable path.
    """
    if not demo_green:
        return 0
    fail = 0
    for svc in services_in:
        if not svc.get("steady_state_disable_entity_breakdown"):
            continue
        key = svc["key"]
        LOG.info("  [demo] delete service _key=%s before recreate (KPI flag rebuild)", key)
        if not client.delete("service", key):
            fail += 1
    return fail


def delete_demo_green_te_base_searches(client: ItsiClient, demo_green: bool) -> int:
    """Delete DCE TE base searches so ``is_entity_breakdown`` can be recreated.

    ITSI treats ``is_entity_breakdown`` as immutable on existing base searches
    and copies it onto KPIs at creation time.
    """
    if not demo_green:
        return 0
    fail = 0
    for key in sorted(DCE_STEADY_STATE_BASE_SEARCH_IDS):
        LOG.info("  [demo] delete kpi_base_search _key=%s before recreate", key)
        if not client.delete("kpi_base_search", key):
            fail += 1
    return fail


def delete_stale_te_entities(client: ItsiClient) -> int:
    """Remove superseded per-KPI TE placeholder entities from ITSI."""
    fail = 0
    for key in STALE_TE_ENTITY_KEYS:
        if not client.delete("entity", key):
            fail += 1
    return fail


def delete_stale_infra_entities(client: ItsiClient) -> int:
    """Remove superseded infrastructure placeholder entities from ITSI."""
    fail = 0
    for key in STALE_INFRA_ENTITY_KEYS:
        if not client.delete("entity", key):
            fail += 1
    return fail


def delete_stale_tier_services(client: ItsiClient) -> int:
    """Remove legacy per-tier L2 services superseded by Customer Tier Experience."""
    fail = 0
    for key in STALE_TIER_SERVICE_KEYS:
        if not client.delete("service", key):
            fail += 1
    return fail


def delete_stale_channel_services(client: ItsiClient) -> int:
    """Remove retired Customer Channel L2 and web-frontend L3 services."""
    fail = 0
    for key in STALE_CHANNEL_SERVICE_KEYS:
        if not client.delete("service", key):
            fail += 1
    return fail


def delete_stale_observability_stack_services(client: ItsiClient) -> int:
    """Remove retired OTel collector / Splunk EC2 / AWS security ITSI tiles."""
    fail = 0
    for key in STALE_OBSERVABILITY_STACK_SERVICE_KEYS:
        LOG.info("  [cleanup] delete service _key=%s", key)
        if not client.delete("service", key):
            fail += 1
    return fail


def delete_stale_l2_api_gateway(client: ItsiClient) -> int:
    """Remove superseded L2 API Gateway tile (replaced by L3 nwpay_l3_api_gateway)."""
    fail = 0
    for key in STALE_L2_API_GATEWAY_KEYS:
        if not client.delete("service", key):
            fail += 1
    return fail


def delete_stale_channel_entities(client: ItsiClient) -> int:
    """Remove the web-frontend ITSI entity."""
    fail = 0
    for key in STALE_CHANNEL_ENTITY_KEYS:
        if not client.delete("entity", key):
            fail += 1
    return fail


def publish_glass_table_dashboard(
    client: ItsiClient,
    view_xml_path: Path,
    native_xml_path: Path | None,
    *,
    view_app: str,
    view_name: str,
    native_key: str,
    splunk_user: str,
    title_override: str | None,
    title_fallback: str,
    description_fallback: str,
) -> int:
    """Install a Simple XML view (``view_xml_path``) and optionally a native
    ITSI ``glass_table`` converted from ``native_xml_path``.

    When ``native_xml_path`` is None or missing, only the dashboard view is
    installed. Returns the number of failed steps (0–2).
    """
    fails = 0
    if not view_xml_path.is_file():
        LOG.warning("[skip] glass-table view XML not found: %s", view_xml_path)
        return 0

    LOG.info("[step] glass-table view (%s in app=%s)", view_name, view_app)
    if not client.upsert_view(view_app, view_name, view_xml_path.read_text(encoding="utf-8")):
        fails += 1

    if not native_xml_path or not native_xml_path.is_file():
        LOG.info("[skip] native glass-table source missing or disabled: %s", native_xml_path)
        return fails

    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from glass_table_convert import convert_xml_to_studio, wrap_glass_table  # type: ignore
    except Exception as exc:  # noqa: BLE001
        LOG.error("[fail] could not import glass_table_convert: %s", exc)
        return fails + 1

    try:
        definition = convert_xml_to_studio(native_xml_path)
        studio_title = (definition.get("title") or "").strip()
        if title_override is not None and str(title_override).strip():
            glass_title = str(title_override).strip()
        else:
            glass_title = studio_title or title_fallback
        envelope = wrap_glass_table(
            definition,
            key=native_key,
            title=glass_title,
            description=(definition.get("description") or "").strip() or description_fallback,
            acl_owner=splunk_user,
        )
    except Exception as exc:  # noqa: BLE001
        LOG.error("[fail] could not convert %s -> glass_table JSON: %s", native_xml_path, exc)
        return fails + 1

    LOG.info("[step] native ITSI glass_table (_key=%s, %d viz)",
             native_key,
             len(envelope.get("definition", {}).get("visualizations", {})))
    if not client.upsert("glass_table", native_key, envelope):
        fails += 1
    return fails


# ---------------------------------------------------------------------------
# Threshold helpers
# ---------------------------------------------------------------------------
def _level(sev: dict, value: float) -> dict:
    return dict(sev, thresholdValue=float(value), dynamicParam=0)


def build_threshold_levels(threshold: dict | None, metric_field: str) -> dict:
    """Translate the manifest's `threshold` dict into an ITSI threshold block.

    Supported keys (high-is-bad metrics):  critical, warning
    Supported keys (low-is-bad metrics):   critical_low, warning_low
    """
    levels: list[dict] = []
    if threshold:
        if "critical" in threshold:
            levels.append(_level(SEV_CRITICAL, threshold["critical"]))
        if "warning" in threshold:
            levels.append(_level(SEV_MEDIUM,   threshold["warning"]))
        if "critical_low" in threshold:
            levels.append(dict(_level(SEV_CRITICAL, threshold["critical_low"]),
                               isMaxStatic=False, isMinStatic=True))
        if "warning_low" in threshold:
            levels.append(dict(_level(SEV_MEDIUM,   threshold["warning_low"]),
                               isMaxStatic=False, isMinStatic=True))

    return {
        "thresholdLevels":          levels,
        "baseSeverityValue":        SEV_NORMAL["severityValue"],
        "baseSeverityLabel":        SEV_NORMAL["severityLabel"],
        "baseSeverityColor":        SEV_NORMAL["severityColor"],
        "baseSeverityColorLight":   SEV_NORMAL["severityColorLight"],
        "isMaxStatic":              False,
        "isMinStatic":              False,
        "gaugeMax":                 None,
        "gaugeMin":                 None,
        "renderBoundaryMax":        None,
        "renderBoundaryMin":        None,
        "metricField":              metric_field,
        "search":                   "",
    }


# ---------------------------------------------------------------------------
# KPI base search rendering
# ---------------------------------------------------------------------------
def render_kpi_base_search(kbs: dict) -> dict:
    metrics = []
    for m in kbs.get("metrics", []):
        # Keep the metric `_key` equal to its plain id. Service KPIs reference
        # this via `base_search_metric` and ITSI looks up the metric by exact
        # match - prefixing here would orphan every shared-base KPI.
        metrics.append({
            "_key":                       m["id"],
            "title":                      m["title"],
            "unit":                       m.get("unit", ""),
            "threshold_field":            m["threshold_field"],
            "aggregate_statop":           m.get("aggregate_statop", "avg"),
            "entity_statop":              m.get("entity_statop", "avg"),
            "fill_gaps":                  "null_value",
            "gap_severity":               m.get("gap_severity", "unknown"),
            "gap_severity_color":         "#666",
            "gap_severity_color_light":   "#aaa",
            "gap_severity_value":         "-1",
        })
    raw_alias = kbs.get("entity_alias_filtering_fields", "")
    alias = ",".join(safe_field(f.strip()) for f in raw_alias.split(",") if f.strip())
    # PRESERVE entity_alias_filtering_fields when the manifest sets one --
    # without it, ITSI's entity-status calculator has no way to associate
    # base-search rows with the entities they describe, and every entity
    # tile on the Entity Insights page (/app/itsi/entity_overview) sits at
    # status `combined=n/a` regardless of data flow. The alias names the
    # column in the search output (post-rename) whose value matches an
    # entity's identifier or informational field. It is independent of
    # is_entity_breakdown: ITSI uses the alias for status / vital-metric
    # joins even when the KPI itself stays on the rolled-up aggregate path.
    #
    # Most KPIs stay rolled-up for L1 glass-table health. ThousandEyes
    # base searches opt in via `entity_breakdown: true` so Service Analyzer
    # can list one entity per TE test under each DCE KPI.
    has_entity_breakdown = bool(kbs.get("entity_breakdown", False))
    return {
        "_key":                            kbs["id"],
        "object_type":                     "kpi_base_search",
        "title":                           kbs["title"],
        "description":                     kbs.get("description", ""),
        "base_search":                     kbs["base_search"].strip(),
        "alert_period":                    "1",
        "alert_lag":                       "30",
        "search_alert_earliest":           "5",
        "metric_qualifier":                "",
        "metrics":                         metrics,
        "entity_alias_filtering_fields":   alias,
        "entity_breakdown_id_fields":      alias if has_entity_breakdown else "",
        "is_entity_breakdown":             has_entity_breakdown,
        "actions":                         "",
        "is_service_entity_filter":        0,
        "sec_grp":                         "default_itsi_security_group",
    }


# ---------------------------------------------------------------------------
# Service KPI rendering
# ---------------------------------------------------------------------------
def normalize_kpi_filter(filter_spl: str) -> str:
    """Map manifest filter tokens to post-base-search column names."""
    out = (filter_spl or "").strip()
    if not out:
        return ""
    out = out.replace("service.name", "service_name")
    out = out.replace("customer.tier", "customer_tier")
    if 'payment_roaming="true"' in out:
        out = out.replace(
            'payment_roaming="true"',
            '(payment_roaming=true OR payment_roaming="true")',
        )
    return out


def apply_kpi_filter_to_base_search(base_search_spl: str, filter_spl: str) -> str:
    """Append a per-KPI where clause so shared-base rollups honour filters.

    ITSI 4.21 does not evaluate `search_buckets` for shared-base KPI health
    scores; without an explicit where each KPI inherits the global aggregate
    (e.g. every city showing the same max p95).
    """
    normalized = normalize_kpi_filter(filter_spl)
    if not normalized:
        return base_search_spl.strip()
    return f"{base_search_spl.rstrip()}\n| where {normalized}"


def render_service_kpi(
    svc_key: str,
    idx: int,
    kpi: dict,
    base_searches_by_id: dict[str, dict],
    *,
    disable_entity_breakdown: bool = False,
) -> dict:
    """Render a service KPI that references a shared base search.

    ITSI 4.21's validator (SA-ITOA/lib/itsi/objects/itsi_kpi.py:643-665) requires
    every shared-base KPI to *also* carry the base search SPL and threshold
    field on the KPI itself. The UI does this transparently, so we replicate
    the behaviour here by looking up the base search and copying both fields.
    Without this the validator raises:
      "Shared base KPIs does not seem to have populated a base search."
    """
    metric_id = kpi.get("metric_id", "value")
    threshold_block = build_threshold_levels(kpi.get("threshold"), metric_id)
    kpi_key = f"kpi_{svc_key}_{idx:02d}"

    kbs = base_searches_by_id.get(kpi["base_search_id"], {})
    base_search_spl = apply_kpi_filter_to_base_search(
        kbs.get("base_search", "").strip(),
        kpi.get("filter", ""),
    )
    # Mirror the metric's stat ops onto the KPI itself - itsi_kpi.py:752 marks
    # aggregate_statop as mandatory on the KPI even for shared_base KPIs.
    metric_def = next((m for m in kbs.get("metrics", []) if m.get("_key") == metric_id), {})
    aggregate_statop = metric_def.get("aggregate_statop", "avg")
    entity_statop    = metric_def.get("entity_statop", aggregate_statop)

    # Rolled-up by default. DCE ThousandEyes KPIs opt in via
    # `entity_breakdown: true` (on the KPI or its base search) so Service
    # Analyzer can show one row per TE test in the Entities panel.
    has_entity_breakdown = bool(
        kpi.get("entity_breakdown")
        or kbs.get("entity_breakdown")
        or kbs.get("is_entity_breakdown")
    )
    if disable_entity_breakdown:
        has_entity_breakdown = False
    return {
        "_key":                            kpi_key,
        "type":                            "kpi",
        "title":                           kpi["title"],
        # ITSI 4.21 KPI schema (SA-ITOA/lib/itsi/objects/itsi_kpi.py) accepts a
        # free-form `description` string that surfaces in the KPI detail
        # drawer of the service tree. Default to empty when absent so re-runs
        # of pre-existing KPIs don't blank out an admin-edited description.
        "description":                     (kpi.get("description") or "").strip(),
        "search_type":                     "shared_base",
        "base_search_id":                  kpi["base_search_id"],
        "base_search_metric":              metric_id,
        "base_search":                     base_search_spl,
        "threshold_field":                 metric_id,
        "aggregate_statop":                aggregate_statop,
        "entity_statop":                   entity_statop,
        "unit":                            metric_def.get("unit", ""),
        "fill_gaps":                       "null_value",
        "gap_severity":                    "normal" if disable_entity_breakdown else metric_def.get("gap_severity", "unknown"),
        "gap_severity_color":              "#666",
        "gap_severity_color_light":        "#aaa",
        "gap_severity_value":              "-1",
        "aggregate_thresholds":            threshold_block,
        "entity_thresholds":               build_threshold_levels(
            kpi.get("threshold") if has_entity_breakdown else None,
            metric_id,
        ),
        "time_variate_thresholds":         False,
        "kpi_threshold_template_id":       "",
        "kpi_template_kpi_id":             "",
        "urgency":                         kpi.get("weight", 5),
        "alert_period":                    "1",
        "alert_lag":                       "30",
        "search_alert_earliest":           "5",
        "is_entity_breakdown":             bool(has_entity_breakdown),
        "entity_breakdown_id_fields":      kbs.get("entity_alias_filtering_fields", "") if has_entity_breakdown else "",
        "entity_id_fields":                kbs.get("entity_alias_filtering_fields", "") if has_entity_breakdown else "",
        "is_service_entity_filter":        False,
        "datamodel_filter_clauses":        [],
        "filter_field":                    "",
        "filter_operator":                 "",
        "filter_value":                    "",
        "anomaly_detection_is_enabled":    False,
        "tags":                            [],
        # Retained for operator visibility; ITSI applies the filter via the
        # appended `| where` in base_search above.
        "search_buckets":                  kpi.get("filter", ""),
    }


# ---------------------------------------------------------------------------
# Service rendering
# ---------------------------------------------------------------------------
def render_service(svc: dict, manifest: dict, base_searches_by_id: dict[str, dict]) -> dict:
    demo_green = manifest.get("demo_steady_state_green") or manifest.get(
        "demo_only_red_service"
    )
    disable_entity_breakdown = bool(
        demo_green and svc.get("steady_state_disable_entity_breakdown")
    )
    kpis = []
    for i, kpi_def in enumerate(svc.get("kpis", [])):
        kpis.append(
            render_service_kpi(
                svc["key"],
                i,
                kpi_def,
                base_searches_by_id,
                disable_entity_breakdown=disable_entity_breakdown,
            )
        )

    # `kpis_depending_on` is what folds the dependent service's
    # ServiceHealthScore (SHKPI-<dep_key>) into THIS service's
    # health score calculation. Always populate it so severity
    # propagates up the dependency chain in the standard ITSI way:
    # the demo's pinned-red microservice still bubbles up to its
    # ancestor capability tiers and to L1, which is exactly the
    # "blast radius" view the run-of-show hangs the conversation on.
    deps = []
    for dep_key in svc.get("depends_on", []) or []:
        deps.append({
            "serviceid":          dep_key,
            "kpis_depending_on":  [f"SHKPI-{dep_key}"],
        })

    return {
        "_key":                                          svc["key"],
        "object_type":                                   "service",
        "title":                                         svc["title"],
        "description":                                   svc.get("description", ""),
        "enabled":                                       1,
        "sec_grp":                                       manifest["metadata"].get("security_group", "default_itsi_security_group"),
        "service_template_id":                           "",
        "is_healthscore_calculate_by_entity_enabled":    0,
        "kpis":                                          kpis,
        "services_depends_on":                           deps,
        "services_depending_on_me":                      [],
        "entity_rules":                                  svc.get("entity_rules", []),
        "tags":                                          ["nwpay-demo"],
        "severity_aggregation":                          AGG_MAP.get(svc.get("severity_aggregation", "weighted_avg"), "weighted_avg"),
    }


# ---------------------------------------------------------------------------
# Microservice expansion: render the L3 services inferred from the
# `microservices` block of the manifest.
# ---------------------------------------------------------------------------
def expand_microservices(manifest: dict) -> list[dict]:
    out = []
    defined_keys = {s["key"] for s in (manifest.get("services") or [])}
    for ms in manifest.get("microservices", []) or []:
        if ms.get("key") in defined_keys:
            continue
        # Default L3 KPI shape: p99 latency + error rate filtered by service.name.
        if "multi_service_filter" in ms:
            filter_expr = ms["multi_service_filter"]
        else:
            filter_expr = f'service.name="{ms["service_name"]}"'

        # Per-microservice threshold overrides. The manifest can supply a
        # `kpi_thresholds` block on a microservice with `latency` and/or
        # `error_rate` keys to tune red/yellow firing per service. We pick
        # this up so demo presenters can pin which service "owns" the
        # red/orange visual without having to flatten the L3 template.
        ms_thresholds  = ms.get("kpi_thresholds", {}) or {}
        lat_threshold  = ms_thresholds.get("latency",    {"critical": 3000, "warning": 1500})
        err_threshold  = ms_thresholds.get("error_rate", {"critical": 0.05, "warning": 0.02})

        kpis = [
            {
                "title":            "p99 latency",
                "base_search_id":   "kbs_apm_latency",
                "metric_id":        "p99_ms",
                "filter":           filter_expr,
                "weight":           5,
                "threshold":        lat_threshold,
            },
            {
                "title":            "error rate",
                "base_search_id":   "kbs_apm_error_rate",
                "metric_id":        "error_rate",
                "filter":           filter_expr,
                "weight":           5,
                "threshold":        err_threshold,
            },
        ]

        out.append({
            "key":                   ms["key"],
            "title":                 ms["title"],
            "description":           f"L3 microservice. OTel service.name={ms['service_name']}",
            "severity_aggregation":  "weighted_avg",
            "depends_on":            ms.get("l4_deps", []),
            "kpis":                  kpis,
            "entity_rules":          [{
                "rule_condition": "AND",
                "rule_items": [{
                    "field":           "service_name",
                    "field_type":      "alias",
                    "rule_type":       "matches",
                    "value":           ms["service_name"],
                }],
            }],
        })
    return out


# ---------------------------------------------------------------------------
# Entity rendering
# ---------------------------------------------------------------------------
def render_entity(ent: dict) -> dict:
    """Render an ITSI entity payload.

    ITSI's _populate_identifier_and_info_fields_blob() (SA-ITOA/lib/itsi/
    objects/itsi_entity.py:160-211) requires every field listed under
    `identifier.fields` / `informational.fields` to appear as a TOP-LEVEL
    key on the entity dict whose value is a list[str]. ITSI then derives
    `identifier.values` / `informational.values` from those top-level keys
    automatically. Putting values inline under .values is silently dropped.
    """
    title = ent["title"]
    identifier_values: dict[str, list[str]] = {
        safe_field(k): [str(v)] for k, v in ent.get("identifier", {}).items()
    }
    informational_values: dict[str, list[str]] = {
        safe_field(k): [str(v)] for k, v in ent.get("informational", {}).items()
    }

    if ent.get("_key"):
        entity_key = str(ent["_key"]).strip()
    else:
        entity_key = f"ent_{title.replace('-', '_').replace('.', '_')}"

    svc_links = []
    for s in ent.get("services", []) or []:
        svc_links.append({"_key": s["key"], "title": s["title"]})

    payload = {
        "_key":                  entity_key,
        "object_type":           "entity",
        "title":                 title,
        "description":           ent.get("description", ""),
        "identifier":            {
            "fields": list(identifier_values.keys()),
            "values": [],
        },
        "informational":         {
            "fields": list(informational_values.keys()),
            "values": [],
        },
        "services":              svc_links,
        "tags":                  ["nwpay-demo"],
        "sec_grp":                "default_itsi_security_group",
    }
    et_ids = ent.get("entity_type_ids") or []
    if et_ids:
        payload["entity_type_ids"] = list(et_ids)
    for field, values in {**identifier_values, **informational_values}.items():
        payload[field] = values
    return payload


TE_STATE_KEY_BY_REF = {
    "TE-01": "TE-01-http-spa.json",
    "TE-02": "TE-02-http-api.json",
    "TE-03": "TE-03-pageload-spa.json",
    "TE-04": "TE-04-transaction-payment.json",
    "TE-05": "TE-05-api-post-process.json",
    "TE-06": "TE-06-dns-server.json",
}

SYNTH_OUTCOMES_SVC = "nwpay_l2_synth_outcomes"

# Maps each ThousandEyes reference to the Splunk Observability Synthetics
# test name provisioned by terraform/observability.tf (null_resource.splunk_synthetic_*).
SYN_TEST_NAME_BY_TE_REF = {
    "TE-01": "[NatWest demo] SPA health",
    "TE-02": "[NatWest demo] payments gateway",
    "TE-03": "[NatWest demo] payments SPA",
    "TE-04": "[NatWest demo] payments SPA",
    "TE-05": "[NatWest demo] payments gateway",
    "TE-06": "[NatWest demo] public proxy health",
}


def resolve_o11y_realm(manifest: dict) -> str:
    env_realm = os.environ.get("TF_VAR_splunk_realm", "").strip()
    if env_realm:
        return env_realm
    meta = manifest.get("metadata") or {}
    return str(meta.get("splunk_o11y_realm", "eu0")).strip() or "eu0"


def substitute_o11y_realm(value: Any, realm: str) -> Any:
    if isinstance(value, str):
        return value.replace("__SPLUNK_REALM__", realm)
    if isinstance(value, list):
        return [substitute_o11y_realm(v, realm) for v in value]
    if isinstance(value, dict):
        return {k: substitute_o11y_realm(v, realm) for k, v in value.items()}
    return value


def fetch_syn_test_ids(realm: str, token: str) -> dict[str, str]:
    """Return Splunk Synthetics test name -> numeric test id."""
    url = f"https://api.{realm}.signalfx.com/v2/synthetics/tests?limit=5000"
    req = urllib.request.Request(
        url,
        headers={"X-SF-TOKEN": token, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    items = body.get("results") or body.get("tests") or []
    out: dict[str, str] = {}
    for item in items:
        name = item.get("name")
        test_id = item.get("id") or item.get("testId")
        if name and test_id is not None:
            out[str(name)] = str(test_id)
    return out


def split_synth_outcome_entities(entity_defs: list[dict]) -> list[dict]:
    """Fork TE entities so Synthetic Business Outcomes gets Splunk drilldowns.

    DCE keeps the ThousandEyes entity type; the parallel ent_syn_* copy keeps
    the same te_test_name identifier for KPI entity-breakdown joins but uses
    nwpay_et_splunk_synthetics navigation drilldowns.
    """
    out: list[dict] = list(entity_defs)
    for ent in entity_defs:
        ent_key = str(ent.get("_key") or "")
        if not ent_key.startswith("ent_te_"):
            continue
        info = dict(ent.get("informational") or {})
        te_ref = str(info.get("te_reference") or "")
        if not te_ref:
            continue
        syn_ent_key = ent_key.replace("ent_te_", "ent_syn_")
        syn_ent = {
            "_key":              syn_ent_key,
            "title":             ent.get("title", ""),
            "description":       (
                "Splunk Observability Synthetics drilldown target for "
                "Synthetic Business Outcomes KPIs."
            ),
            "entity_type_ids":   ["nwpay_et_splunk_synthetics"],
            "identifier":        dict(ent.get("identifier") or {}),
            "informational":     {
                "entity_family": "splunk_synthetics_outcomes",
                "te_reference":  te_ref,
                "syn_test_name": SYN_TEST_NAME_BY_TE_REF.get(te_ref, ""),
            },
            "services":          [{
                "key":   SYNTH_OUTCOMES_SVC,
                "title": "Synthetic Business Outcomes",
            }],
        }
        out.append(syn_ent)
    return out


def enrich_syn_entities(entity_defs: list[dict], manifest: dict) -> list[dict]:
    """Patch syn_test_id on Splunk Synthetics outcome entities."""
    realm = resolve_o11y_realm(manifest)
    token = os.environ.get("TF_VAR_splunk_api_token", "").strip()
    id_by_name: dict[str, str] = {}
    if token:
        try:
            id_by_name = fetch_syn_test_ids(realm, token)
            LOG.info("[syn] loaded %d Splunk Synthetics test id(s) from API", len(id_by_name))
        except (urllib.error.URLError, json.JSONDecodeError, OSError) as exc:
            LOG.warning("[syn] cannot list Splunk Synthetics tests: %s", exc)

    out: list[dict] = []
    for ent in entity_defs:
        ent = dict(ent)
        info = dict(ent.get("informational") or {})
        if info.get("entity_family") != "splunk_synthetics_outcomes":
            out.append(ent)
            continue
        syn_name = str(info.get("syn_test_name") or "")
        if syn_name and syn_name in id_by_name:
            info["syn_test_id"] = id_by_name[syn_name]
        ent["informational"] = info
        out.append(ent)
    return out


def enrich_te_entities(entity_defs: list[dict], manifest_path: Path) -> list[dict]:
    """Patch te_test_id on ThousandEyes entities from secrets/te-state.json."""
    state_file = manifest_path.parent.parent / "secrets" / "te-state.json"
    if not state_file.is_file():
        return entity_defs
    try:
        state = json.loads(state_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        LOG.warning("[te-state] cannot read %s: %s", state_file, exc)
        return entity_defs

    out = []
    for ent in entity_defs:
        ent = dict(ent)
        info = dict(ent.get("informational") or {})
        te_ref = info.get("te_reference")
        state_key = TE_STATE_KEY_BY_REF.get(te_ref or "")
        if state_key and state_key in state:
            test_id = state[state_key].get("testId")
            if test_id is not None:
                info["te_test_id"] = str(test_id)
        if info:
            ent["informational"] = info
        out.append(ent)
    return out


def render_entity_type(et: dict, manifest: dict) -> dict:
    """Render an ITSI entity_type (drilldown class for synthetic / TE entities).

    The ITSI REST API requires several fields to be present (not None):
    `data_drilldowns` and `dashboard_drilldowns` must be lists, and
    `dashboard_type` must be a string ("" is accepted for entity types that
    don't ship a built-in overview dashboard). We accept singular legacy
    aliases from the YAML and always emit the plural API field names.
    """
    sec = manifest["metadata"].get("security_group", "default_itsi_security_group")
    realm = resolve_o11y_realm(manifest)
    dash_dd = substitute_o11y_realm(
        et.get("dashboard_drilldowns") or et.get("dashboard_drilldown") or [],
        realm,
    )
    data_dd = substitute_o11y_realm(
        et.get("data_drilldowns") or et.get("data_drilldown") or [],
        realm,
    )
    vm = et.get("vital_metrics") or []
    dash_type = et.get("dashboard_type", "")
    has_nav_link = any(
        (dd.get("dashboard_type") or "") == "navigation_link" for dd in dash_dd
    )
    has_splunk_dash = any(
        (dd.get("dashboard_type") or "") in ("xml_dashboard", "udf_dashboard")
        for dd in dash_dd
    )
    show_nav_sa = et.get("show_navigation_in_service_analyzer")
    if show_nav_sa is None and has_nav_link:
        show_nav_sa = True
    show_dash_sa = et.get("show_dashboards_in_service_analyzer")
    if show_dash_sa is None and has_splunk_dash:
        show_dash_sa = True

    payload = {
        "_key":                   et["_key"],
        "object_type":            "entity_type",
        "title":                  et["title"],
        "description":            et.get("description", ""),
        "dashboard_drilldowns":   dash_dd,
        "data_drilldowns":        data_dd,
        "dashboard_type":         dash_type,
        "vital_metrics":          vm,
        "sec_grp":                sec,
    }
    if show_nav_sa is not None:
        payload["show_navigation_in_service_analyzer"] = bool(show_nav_sa)
    if show_dash_sa is not None:
        payload["show_dashboards_in_service_analyzer"] = bool(show_dash_sa)
    return payload


def microservice_entities(manifest: dict) -> list[dict]:
    """Render one ITSI entity per microservice in the manifest.

    Earlier iterations of the manifest collapsed the six external payment
    schemes into a single "*-network" rollup microservice and listed the
    per-scheme entities here as a hardcoded loop. The manifest now defines
    each scheme as its own L3 microservice (faster-payments-network,
    bacs-network, chaps-network, swift-network, sepa-network,
    cheque-clearing-network), so they're picked up by the loop below
    without a special-case branch.
    """
    out = []
    for ms in manifest.get("microservices", []) or []:
        if ms.get("service_name") == "*-network":
            continue  # legacy wildcard rollup - kept for back-compat only
        out.append({
            "title":           ms["service_name"],
            # `service_name` rather than `service.name` because ITSI's entity
            # field validator rejects dots. The base searches `rename
            # service.name as service_name` so the alias still resolves.
            "identifier":      {"service_name": ms["service_name"]},
            "informational":   {
                "tier":           ms["title"],
                "environment":    "demo",
                "k8s_namespace":  "natwest",
            },
        })
    return out


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--manifest", default="itsi/service-tree.yaml")
    p.add_argument("--glass-table", default="itsi/glass-table/natwest-payments-overview.xml",
                   help="Simple XML dashboard to install as the L1 glass table")
    p.add_argument("--glass-table-app", default="itsi",
                   help="Splunk app to install the glass-table view in")
    p.add_argument("--glass-table-name", default="natwest_payments_overview",
                   help="Splunk view name for the glass-table dashboard")
    p.add_argument("--native-glass-table", default="itsi/glass-table/natwest-payments-overview.xml",
                   help="Source Simple XML to also publish as a native ITSI Glass "
                        "Table v3 object (so it appears under Service Insights -> "
                        "Glass Tables). Pass an empty string to skip.")
    p.add_argument("--native-glass-table-key", default="nwpay_glass_table_overview",
                   help="Stable _key for the native ITSI glass_table object")
    p.add_argument("--native-glass-table-title", default=None,
                   metavar="TITLE",
                   help="Title in ITSI Service Insights → Glass Tables (default: same as "
                        "Simple XML <label>, i.e. migrate the dashboard name verbatim)")
    p.add_argument("--customer-journey-xml", default="itsi/glass-table/natwest-customer-journey.xml",
                   help="Optional second dashboard — customer journey (Simple XML + native glass_table)")
    p.add_argument("--customer-journey-view", default="natwest_customer_journey",
                   help="Splunk view name for the customer journey dashboard")
    p.add_argument("--customer-journey-native-key", default="nwpay_glass_table_customer_journey",
                   help="Stable _key for the customer journey native ITSI glass_table object")
    p.add_argument("--customer-journey-title", default=None, metavar="TITLE",
                   help="Glass Tables list title for customer journey (default: XML <label>)")
    p.add_argument("--correlation-search", default="itsi/correlation-searches/o11y_to_itsi.json",
                   help="Correlation search JSON to install (kept for backwards "
                        "compatibility; --correlation-search-dir is preferred)")
    p.add_argument("--correlation-search-dir", default="itsi/correlation-searches",
                   help="Directory of correlation-search JSON files. Every *.json "
                        "file is upserted as a saved search in SA-ITOA with the "
                        "ITSI Event Generator action enabled.")
    p.add_argument("--aggregation-policies-dir", default="itsi/aggregation-policies",
                   help="Directory of notable_event_aggregation_policy JSON files. "
                        "Optional; missing directory is silently skipped.")
    p.add_argument("--host",     default=os.getenv("SPLUNK_ENTERPRISE_HOST", "localhost"))
    p.add_argument("--port",     type=int, default=int(os.getenv("SPLUNK_MGMT_PORT", "8089")))
    p.add_argument("--user",     default=os.getenv("SPLUNK_ADMIN_USER", "admin"))
    p.add_argument("--password", default=os.getenv("TF_VAR_splunk_enterprise_admin_password", ""))
    p.add_argument("--dry-run",  action="store_true", help="render JSON to stdout, do not POST")
    p.add_argument("--verbose",  action="store_true")
    args = p.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(message)s")

    if not args.password and not args.dry_run:
        LOG.error("missing admin password (set TF_VAR_splunk_enterprise_admin_password or --password)")
        return 2

    manifest_path = Path(args.manifest)
    if not manifest_path.is_file():
        LOG.error("manifest not found: %s", manifest_path)
        return 2
    manifest = yaml.safe_load(manifest_path.read_text())

    services_in = list(manifest.get("services", []))

    # Demo-mode threshold neutralisation. When the manifest declares
    # `demo_steady_state_green: true` (legacy alias: `demo_only_red_service`),
    # wipe inline KPI thresholds so steady-state traffic keeps L1/L2/L4 tiles
    # green. Services may opt selective KPIs back in via
    # `demo_threshold_kpi_titles` for chaos scenarios (tier throttle,
    # gold-fast-path-off, madrid-network-degradation, etc.).
    demo_green = manifest.get("demo_steady_state_green") or manifest.get(
        "demo_only_red_service"
    )
    if demo_green:
        kpi_count = 0
        preserved_svc = 0
        selective = 0
        for svc in services_in:
            if svc.get("preserve_inline_thresholds"):
                preserved_svc += 1
                continue
            keep_titles = set(svc.get("demo_threshold_kpi_titles") or [])
            for kpi in svc.get("kpis", []) or []:
                if not kpi.get("threshold"):
                    continue
                if keep_titles and kpi.get("title") in keep_titles:
                    selective += 1
                    continue
                base_id = kpi.get("base_search_id", "")
                if "chaos_gated" in base_id or base_id.endswith("_chaos_gated"):
                    selective += 1
                    continue
                kpi["threshold"] = {}   # render -> thresholdLevels: [] -> always normal
                kpi_count += 1
        for b in manifest.get("kpi_base_searches", []) or []:
            if b.get("id") not in DCE_STEADY_STATE_BASE_SEARCH_IDS:
                continue
            b["entity_breakdown"] = False
            for m in b.get("metrics", []) or []:
                m["gap_severity"] = "normal"
                if m.get("aggregate_statop") == "min":
                    m["aggregate_statop"] = "avg"
        LOG.info("[demo] steady_state_green -> cleared %d inline KPI threshold blocks "
                 "(%d services preserve_inline_thresholds; %d selective KPI thresholds kept; "
                 "microservice kpi_thresholds unchanged)",
                 kpi_count, preserved_svc, selective)

    # Build the full plan: order matters - base searches first, then services
    # in topological order (leaves -> root), then entities.
    base_searches = [render_kpi_base_search(b) for b in manifest.get("kpi_base_searches", [])]
    base_searches_by_id = {b["_key"]: b for b in base_searches}

    expanded = services_in + expand_microservices(manifest)
    # Topological order: dependencies before dependents. Simple post-order DFS.
    by_key = {s["key"]: s for s in expanded}
    visited: set[str] = set()
    ordered: list[dict] = []

    def visit(key: str):
        if key in visited or key not in by_key:
            return
        visited.add(key)
        for dep in by_key[key].get("depends_on", []) or []:
            visit(dep)
        ordered.append(by_key[key])

    for s in expanded:
        visit(s["key"])

    services = [render_service(s, manifest, base_searches_by_id) for s in ordered]

    entity_types = [render_entity_type(et, manifest) for et in (manifest.get("entity_types") or [])]

    entity_defs = split_synth_outcome_entities(
        list(manifest.get("entities", [])) + microservice_entities(manifest),
    )
    entity_defs = enrich_te_entities(entity_defs, Path(args.manifest))
    entity_defs = enrich_syn_entities(entity_defs, manifest)
    entities = [render_entity(e) for e in entity_defs]

    if args.dry_run:
        json.dump({
            "kpi_base_searches": base_searches,
            "services":          services,
            "entity_types":      entity_types,
            "entities":          entities,
        }, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0

    client = ItsiClient(args.host, args.port, args.user, args.password)

    # Sanity probe before we start posting - shows the connection works and
    # surfaces auth errors loudly.
    code, body = client.get("service", query={"limit": "1"})
    if code != 200:
        LOG.error("[fatal] cannot reach ITSI REST API at %s:%s (code=%s body=%s)",
                  args.host, args.port, code, body)
        return 1
    LOG.info("[connected] %s:%s as %s", args.host, args.port, args.user)

    fail = 0

    # Drop superseded L2 API Gateway before creating the L3 tile (same title).
    LOG.info("[step] stale L2 api-gateway cleanup (%d)", len(STALE_L2_API_GATEWAY_KEYS))
    fail += delete_stale_l2_api_gateway(client)

    LOG.info("[step] kpi_base_search (%d)", len(base_searches))
    fail += delete_demo_green_te_base_searches(client, bool(demo_green))
    for b in base_searches:
        if not client.upsert("kpi_base_search", b["_key"], b):
            fail += 1

    LOG.info("[step] service (%d, dependency-ordered)", len(services))
    fail += delete_demo_green_kpi_rebuild_services(client, services_in, bool(demo_green))
    for s in services:
        if not client.upsert("service", s["_key"], s):
            fail += 1

    LOG.info("[step] entity_type (%d)", len(entity_types))
    for et in entity_types:
        if not client.upsert("entity_type", et["_key"], et):
            fail += 1

    LOG.info("[step] entity (%d)", len(entities))
    for e in entities:
        if not client.upsert("entity", e["_key"], e):
            fail += 1

    LOG.info("[step] stale TE entity cleanup (%d)", len(STALE_TE_ENTITY_KEYS))
    fail += delete_stale_te_entities(client)
    LOG.info("[step] stale infra entity cleanup (%d)", len(STALE_INFRA_ENTITY_KEYS))
    fail += delete_stale_infra_entities(client)
    LOG.info("[step] stale tier service cleanup (%d)", len(STALE_TIER_SERVICE_KEYS))
    fail += delete_stale_tier_services(client)
    LOG.info("[step] stale channel service cleanup (%d)", len(STALE_CHANNEL_SERVICE_KEYS))
    fail += delete_stale_channel_services(client)
    LOG.info("[step] stale observability-stack service cleanup (%d)", len(STALE_OBSERVABILITY_STACK_SERVICE_KEYS))
    fail += delete_stale_observability_stack_services(client)
    LOG.info("[step] stale channel entity cleanup (%d)", len(STALE_CHANNEL_ENTITY_KEYS))
    fail += delete_stale_channel_entities(client)

    primary_view = Path(args.glass_table)
    primary_native = Path(args.native_glass_table) if args.native_glass_table else None
    fail += publish_glass_table_dashboard(
        client,
        primary_view,
        primary_native,
        view_app=args.glass_table_app,
        view_name=args.glass_table_name,
        native_key=args.native_glass_table_key,
        splunk_user=args.user,
        title_override=args.native_glass_table_title,
        title_fallback="NatWest Card Payments - Glass Table",
        description_fallback="Executive overview of NatWest Card Payments.",
    )

    cj_path = Path(args.customer_journey_xml)
    if cj_path.is_file():
        fail += publish_glass_table_dashboard(
            client,
            cj_path,
            cj_path,
            view_app=args.glass_table_app,
            view_name=args.customer_journey_view,
            native_key=args.customer_journey_native_key,
            splunk_user=args.user,
            title_override=args.customer_journey_title,
            title_fallback="NatWest Customer Journey",
            description_fallback="Customer journey view for NatWest Card Payments.",
        )
    else:
        LOG.info("[skip] customer journey glass-table XML not found: %s", cj_path)

    # Discover every correlation-search JSON to install. The single-file
    # --correlation-search flag remains for backwards compatibility (and
    # so a caller can drive one specific search); --correlation-search-
    # dir picks up every other file in the directory so dropping a new
    # SIEM correlation search into the repo is a one-file change with no
    # bootstrap edit.
    corr_paths: list[Path] = []
    seen: set[Path] = set()

    def _add_corr(p: Path) -> None:
        try:
            resolved = p.resolve()
        except OSError:
            resolved = p
        if resolved in seen:
            return
        seen.add(resolved)
        corr_paths.append(p)

    explicit_corr = Path(args.correlation_search)
    if explicit_corr.is_file():
        _add_corr(explicit_corr)

    corr_dir = Path(args.correlation_search_dir)
    if corr_dir.is_dir():
        for p in sorted(corr_dir.glob("*.json")):
            _add_corr(p)

    if not corr_paths:
        LOG.info("[skip] no correlation-search files found (looked at %s and %s)",
                 explicit_corr, corr_dir)

    for corr_path in corr_paths:
        try:
            corr = json.loads(corr_path.read_text())
        except json.JSONDecodeError as exc:
            LOG.error("[fail] malformed correlation search %s: %s", corr_path, exc)
            fail += 1
            continue
        if not corr.get("title") or not corr.get("search"):
            LOG.error("[fail] correlation search %s missing required 'title' or 'search'", corr_path)
            fail += 1
            continue
        # Translate the JSON manifest into a Splunk saved-search form payload.
        form = {
            "search":              corr["search"],
            "description":         corr.get("description", ""),
            "is_scheduled":        str(corr.get("is_scheduled", 1)),
            "cron_schedule":       corr.get("cron_schedule", "*/1 * * * *"),
            "dispatch.earliest_time": corr.get("dispatch.earliest_time", "-2m"),
            "dispatch.latest_time":   corr.get("dispatch.latest_time",   "now"),
            "alert_type":          corr.get("alert_type", "number of events"),
            "alert_comparator":    corr.get("alert_comparator", "greater than"),
            "alert_threshold":     str(corr.get("alert_threshold", "0")),
            "actions":             corr.get("actions", "itsi_event_generator"),
        }
        # Pass through the action.* params that drive notable-event creation.
        for k, v in corr.items():
            if k.startswith("action."):
                form[k] = str(v)
        LOG.info("[step] correlation search (%s in app=SA-ITOA)", corr["title"])
        if not client.upsert_saved_search("SA-ITOA", corr["title"], form):
            fail += 1

    # ITSI notable_event_aggregation_policy objects. Group related notable
    # events (e.g. the SWIFT-error span detector + the SIEM "off-window
    # chaos" notable) into one Episode so Episode Review surfaces one
    # ticket per logical incident.
    agg_dir = Path(args.aggregation_policies_dir)
    if agg_dir.is_dir():
        for agg_path in sorted(agg_dir.glob("*.json")):
            try:
                policy = json.loads(agg_path.read_text())
            except json.JSONDecodeError as exc:
                LOG.error("[fail] malformed aggregation policy %s: %s", agg_path, exc)
                fail += 1
                continue
            policy_key = policy.get("_key")
            if not policy_key:
                LOG.error("[fail] aggregation policy %s missing required '_key'", agg_path)
                fail += 1
                continue
            LOG.info("[step] notable_event_aggregation_policy (%s)", policy_key)
            if not client.upsert("notable_event_aggregation_policy", policy_key, policy):
                fail += 1
    else:
        LOG.info("[skip] aggregation-policies dir not found: %s", agg_dir)

    gt_bundles = 0
    if primary_view.is_file():
        gt_bundles += 1
        if primary_native and primary_native.is_file():
            gt_bundles += 1
    if cj_path.is_file():
        gt_bundles += 2
    agg_count = len(list(agg_dir.glob("*.json"))) if agg_dir.is_dir() else 0
    total_objects = (len(base_searches) + len(services) + len(entity_types) + len(entities)
                     + gt_bundles
                     + len(corr_paths)
                     + agg_count)
    LOG.info("[done] %d failures across %d objects", fail, total_objects)
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
