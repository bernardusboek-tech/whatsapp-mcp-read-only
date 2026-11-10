import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime
from dataclasses import asdict, dataclass, is_dataclass
from typing import Any, Dict, List, Optional
import os
import os.path
import json
import socket
import urllib.parse
from http.client import HTTPConnection

class ConfigError(RuntimeError):
    """Raised when instance paths are missing or point outside the instance."""

def require_messages_db() -> str:
    """Return the absolute read-only message database for this instance.

    There is no default path. A relative path, a path outside WA_INSTANCE_DIR,
    a repository path, or a denied path is rejected.
    """
    instance = os.environ.get("WA_INSTANCE_DIR", "").strip()
    db = os.environ.get("WHATSAPP_DB_PATH", "").strip()
    if not instance or not os.path.isabs(instance):
        raise ConfigError("WA_INSTANCE_DIR must be an absolute path")
    if not db or not os.path.isabs(db):
        raise ConfigError("WHATSAPP_DB_PATH must be an absolute path")
    instance_real = os.path.realpath(instance)
    db_real = os.path.realpath(db)
    expected = os.path.realpath(os.path.join(instance, "messages.db"))
    if db_real != expected:
        raise ConfigError("WHATSAPP_DB_PATH must be messages.db inside WA_INSTANCE_DIR")
    repo = os.environ.get("WA_REPO_ROOT", "").strip()
    if repo:
        repo_real = os.path.realpath(repo)
        if db_real == repo_real or db_real.startswith(repo_real + os.sep):
            raise ConfigError("database must be outside the repository")
    deny = os.environ.get("WA_DENY_DB_PATHS", "")
    for part in deny.split(os.pathsep):
        part = part.strip()
        if not part:
            continue
        if not os.path.isabs(part):
            raise ConfigError("WA_DENY_DB_PATHS entries must be absolute")
        denied = os.path.realpath(part) if os.path.exists(part) else os.path.abspath(part)
        if db_real == denied or db_real.startswith(denied + os.sep) or denied.startswith(db_real + os.sep):
            raise ConfigError("database path is denied")
    return db_real

@contextmanager
def connect_ro() -> Iterator[sqlite3.Connection]:
    path = require_messages_db()
    uri = "file:" + urllib.parse.quote(path) + "?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    try:
        yield conn
    finally:
        conn.close()

@dataclass
class Message:
    timestamp: datetime
    sender: str
    content: str
    is_from_me: bool
    chat_jid: str
    id: str
    chat_name: Optional[str] = None
    media_type: Optional[str] = None

@dataclass
class Chat:
    jid: str
    name: Optional[str]
    last_message_time: Optional[datetime]
    last_message: Optional[str] = None
    last_sender: Optional[str] = None
    last_is_from_me: Optional[bool] = None

    @property
    def is_group(self) -> bool:
        """Determine if chat is a group based on JID pattern."""
        return self.jid.endswith("@g.us")

@dataclass
class Contact:
    phone_number: str
    name: Optional[str]
    jid: str

@dataclass
class MessageContext:
    message: Message
    before: List[Message]
    after: List[Message]

def _json_ready(value: Any) -> Any:
    """Datetimes and dataclasses cannot cross the MCP JSON boundary."""
    if is_dataclass(value) and not isinstance(value, type):
        value = asdict(value)
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, list):
        return [_json_ready(item) for item in value]
    if isinstance(value, dict):
        return {key: _json_ready(item) for key, item in value.items()}
    return value

def _match_phone_or_jid(column: str, value: str) -> tuple[str, list[str]]:
    # Callers pass a bare number or a JID; rows store either form.
    phone = value.split("@", 1)[0]
    return f"({column} = ? OR {column} LIKE ?)", [value, f"%{phone}%"]

_CHAT_SELECT = """
    SELECT
        chats.jid,
        chats.name,
        chats.last_message_time,
        messages.content as last_message,
        messages.sender as last_sender,
        messages.is_from_me as last_is_from_me
    FROM chats
"""

_LAST_MESSAGE_JOIN = """
    LEFT JOIN messages ON chats.jid = messages.chat_jid
    AND chats.last_message_time = messages.timestamp
"""

def _query_chats(
    cursor: sqlite3.Cursor,
    where: str,
    params: List[Any],
    include_last_message: bool = True,
    order_by: str = "",
    limit: Optional[int] = None,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    parts = [_CHAT_SELECT]
    if include_last_message:
        parts.append(_LAST_MESSAGE_JOIN)
    if where:
        parts.append("WHERE " + where)
    if order_by:
        parts.append("ORDER BY " + order_by)
    query_params = list(params)
    if limit is not None:
        parts.append("LIMIT ? OFFSET ?")
        query_params.extend([limit, offset])
    cursor.execute(" ".join(parts), tuple(query_params))
    chats = []
    for row in cursor.fetchall():
        chats.append(Chat(
            jid=row[0],
            name=row[1],
            last_message_time=datetime.fromisoformat(row[2]) if row[2] else None,
            last_message=row[3],
            last_sender=row[4],
            last_is_from_me=row[5],
        ))
    return _json_ready(chats)

def list_messages(
    after: Optional[str] = None,
    before: Optional[str] = None,
    sender_phone_number: Optional[str] = None,
    chat_jid: Optional[str] = None,
    query: Optional[str] = None,
    limit: int = 20,
    page: int = 0,
    include_context: bool = True,
    context_before: int = 1,
    context_after: int = 1
) -> List[Dict[str, Any]]:
    """Get messages matching the specified criteria with optional context."""
    with connect_ro() as conn:
        cursor = conn.cursor()
        
        # Build base query
        query_parts = ["SELECT messages.timestamp, messages.sender, chats.name, messages.content, messages.is_from_me, chats.jid, messages.id, messages.media_type FROM messages"]
        query_parts.append("JOIN chats ON messages.chat_jid = chats.jid")
        where_clauses = []
        params = []
        
        # Add filters
        if after:
            try:
                after = datetime.fromisoformat(after)
            except ValueError:
                raise ValueError(f"Invalid date format for 'after': {after}. Please use ISO-8601 format.")
            
            where_clauses.append("messages.timestamp > ?")
            params.append(after)

        if before:
            try:
                before = datetime.fromisoformat(before)
            except ValueError:
                raise ValueError(f"Invalid date format for 'before': {before}. Please use ISO-8601 format.")
            
            where_clauses.append("messages.timestamp < ?")
            params.append(before)

        if sender_phone_number:
            clause, clause_params = _match_phone_or_jid("messages.sender", sender_phone_number)
            where_clauses.append(clause)
            params.extend(clause_params)
            
        if chat_jid:
            where_clauses.append("messages.chat_jid = ?")
            params.append(chat_jid)
            
        if query:
            where_clauses.append("LOWER(messages.content) LIKE LOWER(?)")
            params.append(f"%{query}%")
            
        if where_clauses:
            query_parts.append("WHERE " + " AND ".join(where_clauses))
            
        # Add pagination
        offset = page * limit
        query_parts.append("ORDER BY messages.timestamp DESC")
        query_parts.append("LIMIT ? OFFSET ?")
        params.extend([limit, offset])
        
        cursor.execute(" ".join(query_parts), tuple(params))
        messages = cursor.fetchall()
        
        result = []
        for msg in messages:
            message = Message(
                timestamp=datetime.fromisoformat(msg[0]),
                sender=msg[1],
                chat_name=msg[2],
                content=msg[3],
                is_from_me=msg[4],
                chat_jid=msg[5],
                id=msg[6],
                media_type=msg[7]
            )
            result.append(message)
            
        if include_context and result:
            messages_with_context = []
            for msg in result:
                context = get_message_context(msg.id, context_before, context_after)
                messages_with_context.extend(context["before"])
                messages_with_context.append(context["message"])
                messages_with_context.extend(context["after"])

            return messages_with_context

        return _json_ready(result)
        

def get_message_context(
    message_id: str,
    before: int = 5,
    after: int = 5
) -> Dict[str, Any]:
    """Get context around a specific message."""
    with connect_ro() as conn:
        cursor = conn.cursor()
        
        # Get the target message first
        cursor.execute("""
            SELECT messages.timestamp, messages.sender, chats.name, messages.content, messages.is_from_me, chats.jid, messages.id, messages.chat_jid, messages.media_type
            FROM messages
            JOIN chats ON messages.chat_jid = chats.jid
            WHERE messages.id = ?
        """, (message_id,))
        msg_data = cursor.fetchone()
        
        if not msg_data:
            raise ValueError(f"Message with ID {message_id} not found")
            
        target_message = Message(
            timestamp=datetime.fromisoformat(msg_data[0]),
            sender=msg_data[1],
            chat_name=msg_data[2],
            content=msg_data[3],
            is_from_me=msg_data[4],
            chat_jid=msg_data[5],
            id=msg_data[6],
            media_type=msg_data[8]
        )
        
        # Get messages before
        cursor.execute("""
            SELECT messages.timestamp, messages.sender, chats.name, messages.content, messages.is_from_me, chats.jid, messages.id, messages.media_type
            FROM messages
            JOIN chats ON messages.chat_jid = chats.jid
            WHERE messages.chat_jid = ? AND messages.timestamp < ?
            ORDER BY messages.timestamp DESC
            LIMIT ?
        """, (msg_data[7], msg_data[0], before))
        
        before_messages = []
        for msg in cursor.fetchall():
            before_messages.append(Message(
                timestamp=datetime.fromisoformat(msg[0]),
                sender=msg[1],
                chat_name=msg[2],
                content=msg[3],
                is_from_me=msg[4],
                chat_jid=msg[5],
                id=msg[6],
                media_type=msg[7]
            ))
        # DESC LIMIT keeps the nearest rows; context is read oldest-first.
        before_messages.reverse()

        # Get messages after
        cursor.execute("""
            SELECT messages.timestamp, messages.sender, chats.name, messages.content, messages.is_from_me, chats.jid, messages.id, messages.media_type
            FROM messages
            JOIN chats ON messages.chat_jid = chats.jid
            WHERE messages.chat_jid = ? AND messages.timestamp > ?
            ORDER BY messages.timestamp ASC
            LIMIT ?
        """, (msg_data[7], msg_data[0], after))
        
        after_messages = []
        for msg in cursor.fetchall():
            after_messages.append(Message(
                timestamp=datetime.fromisoformat(msg[0]),
                sender=msg[1],
                chat_name=msg[2],
                content=msg[3],
                is_from_me=msg[4],
                chat_jid=msg[5],
                id=msg[6],
                media_type=msg[7]
            ))
        
        return _json_ready(MessageContext(
            message=target_message,
            before=before_messages,
            after=after_messages
        ))
        

def list_chats(
    query: Optional[str] = None,
    limit: int = 20,
    page: int = 0,
    include_last_message: bool = True,
    sort_by: str = "last_active"
) -> List[Dict[str, Any]]:
    """Get chats matching the specified criteria."""
    where = ""
    params: List[Any] = []
    if query:
        clause, clause_params = _match_phone_or_jid("chats.jid", query)
        where = f"(LOWER(chats.name) LIKE LOWER(?) OR {clause})"
        params = [f"%{query}%", *clause_params]
    order_by = "chats.last_message_time DESC" if sort_by == "last_active" else "chats.name"
    with connect_ro() as conn:
        return _query_chats(
            conn.cursor(),
            where,
            params,
            include_last_message=include_last_message,
            order_by=order_by,
            limit=limit,
            offset=page * limit,
        )


def search_contacts(query: str) -> List[Dict[str, Any]]:
    """Search contacts by name or phone number."""
    clause, clause_params = _match_phone_or_jid("jid", query)
    with connect_ro() as conn:
        cursor = conn.cursor()
        cursor.execute(
            f"""
            SELECT DISTINCT
                jid,
                name
            FROM chats
            WHERE
                (LOWER(name) LIKE LOWER(?) OR {clause})
                AND jid NOT LIKE '%@g.us'
            ORDER BY name, jid
            LIMIT 50
            """,
            (f"%{query}%", *clause_params),
        )
        contacts = cursor.fetchall()

        result = []
        for contact_data in contacts:
            contact = Contact(
                phone_number=contact_data[0].split('@')[0],
                name=contact_data[1],
                jid=contact_data[0]
            )
            result.append(contact)

        return _json_ready(result)


def get_contact_chats(jid: str, limit: int = 20, page: int = 0) -> List[Dict[str, Any]]:
    """Get all chats involving the contact.

    Args:
        jid: The contact's JID to search for
        limit: Maximum number of chats to return (default 20)
        page: Page number for pagination (default 0)
    """
    chat_clause, chat_params = _match_phone_or_jid("chats.jid", jid)
    sender_clause, sender_params = _match_phone_or_jid("sender", jid)
    # Last-message join is one row; a contact may have spoken earlier than that.
    where = (
        f"{chat_clause} OR chats.jid IN "
        f"(SELECT chat_jid FROM messages WHERE {sender_clause})"
    )
    with connect_ro() as conn:
        return _query_chats(
            conn.cursor(),
            where,
            [*chat_params, *sender_params],
            order_by="chats.last_message_time DESC",
            limit=limit,
            offset=page * limit,
        )


def get_last_interaction(jid: str) -> Optional[Dict[str, Any]]:
    """Get most recent message involving the contact."""
    sender_clause, sender_params = _match_phone_or_jid("m.sender", jid)
    chat_clause, chat_params = _match_phone_or_jid("c.jid", jid)
    with connect_ro() as conn:
        cursor = conn.cursor()
        cursor.execute(
            f"""
            SELECT
                m.timestamp,
                m.sender,
                c.name,
                m.content,
                m.is_from_me,
                c.jid,
                m.id,
                m.media_type
            FROM messages m
            JOIN chats c ON m.chat_jid = c.jid
            WHERE {sender_clause} OR {chat_clause}
            ORDER BY m.timestamp DESC
            LIMIT 1
            """,
            (*sender_params, *chat_params),
        )
        msg_data = cursor.fetchone()

        if not msg_data:
            return None

        return _json_ready(Message(
            timestamp=datetime.fromisoformat(msg_data[0]),
            sender=msg_data[1],
            chat_name=msg_data[2],
            content=msg_data[3],
            is_from_me=msg_data[4],
            chat_jid=msg_data[5],
            id=msg_data[6],
            media_type=msg_data[7]
        ))


def get_chat(chat_jid: str, include_last_message: bool = True) -> Optional[Dict[str, Any]]:
    """Get chat metadata by JID."""
    with connect_ro() as conn:
        rows = _query_chats(
            conn.cursor(),
            "chats.jid = ?",
            [chat_jid],
            include_last_message=include_last_message,
            limit=1,
        )
    return rows[0] if rows else None


def get_direct_chat_by_contact(sender_phone_number: str) -> Optional[Dict[str, Any]]:
    """Get chat metadata by sender phone number."""
    clause, params = _match_phone_or_jid("chats.jid", sender_phone_number)
    with connect_ro() as conn:
        rows = _query_chats(
            conn.cursor(),
            f"{clause} AND chats.jid NOT LIKE '%@g.us'",
            params,
            limit=1,
        )
    return rows[0] if rows else None


class _UnixHTTPConnection(HTTPConnection):
    """HTTP over a Unix socket. This process does not open a TCP connection."""

    def __init__(self, socket_path: str):
        super().__init__("localhost")
        self.socket_path = socket_path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(self.socket_path)
        self.sock = sock

def _bridge_auth() -> tuple:
    instance = os.environ.get("WA_INSTANCE_DIR", "").strip()
    if not instance or not os.path.isabs(instance):
        raise ConfigError("WA_INSTANCE_DIR must be an absolute path")
    instance_real = os.path.realpath(instance)
    sock = os.path.join(instance_real, "bridge.sock")
    token_path = os.path.join(instance_real, "bridge.token")
    if os.path.islink(sock):
        raise ConfigError("bridge socket must not be a symlink")
    if os.path.dirname(os.path.realpath(sock) if os.path.exists(sock) else sock) != instance_real:
        raise ConfigError("bridge socket must stay inside the instance directory")
    with open(token_path, "r", encoding="utf-8") as handle:
        token = handle.read().strip()
    if not token:
        raise ConfigError("bridge token is empty")
    return sock, token

def download_media(message_id: str, chat_jid: str) -> Optional[str]:
    """Ask the local bridge to download media and return the file path.

    The request goes to the instance Unix socket only. There is no TCP client
    and no send route.
    """
    try:
        sock, token = _bridge_auth()
        payload = json.dumps({"message_id": message_id, "chat_jid": chat_jid}).encode("utf-8")
        conn = _UnixHTTPConnection(sock)
        conn.request(
            "POST",
            "/api/download",
            body=payload,
            headers={
                "Content-Type": "application/json",
                "Content-Length": str(len(payload)),
                "Authorization": f"Bearer {token}",
            },
        )
        response = conn.getresponse()
        raw = response.read()
        if response.status != 200:
            return None
        result = json.loads(raw.decode("utf-8"))
        if result.get("success"):
            return result.get("path")
        return None
    except ConfigError:
        raise
    except (OSError, json.JSONDecodeError):
        return None
