# WhatsApp MCP Server

This is a Model Context Protocol (MCP) server for WhatsApp.

This candidate reads chats, contacts, and media metadata from a local store and can ask a local bridge to download media that is already in that store. It has no send, reply, react, or mark-read tool, and the bridge does not expose a send endpoint.

Connecting a real account is a separate step and is not part of the automated tests. If you later connect, WhatsApp can still deliver existing chats, contacts, and settings into the instance directory. This program does not offer a new-messages-only mode. The pinned library can also send protocol acknowledgements during a real connection. Those are not user messages. This program does not call mark-as-read or available presence. Automated tests do not open a WhatsApp connection, so they do not prove how a live server renders those acknowledgements.

A future connection uses the WhatsApp web multidevice API through the pinned [whatsmeow](https://github.com/tulir/whatsmeow) library. Message rows stay in the instance directory. The MCP server returns them only when a client calls a tool.

## Installation

### Prerequisites

- Go
- Python 3.11+
- Anthropic Claude Desktop app (or Cursor)
- UV (Python package manager), install with `curl -LsSf https://astral.sh/uv/install.sh | sh`

### Steps

1. **Clone this repository**

   ```bash
   git clone <this-repository>
   cd <repository>
   ```

2. **Choose an instance directory outside this repository**

   The bridge and the MCP server refuse relative paths and refuse to store data inside the repository. Set `WA_DENY_INSTANCE_DIRS` to any existing installation that must not be opened. Do not put that path in git.

   ```bash
   export WA_INSTANCE_DIR=/absolute/path/outside/this/repo
   export WA_DENY_INSTANCE_DIRS=/absolute/path/of/an/existing/installation
   scripts/start-bridge.sh "$WA_INSTANCE_DIR"
   ```

   Without `WA_PAIR=1`, a directory that has no saved session exits before connecting. Pairing writes a secret payload to `$WA_INSTANCE_DIR/pairing.payload` and does not print it. Do not commit that file, the session database, or message rows. The tests in this repository never set `WA_PAIR` and never connect to WhatsApp.

3. **Connect to the MCP server**

   Copy the below json with the appropriate {{PATH}} values:

   ```json
   {
     "mcpServers": {
       "whatsapp": {
         "command": "{{PATH_TO_UV}}",
         "args": [
           "--directory",
           "/absolute/path/to/whatsapp-mcp-server",
           "run",
           "main.py"
         ],
         "env": {
           "WA_INSTANCE_DIR": "/absolute/path/outside/this/repo",
           "WHATSAPP_DB_PATH": "/absolute/path/outside/this/repo/messages.db"
         }
       }
     }
   }
   ```

   `WHATSAPP_DB_PATH` must be exactly `$WA_INSTANCE_DIR/messages.db`. The MCP process opens it with SQLite `mode=ro`. Media download uses the Unix socket and token file inside that directory. There is no TCP port.

   For **Claude**, save this as `claude_desktop_config.json` in your Claude Desktop configuration directory at:

   ```
   ~/Library/Application Support/Claude/claude_desktop_config.json
   ```

   For **Cursor**, save this as `mcp.json` in your Cursor configuration directory at:

   ```
   ~/.cursor/mcp.json
   ```

4. **Restart Claude Desktop / Cursor**

   Open Claude Desktop and you should now see WhatsApp as an available integration.

   Or restart Cursor.

### Windows Compatibility

If you're running this project on Windows, be aware that `go-sqlite3` requires **CGO to be enabled** in order to compile and work properly. By default, **CGO is disabled on Windows**, so you need to explicitly enable it and have a C compiler installed.

#### Steps to get it working:

1. **Install a C compiler**  
   We recommend using [MSYS2](https://www.msys2.org/) to install a C compiler for Windows. After installing MSYS2, make sure to add the `ucrt64\bin` folder to your `PATH`.  
   → A step-by-step guide is available [here](https://code.visualstudio.com/docs/cpp/config-mingw).

2. **Enable CGO and run the app**

   ```bash
   cd whatsapp-bridge
   go env -w CGO_ENABLED=1
   ```

   Start with `scripts/start-bridge.sh` and an absolute `WA_INSTANCE_DIR`, as above. `go run main.go` without that variable exits before connecting.

Without this setup, you'll likely run into errors like:

> `Binary was compiled with 'CGO_ENABLED=0', go-sqlite3 requires cgo to work.`

## Architecture Overview

This application consists of two main components:

1. **Go WhatsApp Bridge** (`whatsapp-bridge/`): Keeps one instance's session and message rows under `WA_INSTANCE_DIR` and serves media download on a Unix socket in that directory. It does not listen on TCP.

2. **Python MCP Server** (`whatsapp-mcp-server/`): A Python server implementing the Model Context Protocol (MCP), which provides standardized tools for Claude to read WhatsApp data.

### Data Storage

- `messages.db` in the instance directory stores chats and message rows, including history WhatsApp delivers after a future connection
- `session.db` in the same directory stores the linked-device session
- Media bytes are written under `media/` only after a download request, with filenames reduced to a single path segment

## Usage

Once connected, you can interact with your WhatsApp contacts through Claude, leveraging Claude's AI capabilities in your WhatsApp conversations.

### MCP Tools

Claude can access the following tools to interact with WhatsApp:

- **search_contacts**: Search for contacts by name or phone number
- **list_messages**: Retrieve messages with optional filters and context
- **list_chats**: List available chats with metadata
- **get_chat**: Get information about a specific chat
- **get_direct_chat_by_contact**: Find a direct chat with a specific contact
- **get_contact_chats**: List all chats involving a specific contact
- **get_last_interaction**: Get the most recent message with a contact
- **get_message_context**: Retrieve context around a specific message
- **download_media**: Download media from a WhatsApp message and get the local file path

### Media Handling Features

The MCP server supports downloading media files from your chats:

#### Media Downloading

By default, just the metadata of the media is stored in the local database. The message will indicate that media was sent. To access this media you need to use the download_media tool which takes the `message_id` and `chat_jid` (which are shown when printing messages containing the meda), this downloads the media and then returns the file path which can be then opened or passed to another tool.

## Technical Details

1. Claude sends requests to the Python MCP server
2. The MCP server queries the Go bridge for WhatsApp data or directly to the SQLite database
3. The Go accesses the WhatsApp API and keeps the SQLite database up to date
4. Data flows back through the chain to Claude

## Troubleshooting

- If you encounter permission issues when running uv, you may need to add it to your PATH or use the full path to the executable.
- Make sure both the Go application and the Python server are running for the integration to work properly.

### Authentication Issues

- **QR Code Not Displaying**: If the QR code doesn't appear, try restarting the authentication script. If issues persist, check if your terminal supports displaying QR codes.
- **WhatsApp Already Logged In**: If your session is already active, the Go bridge will automatically reconnect without showing a QR code.
- **Device Limit Reached**: WhatsApp limits the number of linked devices. If you reach this limit, you'll need to remove an existing device from WhatsApp on your phone (Settings > Linked Devices).
- **No Messages Loading**: After initial authentication, it can take several minutes for your message history to load, especially if you have many chats.
- **WhatsApp Out of Sync**: Deleting `session.db` and `messages.db` inside one instance directory drops that instance's local session and stored rows. Do that only for the instance you intend to reset. Stopping the process disconnects it; it does not unlink the phone. Unlinking is done from the phone's linked devices.

For additional Claude Desktop integration troubleshooting, see the [MCP documentation](https://modelcontextprotocol.io/quickstart/server#claude-for-desktop-integration-issues). The documentation includes helpful tips for checking logs and resolving common issues.
