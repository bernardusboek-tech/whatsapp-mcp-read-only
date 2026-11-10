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
            where_clauses.append("messages.sender = ?")
            params.append(sender_phone_number)
            
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
    with connect_ro() as conn:
        cursor = conn.cursor()
        
        # Build base query
        query_parts = ["""
            SELECT 
                chats.jid,
                chats.name,
                chats.last_message_time,
                messages.content as last_message,
                messages.sender as last_sender,
                messages.is_from_me as last_is_from_me
            FROM chats
        """]
        
        if include_last_message:
            query_parts.append("""
                LEFT JOIN messages ON chats.jid = messages.chat_jid 
                AND chats.last_message_time = messages.timestamp
            """)
            
        where_clauses = []
        params = []
        
        if query:
            where_clauses.append("(LOWER(chats.name) LIKE LOWER(?) OR chats.jid LIKE ?)")
            params.extend([f"%{query}%", f"%{query}%"])
            
        if where_clauses:
            query_parts.append("WHERE " + " AND ".join(where_clauses))
            
        # Add sorting
        order_by = "chats.last_message_time DESC" if sort_by == "last_active" else "chats.name"
        query_parts.append(f"ORDER BY {order_by}")
        
        # Add pagination
        offset = (page ) * limit
        query_parts.append("LIMIT ? OFFSET ?")
        params.extend([limit, offset])
        
        cursor.execute(" ".join(query_parts), tuple(params))
        chats = cursor.fetchall()
        
        result = []
        for chat_data in chats:
            chat = Chat(
                jid=chat_data[0],
                name=chat_data[1],
                last_message_time=datetime.fromisoformat(chat_data[2]) if chat_data[2] else None,
                last_message=chat_data[3],
                last_sender=chat_data[4],
                last_is_from_me=chat_data[5]
            )
            result.append(chat)

        return _json_ready(result)


def search_contacts(query: str) -> List[Dict[str, Any]]:
    """Search contacts by name or phone number."""
    with connect_ro() as conn:
        cursor = conn.cursor()
        
        # Split query into characters to support partial matching
        search_pattern = '%' +query + '%'
        
        cursor.execute("""
            SELECT DISTINCT 
                jid,
                name
            FROM chats
            WHERE 
                (LOWER(name) LIKE LOWER(?) OR LOWER(jid) LIKE LOWER(?))
                AND jid NOT LIKE '%@g.us'
            ORDER BY name, jid
            LIMIT 50
        """, (search_pattern, search_pattern))
        
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
    with connect_ro() as conn:
        cursor = conn.cursor()
        
        cursor.execute("""
            SELECT DISTINCT
                c.jid,
                c.name,
                c.last_message_time,
                m.content as last_message,
                m.sender as last_sender,
                m.is_from_me as last_is_from_me
            FROM chats c
            JOIN messages m ON c.jid = m.chat_jid
            WHERE m.sender = ? OR c.jid = ?
            ORDER BY c.last_message_time DESC
            LIMIT ? OFFSET ?
        """, (jid, jid, limit, page * limit))
        
        chats = cursor.fetchall()
        
        result = []
        for chat_data in chats:
            chat = Chat(
                jid=chat_data[0],
                name=chat_data[1],
                last_message_time=datetime.fromisoformat(chat_data[2]) if chat_data[2] else None,
                last_message=chat_data[3],
                last_sender=chat_data[4],
                last_is_from_me=chat_data[5]
            )
            result.append(chat)

        return _json_ready(result)


def get_last_interaction(jid: str) -> Optional[Dict[str, Any]]:
    """Get most recent message involving the contact."""
    with connect_ro() as conn:
        cursor = conn.cursor()
        
        cursor.execute("""
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
            WHERE m.sender = ? OR c.jid = ?
            ORDER BY m.timestamp DESC
            LIMIT 1
        """, (jid, jid))
        
        msg_data = cursor.fetchone()
        
        if not msg_data:
            return None
            
        message = Message(
            timestamp=datetime.fromisoformat(msg_data[0]),
            sender=msg_data[1],
            chat_name=msg_data[2],
            content=msg_data[3],
            is_from_me=msg_data[4],
            chat_jid=msg_data[5],
            id=msg_data[6],
            media_type=msg_data[7]
        )
        
        return _json_ready(message)
        

def get_chat(chat_jid: str, include_last_message: bool = True) -> Optional[Dict[str, Any]]:
    """Get chat metadata by JID."""
    with connect_ro() as conn:
        cursor = conn.cursor()
        
        query = """
            SELECT 
                c.jid,
                c.name,
                c.last_message_time,
                m.content as last_message,
                m.sender as last_sender,
                m.is_from_me as last_is_from_me
            FROM chats c
        """
        
        if include_last_message:
            query += """
                LEFT JOIN messages m ON c.jid = m.chat_jid 
                AND c.last_message_time = m.timestamp
            """
            
        query += " WHERE c.jid = ?"
        
        cursor.execute(query, (chat_jid,))
        chat_data = cursor.fetchone()
        
        if not chat_data:
            return None
            
        return _json_ready(Chat(
            jid=chat_data[0],
            name=chat_data[1],
            last_message_time=datetime.fromisoformat(chat_data[2]) if chat_data[2] else None,
            last_message=chat_data[3],
            last_sender=chat_data[4],
            last_is_from_me=chat_data[5]
        ))


def get_direct_chat_by_contact(sender_phone_number: str) -> Optional[Dict[str, Any]]:
    """Get chat metadata by sender phone number."""
    with connect_ro() as conn:
        cursor = conn.cursor()
        
        cursor.execute("""
            SELECT 
                c.jid,
                c.name,
                c.last_message_time,
                m.content as last_message,
                m.sender as last_sender,
                m.is_from_me as last_is_from_me
            FROM chats c
            LEFT JOIN messages m ON c.jid = m.chat_jid 
                AND c.last_message_time = m.timestamp
            WHERE c.jid LIKE ? AND c.jid NOT LIKE '%@g.us'
            LIMIT 1
        """, (f"%{sender_phone_number}%",))
        
        chat_data = cursor.fetchone()
        
        if not chat_data:
            return None
            
        return _json_ready(Chat(
            jid=chat_data[0],
            name=chat_data[1],
            last_message_time=datetime.fromisoformat(chat_data[2]) if chat_data[2] else None,
            last_message=chat_data[3],
            last_sender=chat_data[4],
            last_is_from_me=chat_data[5]
        ))
        

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
