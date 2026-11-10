"""Opt-in Streamable HTTP for the read-only MCP server.

The default remains stdio. HTTP listens only when WA_MCP_TRANSPORT is
streamable-http, and only with a bearer token file. This module does not
connect to WhatsApp and does not start the bridge.
"""

from __future__ import annotations

import hmac
import logging
import os
import stat
from dataclasses import dataclass

from mcp.server.auth.provider import AccessToken
from mcp.server.auth.settings import AuthSettings
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings
from starlette.types import ASGIApp, Receive, Scope, Send

LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})
WILDCARD_HOSTS = frozenset({"0.0.0.0", "::", "::0"})
QUERY_CREDENTIAL_KEYS = frozenset({"token", "access_token", "auth", "authorization"})


class TransportConfigError(RuntimeError):
    """The HTTP listener must not start."""


@dataclass(frozen=True)
class HttpConfig:
    bind: str
    port: int
    token: str
    allowed_hosts: list[str]
    allowed_origins: list[str]
    resource_url: str


class StaticBearerVerifier:
    """Accept one configured bearer. The secret is not returned or logged."""

    def __init__(self, token: str) -> None:
        self._token = token

    async def verify_token(self, token: str) -> AccessToken | None:
        if not token or len(token) != len(self._token):
            hmac.compare_digest(self._token, self._token)
            return None
        if not hmac.compare_digest(token, self._token):
            return None
        return AccessToken(token="accepted", client_id="configured-client", scopes=["read"])


class RejectQueryCredentialMiddleware:
    """Refuse credentials in the URL. The rejection body does not echo them."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope.get("type") == "http":
            raw = scope.get("query_string", b"")
            if raw and _query_has_credential(raw):
                body = b"credentials in the query string are not accepted"
                await send(
                    {
                        "type": "http.response.start",
                        "status": 400,
                        "headers": [
                            (b"content-type", b"text/plain; charset=utf-8"),
                            (b"content-length", str(len(body)).encode()),
                        ],
                    }
                )
                await send({"type": "http.response.body", "body": body})
                return
        await self.app(scope, receive, send)


def resolve_transport(environ: dict[str, str] | None = None) -> str:
    env = os.environ if environ is None else environ
    transport = env.get("WA_MCP_TRANSPORT", "stdio").strip() or "stdio"
    if transport == "stdio":
        return "stdio"
    if transport == "streamable-http":
        return "streamable-http"
    raise TransportConfigError("WA_MCP_TRANSPORT must be stdio or streamable-http")


def load_http_config(environ: dict[str, str] | None = None) -> HttpConfig:
    env = os.environ if environ is None else environ
    if resolve_transport(env) != "streamable-http":
        raise TransportConfigError("HTTP config requested while transport is stdio")
    token = _read_token(env)
    port = _port(env.get("WA_MCP_PORT", ""))
    bind = env.get("WA_MCP_BIND", "127.0.0.1").strip() or "127.0.0.1"
    if bind in WILDCARD_HOSTS:
        raise TransportConfigError("wildcard bind is not allowed")
    non_loopback = bind not in LOOPBACK_HOSTS
    if non_loopback and env.get("WA_MCP_ALLOW_NON_LOOPBACK") != "1":
        raise TransportConfigError("non-loopback bind requires WA_MCP_ALLOW_NON_LOOPBACK=1")
    allowed_hosts = _csv(env.get("WA_MCP_ALLOWED_HOSTS", ""))
    if non_loopback and not allowed_hosts:
        raise TransportConfigError("WA_MCP_ALLOWED_HOSTS is required for a non-loopback bind")
    if not allowed_hosts:
        host_for_header = bind
        allowed_hosts = [f"{host_for_header}:{port}"]
        if bind == "127.0.0.1":
            allowed_hosts.append(f"localhost:{port}")
    allowed_origins = _csv(env.get("WA_MCP_ALLOWED_ORIGINS", ""))
    resource = env.get("WA_MCP_RESOURCE_URL", "").strip()
    if not resource:
        if non_loopback:
            raise TransportConfigError("WA_MCP_RESOURCE_URL is required for a non-loopback bind")
        resource = f"http://{bind}:{port}"
    if not resource.startswith("http://") and not resource.startswith("https://"):
        raise TransportConfigError("WA_MCP_RESOURCE_URL must be an http or https URL")
    return HttpConfig(
        bind=bind,
        port=port,
        token=token,
        allowed_hosts=allowed_hosts,
        allowed_origins=allowed_origins,
        resource_url=resource.rstrip("/"),
    )


def build_http_app(config: HttpConfig, tool_source: FastMCP) -> ASGIApp:
    """Build the authenticated Streamable HTTP app. It does not listen yet."""
    security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=list(config.allowed_hosts),
        allowed_origins=list(config.allowed_origins),
    )
    server = FastMCP(
        "whatsapp",
        host=config.bind,
        port=config.port,
        log_level="ERROR",
        json_response=True,
        stateless_http=True,
        streamable_http_path="/mcp",
        auth=AuthSettings(
            issuer_url=f"{config.resource_url}/oauth-not-configured",
            resource_server_url=config.resource_url,
            required_scopes=["read"],
        ),
        token_verifier=StaticBearerVerifier(config.token),
        transport_security=security,
    )
    for tool in tool_source._tool_manager.list_tools():
        server.add_tool(
            tool.fn,
            name=tool.name,
            description=tool.description,
            structured_output=False,
        )
    _quiet_loggers()
    return RejectQueryCredentialMiddleware(server.streamable_http_app())


def serve_http(config: HttpConfig, tool_source: FastMCP) -> None:
    import uvicorn

    app = build_http_app(config, tool_source)
    uvicorn.run(
        app,
        host=config.bind,
        port=config.port,
        access_log=False,
        log_level="error",
        lifespan="on",
    )


def _quiet_loggers() -> None:
    logging.getLogger().setLevel(logging.ERROR)
    for name in ("mcp", "uvicorn", "uvicorn.error", "uvicorn.access", "httpx", "httpcore"):
        logging.getLogger(name).setLevel(logging.ERROR)
    logging.getLogger("uvicorn.access").disabled = True


def _read_token(env: dict[str, str]) -> str:
    path = env.get("MCP_AUTH_TOKEN_FILE", "").strip()
    if not path or not os.path.isabs(path):
        raise TransportConfigError("MCP_AUTH_TOKEN_FILE must be an absolute path")
    repo = env.get("WA_REPO_ROOT", "").strip()
    if repo:
        real = os.path.realpath(path)
        repo_real = os.path.realpath(repo)
        if real == repo_real or real.startswith(repo_real + os.sep):
            raise TransportConfigError("token file must be outside the repository")
    try:
        mode = os.stat(path).st_mode
    except OSError as exc:
        raise TransportConfigError("token file is not readable") from exc
    if stat.S_IMODE(mode) & 0o077:
        raise TransportConfigError("token file must not be group or world accessible")
    with open(path, "r", encoding="utf-8") as handle:
        token = handle.read().strip()
    if not token or any(ch.isspace() for ch in token):
        raise TransportConfigError("token file must contain one non-empty line")
    return token


def _port(raw: str) -> int:
    if not raw.strip():
        raise TransportConfigError("WA_MCP_PORT is required")
    try:
        port = int(raw)
    except ValueError as exc:
        raise TransportConfigError("WA_MCP_PORT must be an integer") from exc
    if port < 1 or port > 65535:
        raise TransportConfigError("WA_MCP_PORT is out of range")
    return port


def _csv(raw: str) -> list[str]:
    return [part.strip() for part in raw.split(",") if part.strip()]


def _query_has_credential(raw: bytes) -> bool:
    from urllib.parse import parse_qs

    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        return True
    parsed = parse_qs(text, keep_blank_values=True)
    return any(key.lower() in QUERY_CREDENTIAL_KEYS for key in parsed)
