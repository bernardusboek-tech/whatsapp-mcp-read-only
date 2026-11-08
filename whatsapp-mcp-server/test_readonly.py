import ast
import json
import os
import sqlite3
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path

import whatsapp


ROOT = Path(__file__).resolve().parent
FIXTURE = ROOT / "testdata" / "synthetic-messages.json"
MAIN = ROOT / "main.py"


def load_fixture():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))["chats"]


def write_db(directory: Path, rows: list) -> Path:
    directory.mkdir(mode=0o700, exist_ok=True)
    path = directory / "messages.db"
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE chats (
            jid TEXT PRIMARY KEY,
            name TEXT,
            last_message_time TIMESTAMP
        );
        CREATE TABLE messages (
            id TEXT,
            chat_jid TEXT,
            sender TEXT,
            content TEXT,
            timestamp TIMESTAMP,
            is_from_me BOOLEAN,
            media_type TEXT,
            filename TEXT,
            url TEXT,
            media_key BLOB,
            file_sha256 BLOB,
            file_enc_sha256 BLOB,
            file_length INTEGER
        );
        """
    )
    for row in rows:
        conn.execute(
            "INSERT INTO chats (jid, name, last_message_time) VALUES (?, ?, ?)",
            (row["jid"], row["name"], row["timestamp"]),
        )
        conn.execute(
            """INSERT INTO messages
            (id, chat_jid, sender, content, timestamp, is_from_me, media_type, filename)
            VALUES (?, ?, ?, ?, ?, 0, '', '')""",
            (row["message_id"], row["jid"], row["sender"], row["content"], row["timestamp"]),
        )
    conn.commit()
    conn.close()
    os.chmod(path, 0o600)
    return path


class ReadOnlyMCPTests(unittest.TestCase):
    def setUp(self):
        self._env = os.environ.copy()
        self._tmp = tempfile.TemporaryDirectory(prefix="wa-synthetic-")
        self.base = Path(self._tmp.name)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._env)
        self._tmp.cleanup()

    def use(self, directory: Path, db: Path):
        os.environ["WA_INSTANCE_DIR"] = str(directory)
        os.environ["WHATSAPP_DB_PATH"] = str(db)
        os.environ.pop("WA_REPO_ROOT", None)
        os.environ.pop("WA_DENY_DB_PATHS", None)

    def test_tool_surface_has_no_send_tools(self):
        tree = ast.parse(MAIN.read_text(encoding="utf-8"))
        names = []
        for node in tree.body:
            if not isinstance(node, ast.FunctionDef):
                continue
            for dec in node.decorator_list:
                func = dec.func if isinstance(dec, ast.Call) else dec
                if isinstance(func, ast.Attribute) and func.attr == "tool":
                    names.append(node.name)
        self.assertEqual(
            names,
            [
                "search_contacts",
                "list_messages",
                "list_chats",
                "get_chat",
                "get_direct_chat_by_contact",
                "get_contact_chats",
                "get_last_interaction",
                "get_message_context",
                "download_media",
            ],
        )
        source = (ROOT / "whatsapp.py").read_text(encoding="utf-8")
        for banned in ("/api/send", "send_message", "send_file", "send_audio_message", "requests.post"):
            self.assertNotIn(banned, source)

    def test_queries_are_isolated_and_read_only(self):
        rows = load_fixture()
        left = self.base / "left"
        right = self.base / "right"
        left_db = write_db(left, [rows[0]])
        right_db = write_db(right, [rows[1]])
        self.use(left, left_db)
        found = whatsapp.list_messages(include_context=False)
        self.assertIn("synthetic-fixture-alpha", found)
        self.assertNotIn("synthetic-fixture-beta", found)
        self.use(right, right_db)
        found = whatsapp.list_messages(include_context=False)
        self.assertIn("synthetic-fixture-beta", found)
        self.assertNotIn("synthetic-fixture-alpha", found)
        self.use(left, left_db)
        conn = whatsapp.connect_ro()
        with self.assertRaises(sqlite3.OperationalError):
            conn.execute(
                "INSERT INTO chats (jid, name, last_message_time) VALUES ('x', 'y', '2024-01-02T03:04:05')"
            )
        conn.close()

    def test_missing_or_denied_paths_fail_closed(self):
        os.environ["WA_INSTANCE_DIR"] = "relative/instance"
        os.environ["WHATSAPP_DB_PATH"] = "/tmp/messages.db"
        with self.assertRaises(whatsapp.ConfigError):
            whatsapp.require_messages_db()
        missing = self.base / "missing"
        missing.mkdir(mode=0o700)
        self.use(missing, missing / "messages.db")
        with self.assertRaises(sqlite3.OperationalError):
            whatsapp.connect_ro()
        rows = load_fixture()
        db = write_db(self.base / "real", [rows[0]])
        self.use(db.parent, db)
        os.environ["WA_DENY_DB_PATHS"] = str(db)
        with self.assertRaises(whatsapp.ConfigError):
            whatsapp.require_messages_db()
        os.environ.pop("WA_DENY_DB_PATHS")
        os.environ["WA_REPO_ROOT"] = str(self.base)
        with self.assertRaises(whatsapp.ConfigError):
            whatsapp.require_messages_db()

    def test_download_posts_only_to_local_socket(self):
        instance = self.base / "bridge"
        instance.mkdir(mode=0o700)
        token = "synthetic-token-not-a-credential"
        (instance / "bridge.token").write_text(token + "\n", encoding="utf-8")
        os.chmod(instance / "bridge.token", 0o600)
        sock_path = instance / "bridge.sock"
        seen = {}
        response_body = json.dumps(
            {
                "success": True,
                "message": "downloaded document",
                "filename": "a.bin",
                "path": str(instance / "media" / "a.bin"),
            }
        ).encode("utf-8")

        def serve_clean():
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(sock_path))
            listener.listen(1)
            conn, _ = listener.accept()
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            head, _, rest = data.partition(b"\r\n\r\n")
            length = 0
            for line in head.decode("utf-8", "replace").split("\r\n"):
                if line.lower().startswith("content-length:"):
                    length = int(line.split(":", 1)[1].strip())
            while len(rest) < length:
                rest += conn.recv(4096)
            seen["request"] = head + b"\r\n\r\n" + rest
            conn.sendall(
                b"HTTP/1.1 200 OK\r\nContent-Length: "
                + str(len(response_body)).encode("ascii")
                + b"\r\nConnection: close\r\n\r\n"
                + response_body
            )
            conn.close()
            listener.close()

        thread = threading.Thread(target=serve_clean)
        thread.start()
        for _ in range(50):
            if sock_path.exists():
                break
            time.sleep(0.01)
        self.use(instance, instance / "messages.db")
        # messages.db is not required for the socket call, but the path helper is not used there.
        try:
            path = whatsapp.download_media("synthetic-alpha-1", "15550001111@s.whatsapp.net")
        finally:
            thread.join(timeout=5)
        self.assertEqual(path, str(instance / "media" / "a.bin"))
        request = seen["request"]
        self.assertIn(b"POST /api/download HTTP/1.1", request)
        self.assertNotIn(b"/api/send", request)
        self.assertNotIn(b"synthetic-fixture-alpha", request)


if __name__ == "__main__":
    unittest.main()
