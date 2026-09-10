"""Thin Kubernetes client wrapper used by chaos scenarios.

All operations target a single namespace (``NAMESPACE`` env, default
``natwest``). Verbs are deliberately limited to deployments
(``get/list/patch`` + ``deployments/scale``) and pods
(``get/list/delete``); the controller's RBAC Role grants only those.

Every mutating helper returns a small dict describing the observed
state diff (``before`` / ``after``) so callers can include it in the
HEC audit payload and surface it on the dashboard.
"""

from __future__ import annotations

import logging
import os
import random
import threading
from typing import Any, Iterable

from kubernetes import client, config
from kubernetes.client.rest import ApiException

LOG = logging.getLogger("chaos-controller.k8s")

NAMESPACE = os.environ.get("NAMESPACE", "natwest").strip() or "natwest"

_init_lock = threading.Lock()
_apps_v1: client.AppsV1Api | None = None
_core_v1: client.CoreV1Api | None = None


def _initialise_clients() -> tuple[client.AppsV1Api, client.CoreV1Api]:
    global _apps_v1, _core_v1
    with _init_lock:
        if _apps_v1 is not None and _core_v1 is not None:
            return _apps_v1, _core_v1
        try:
            config.load_incluster_config()
            LOG.info("kube_config loaded_from=incluster namespace=%s", NAMESPACE)
        except config.ConfigException:
            config.load_kube_config()
            LOG.info("kube_config loaded_from=kubeconfig namespace=%s", NAMESPACE)
        _apps_v1 = client.AppsV1Api()
        _core_v1 = client.CoreV1Api()
        return _apps_v1, _core_v1


def apps() -> client.AppsV1Api:
    return _initialise_clients()[0]


def core() -> client.CoreV1Api:
    return _initialise_clients()[1]


# ---------------------------------------------------------------------------
# Deployment helpers.
# ---------------------------------------------------------------------------


def _container_env_to_map(env_list: Iterable[client.V1EnvVar] | None) -> dict[str, str]:
    out: dict[str, str] = {}
    if not env_list:
        return out
    for ev in env_list:
        if ev.value is not None:
            out[ev.name] = str(ev.value)
        elif ev.value_from is not None:
            out[ev.name] = "<valueFrom>"
    return out


def current_env(deployment: str, keys: Iterable[str]) -> dict[str, str]:
    """Return the current value of ``keys`` on the first container of ``deployment``.

    Missing keys return as empty strings (matching the SPA HUD's
    ``vars[k]`` shape). Errors return an empty dict so callers can fall
    back to ``unknown`` status rather than crashing.
    """
    try:
        depl = apps().read_namespaced_deployment(name=deployment, namespace=NAMESPACE)
    except ApiException as exc:
        LOG.warning("read_deployment_failed deploy=%s status=%s", deployment, exc.status)
        return {}
    containers = (depl.spec.template.spec.containers or []) if depl.spec and depl.spec.template else []
    if not containers:
        return {}
    env_map = _container_env_to_map(containers[0].env)
    return {k: env_map.get(k, "") for k in keys}


def set_env(deployment: str, env_vars: dict[str, str]) -> dict[str, Any]:
    """Patch the first container's env on ``deployment`` (rolling restart).

    Only the supplied keys are touched; existing variables not in the
    patch are preserved. Equivalent to::

        kubectl set env deploy/<deployment> KEY=value KEY2=value2

    Returns the observed before/after diff for audit logging.
    """
    apps_api = apps()
    try:
        depl = apps_api.read_namespaced_deployment(name=deployment, namespace=NAMESPACE)
    except ApiException as exc:
        raise RuntimeError(
            f"read_deployment_failed deploy={deployment} status={exc.status}"
        ) from exc

    if not depl.spec or not depl.spec.template or not depl.spec.template.spec:
        raise RuntimeError(f"deployment {deployment} has no podSpec")
    containers = depl.spec.template.spec.containers or []
    if not containers:
        raise RuntimeError(f"deployment {deployment} has no containers")

    target = containers[0]
    before_env = _container_env_to_map(target.env)

    new_env: list[dict[str, Any]] = []
    seen: set[str] = set()
    for ev in target.env or []:
        if ev.name in env_vars:
            new_env.append({"name": ev.name, "value": str(env_vars[ev.name])})
            seen.add(ev.name)
        elif ev.value_from is not None:
            # Preserve valueFrom references verbatim. We don't reach into
            # secret/configMap-backed env vars from the chaos controller.
            new_env.append({
                "name": ev.name,
                "valueFrom": apps_api.api_client.sanitize_for_serialization(ev.value_from),
            })
        else:
            new_env.append({"name": ev.name, "value": ev.value if ev.value is not None else ""})
    for key, value in env_vars.items():
        if key in seen:
            continue
        new_env.append({"name": key, "value": str(value)})

    patch = {
        "spec": {
            "template": {
                "spec": {
                    "containers": [
                        {
                            "name": target.name,
                            "env": new_env,
                        }
                    ]
                }
            }
        }
    }

    try:
        apps_api.patch_namespaced_deployment(
            name=deployment, namespace=NAMESPACE, body=patch
        )
    except ApiException as exc:
        raise RuntimeError(
            f"patch_deployment_failed deploy={deployment} status={exc.status}"
        ) from exc

    after_env = {**before_env, **{k: str(v) for k, v in env_vars.items()}}
    return {
        "deployment": deployment,
        "before": {k: before_env.get(k, "") for k in env_vars},
        "after": {k: after_env[k] for k in env_vars},
    }


def current_replicas(deployment: str) -> int | None:
    """Read the current declared replica count, or None on failure."""
    try:
        scale = apps().read_namespaced_deployment_scale(
            name=deployment, namespace=NAMESPACE
        )
    except ApiException as exc:
        LOG.warning("read_scale_failed deploy=%s status=%s", deployment, exc.status)
        return None
    return scale.spec.replicas if scale.spec else None


def scale(deployment: str, replicas: int) -> dict[str, Any]:
    """Patch ``spec.replicas`` on ``deployment``. Returns before/after."""
    if replicas < 0 or replicas > 32:
        raise ValueError("replicas must be in [0, 32]")
    apps_api = apps()
    before = current_replicas(deployment)
    body = {"spec": {"replicas": int(replicas)}}
    try:
        apps_api.patch_namespaced_deployment_scale(
            name=deployment, namespace=NAMESPACE, body=body
        )
    except ApiException as exc:
        raise RuntimeError(
            f"scale_failed deploy={deployment} status={exc.status}"
        ) from exc
    return {"deployment": deployment, "before": before, "after": int(replicas)}


def delete_random_pod(label_selector: str) -> dict[str, Any]:
    """Delete one matching pod (random selection)."""
    core_api = core()
    try:
        pods = core_api.list_namespaced_pod(
            namespace=NAMESPACE,
            label_selector=label_selector,
        )
    except ApiException as exc:
        raise RuntimeError(
            f"list_pods_failed selector={label_selector} status={exc.status}"
        ) from exc
    if not pods.items:
        return {"deleted": None, "selector": label_selector, "match_count": 0}
    victim = random.choice(pods.items)
    try:
        core_api.delete_namespaced_pod(
            name=victim.metadata.name,
            namespace=NAMESPACE,
            grace_period_seconds=0,
        )
    except ApiException as exc:
        raise RuntimeError(
            f"delete_pod_failed name={victim.metadata.name} status={exc.status}"
        ) from exc
    return {
        "deleted": victim.metadata.name,
        "selector": label_selector,
        "match_count": len(pods.items),
    }


def deployment_exists(deployment: str) -> bool:
    try:
        apps().read_namespaced_deployment(name=deployment, namespace=NAMESPACE)
        return True
    except ApiException:
        return False
