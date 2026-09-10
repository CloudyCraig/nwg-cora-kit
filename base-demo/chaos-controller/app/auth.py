"""Token authentication middleware for the chaos-controller HTTP API.

The dashboard is a presenter-only surface: a single shared bearer token
mounted from a Kubernetes Secret authenticates every mutating request.
Comparison is constant-time (``hmac.compare_digest``) to deny timing
side-channels (codeguard-0-authentication-mfa). When the token is not
configured the controller refuses to accept any POSTs - the dashboard
fails closed.
"""

from __future__ import annotations

import functools
import hmac
import logging
import os
from typing import Any, Callable

from flask import abort, request

LOG = logging.getLogger("chaos-controller.auth")

_TOKEN_ENV = "CHAOS_PRESENTER_TOKEN"
_TOKEN_PATH_ENV = "CHAOS_PRESENTER_TOKEN_PATH"
_HEADER_NAME = "X-Chaos-Token"


def _read_token_file(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError as exc:  # noqa: BLE001
        LOG.warning("token_path_unreadable path=%s err=%s", path, exc)
        return ""


def _expected_token() -> str:
    """Resolve the presenter token from a mounted file or env var.

    Precedence:
      1. ``CHAOS_PRESENTER_TOKEN_PATH`` - path to a Secret-mounted file.
         Preferred because the token never appears in the pod spec.
      2. ``CHAOS_PRESENTER_TOKEN`` - environment variable. Used by the
         Helm chart when ``chaosController.presenterToken`` is set.
    Returns an empty string when neither is configured; the request
    handler treats this as "no token configured, deny all".
    """
    path = os.environ.get(_TOKEN_PATH_ENV, "").strip()
    if path:
        tok = _read_token_file(path)
        if tok:
            return tok
    env = os.environ.get(_TOKEN_ENV, "").strip()
    return env


def require_presenter_token(func: Callable[..., Any]) -> Callable[..., Any]:
    """Flask decorator: reject any request without a matching token.

    Sends a generic ``401`` body (no token-was-empty-vs-mismatch leak)
    so unauthorised callers cannot probe the controller for the
    presence of a configured secret.
    """

    @functools.wraps(func)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        expected = _expected_token()
        provided = request.headers.get(_HEADER_NAME, "").strip()
        if not expected or not provided or not hmac.compare_digest(
            expected.encode("utf-8"), provided.encode("utf-8")
        ):
            LOG.warning(
                "chaos_auth_denied path=%s ip=%s",
                request.path,
                request.headers.get("X-Forwarded-For", request.remote_addr or "?"),
            )
            abort(401, description="invalid presenter token")
        return func(*args, **kwargs)

    return wrapper


def auth_configured() -> bool:
    """True when at least an expected token is present.

    The /chaos/api/scenarios catalog endpoint is GET-only and read-only,
    but we still gate it behind the same token (the dashboard fetches
    with the same header) to avoid surfacing the scenario catalog to
    unauthenticated callers, which would otherwise enumerate the
    deployments the controller can target.
    """
    return bool(_expected_token())
