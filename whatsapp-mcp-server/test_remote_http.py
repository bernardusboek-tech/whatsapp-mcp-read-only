"""Synthetic Streamable HTTP checks. They do not start the bridge or WhatsApp."""

import asyncio
import logging
import os
import socket
import sys
import threading
import unittest
from pathlib import Path

import httpx
import uvicorn
from mcp import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client
from mcp.client.streamable_http import streamable_http_client

import main
import remote_http


ROOT = Path(__file__).resolve().parent


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def write_token(directory: Path, token: str) -> Path:
    path = directory / "mcp-token"
    path.write_text(token + "\n", encoding="utf-8")
    os.chmod(path, 0o600)
    return path


class HttpConfigTests(unittest.TestCase):
    def test_default_is_stdio(self):
        self.assertEqual(remote_http.resolve_transport({}), "stdio")

    def test_sse_and_wildcard_bind_are_rejected(self):
        with self.assertRaises(remote_http.TransportConfigError):
            remote_http.resolve_transport({"WA_MCP_TRANSPORT": "sse"})
        base = self._base()
        token = write_token(base, "synthetic-token-value")
        env = {
            "WA_MCP_TRANSPORT": "streamable-http",
            "MCP_AUTH_TOKEN_FILE": str(token),
            "WA_MCP_PORT": "8765",
            "WA_MCP_BIND": "0.0.0.0",
        }
        with self.assertRaises(remote_http.TransportConfigError):
            remote_http.load_http_config(env)

    def test_missing_token_file_is_rejected(self):
        env = {
            "WA_MCP_TRANSPORT": "streamable-http",
            "WA_MCP_PORT": "8765",
            "MCP_AUTH_TOKEN_FILE": str(self._base() / "missing-token"),
        }
        with self.assertRaises(remote_http.TransportConfigError):
            remote_http.load_http_config(env)

    def _base(self) -> Path:
        import tempfile

        path = Path(tempfile.mkdtemp(prefix="wa-http-"))
        self.addCleanup(lambda: None)
        return path


class StreamableHttpTests(unittest.TestCase):
    def setUp(self):
        import tempfile

        self.base = Path(tempfile.mkdtemp(prefix="wa-http-"))
        self.token = "synthetic-bearer-not-a-session"
        self.token_path = write_token(self.base, self.token)
        self.port = free_port()
        env = {
            "WA_MCP_TRANSPORT": "streamable-http",
            "MCP_AUTH_TOKEN_FILE": str(self.token_path),
            "WA_MCP_PORT": str(self.port),
            "WA_MCP_BIND": "127.0.0.1",
            "WA_REPO_ROOT": str(ROOT.parent),
        }
        self.config = remote_http.load_http_config(env)
        self.app = remote_http.build_http_app(self.config, main.mcp)
        self.server = uvicorn.Server(
            uvicorn.Config(
                self.app,
                host="127.0.0.1",
                port=self.port,
                access_log=False,
                log_level="error",
                lifespan="on",
            )
        )
        self.thread = threading.Thread(target=self.server.run, daemon=True)
        self.thread.start()
        for _ in range(100):
            if self.server.started:
                break
            self.thread.join(0.05)
        if not self.server.started:
            self.fail("loopback server did not start")

    def tearDown(self):
        self.server.should_exit = True
        self.thread.join(timeout=5)

    def test_auth_origin_and_tool_surface(self):
        base = f"http://127.0.0.1:{self.port}/mcp"
        unauthenticated = httpx.post(base, json={"jsonrpc": "2.0", "id": 1, "method": "initialize"})
        self.assertEqual(unauthenticated.status_code, 401)
        wrong = httpx.post(
            base,
            headers={"Authorization": "Bearer wrong-token"},
            json={"jsonrpc": "2.0", "id": 1, "method": "initialize"},
        )
        self.assertEqual(wrong.status_code, 401)
        query = httpx.post(
            base,
            params={"access_token": self.token},
            headers={"Authorization": f"Bearer {self.token}"},
            json={"jsonrpc": "2.0", "id": 1, "method": "initialize"},
        )
        self.assertEqual(query.status_code, 400)
        self.assertNotIn(self.token.encode(), query.content)
        bad_origin = httpx.post(
            base,
            headers={"Authorization": f"Bearer {self.token}", "Origin": "http://evil.example"},
            json={"jsonrpc": "2.0", "id": 1, "method": "initialize"},
        )
        self.assertEqual(bad_origin.status_code, 403)
        bad_host = httpx.post(
            base,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Host": "evil.example",
            },
            json={"jsonrpc": "2.0", "id": 1, "method": "initialize"},
        )
        self.assertIn(bad_host.status_code, (403, 421))
        logs = _capture(self._handshake)
        self.assertNotIn(self.token, logs)
        self.assertNotIn("mcp-session-id", logs.lower())

    def _handshake(self) -> None:
        asyncio.run(self._list_tools())

    async def _list_tools(self) -> None:
        client = httpx.AsyncClient(headers={"Authorization": f"Bearer {self.token}"})
        async with streamable_http_client(
            f"http://127.0.0.1:{self.port}/mcp",
            http_client=client,
        ) as (read, write, _get_session):
            async with ClientSession(read, write) as session:
                await session.initialize()
                listed = await session.list_tools()
        names = sorted(tool.name for tool in listed.tools)
        self.assertEqual(
            names,
            [
                "download_media",
                "get_chat",
                "get_contact_chats",
                "get_direct_chat_by_contact",
                "get_last_interaction",
                "get_message_context",
                "list_chats",
                "list_messages",
                "search_contacts",
            ],
        )
        for banned in ("send_message", "send_file", "send_audio_message"):
            self.assertNotIn(banned, names)


class StdioCompatibilityTests(unittest.TestCase):
    def test_stdio_lists_the_same_read_tools(self):
        env = os.environ.copy()
        env["WA_MCP_TRANSPORT"] = "stdio"
        env.pop("WA_PAIR", None)
        params = StdioServerParameters(
            command=sys.executable,
            args=[str(ROOT / "main.py")],
            cwd=str(ROOT),
            env=env,
        )

        async def run() -> list[str]:
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    listed = await session.list_tools()
                    return sorted(tool.name for tool in listed.tools)

        names = asyncio.run(run())
        self.assertIn("list_messages", names)
        self.assertNotIn("send_message", names)


def _capture(fn) -> str:
    records: list[str] = []

    class Grab(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            records.append(record.getMessage())

    handler = Grab(level=logging.DEBUG)
    root = logging.getLogger()
    previous = root.level
    root.setLevel(logging.DEBUG)
    root.addHandler(handler)
    try:
        fn()
    finally:
        root.removeHandler(handler)
        root.setLevel(previous)
    return "\n".join(records)


if __name__ == "__main__":
    unittest.main()
