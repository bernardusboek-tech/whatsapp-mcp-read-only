package main

import (
	"fmt"
	"strings"
	"time"

	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	waHist "go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

func extractTextContent(msg *waE2E.Message) string {
	if msg == nil {
		return ""
	}
	if text := msg.GetConversation(); text != "" {
		return text
	}
	if text := msg.GetExtendedTextMessage().GetText(); text != "" {
		return text
	}
	if text := msg.GetImageMessage().GetCaption(); text != "" {
		return text
	}
	if text := msg.GetVideoMessage().GetCaption(); text != "" {
		return text
	}
	if text := msg.GetDocumentMessage().GetCaption(); text != "" {
		return text
	}
	return ""
}

func extractMediaInfo(msg *waE2E.Message, messageID string) (mediaType, filename, url string, mediaKey, fileSHA256, fileEncSHA256 []byte, fileLength uint64) {
	if msg == nil {
		return "", "", "", nil, nil, nil, 0
	}
	if img := msg.GetImageMessage(); img != nil {
		return "image", "image_" + messageID + ".jpg", img.GetURL(), img.GetMediaKey(), img.GetFileSHA256(), img.GetFileEncSHA256(), img.GetFileLength()
	}
	if vid := msg.GetVideoMessage(); vid != nil {
		return "video", "video_" + messageID + ".mp4", vid.GetURL(), vid.GetMediaKey(), vid.GetFileSHA256(), vid.GetFileEncSHA256(), vid.GetFileLength()
	}
	if aud := msg.GetAudioMessage(); aud != nil {
		return "audio", "audio_" + messageID + ".ogg", aud.GetURL(), aud.GetMediaKey(), aud.GetFileSHA256(), aud.GetFileEncSHA256(), aud.GetFileLength()
	}
	if doc := msg.GetDocumentMessage(); doc != nil {
		name := doc.GetFileName()
		if name == "" {
			name = "document_" + messageID
		}
		return "document", name, doc.GetURL(), doc.GetMediaKey(), doc.GetFileSHA256(), doc.GetFileEncSHA256(), doc.GetFileLength()
	}
	return "", "", "", nil, nil, nil, 0
}

func chatName(client BridgeClient, store *MessageStore, jid types.JID, chatJID string, conversation *waHist.Conversation, sender string) string {
	var existingName string
	err := store.db.QueryRow("SELECT name FROM chats WHERE jid = ?", chatJID).Scan(&existingName)
	if err == nil && existingName != "" {
		return existingName
	}
	var name string
	if jid.Server == "g.us" {
		if conversation != nil {
			name = conversation.GetDisplayName()
			if name == "" {
				name = conversation.GetName()
			}
		}
		if name == "" && client != nil {
			if group, err := client.GroupName(jid); err == nil && group != "" {
				name = group
			}
		}
		if name == "" {
			name = fmt.Sprintf("Group %s", jid.User)
		}
	} else {
		if client != nil {
			name = client.ContactName(jid)
		}
		if name == "" && sender != "" {
			name = sender
		}
		if name == "" {
			name = jid.User
		}
	}
	return name
}

func handleMessage(client BridgeClient, store *MessageStore, msg *events.Message, _ Logger) error {
	if msg == nil {
		return nil
	}
	chatJID := msg.Info.Chat.String()
	sender := msg.Info.Sender.User
	name := chatName(client, store, msg.Info.Chat, chatJID, nil, sender)
	if err := store.StoreChat(chatJID, name, msg.Info.Timestamp); err != nil {
		return err
	}
	content := extractTextContent(msg.Message)
	mediaType, filename, url, mediaKey, fileSHA256, fileEncSHA256, fileLength := extractMediaInfo(msg.Message, msg.Info.ID)
	if content == "" && mediaType == "" {
		return nil
	}
	return store.StoreMessage(msg.Info.ID, chatJID, sender, content, msg.Info.Timestamp, msg.Info.IsFromMe, mediaType, filename, url, mediaKey, fileSHA256, fileEncSHA256, fileLength)
}

func handleHistorySync(client BridgeClient, store *MessageStore, historySync *events.HistorySync, _ Logger) (int, error) {
	if historySync == nil || historySync.Data == nil {
		return 0, nil
	}
	synced := 0
	for _, conversation := range historySync.Data.Conversations {
		if conversation.ID == nil {
			continue
		}
		chatJID := *conversation.ID
		jid, err := types.ParseJID(chatJID)
		if err != nil {
			continue
		}
		name := chatName(client, store, jid, chatJID, conversation, "")
		var chatAt time.Time
		for _, msg := range conversation.Messages {
			if msg == nil || msg.Message == nil {
				continue
			}
			if ts := msg.Message.GetMessageTimestamp(); ts != 0 {
				chatAt = time.Unix(int64(ts), 0)
				break
			}
		}
		if !chatAt.IsZero() {
			if err := store.StoreChat(chatJID, name, chatAt); err != nil {
				return synced, err
			}
		}
		for _, msg := range conversation.Messages {
			if msg == nil || msg.Message == nil {
				continue
			}
			msgID := ""
			if msg.Message.Key != nil && msg.Message.Key.ID != nil {
				msgID = *msg.Message.Key.ID
			}
			var content string
			var mediaType, filename, url string
			var mediaKey, fileSHA256, fileEncSHA256 []byte
			var fileLength uint64
			if msg.Message.Message != nil {
				content = extractTextContent(msg.Message.Message)
				mediaType, filename, url, mediaKey, fileSHA256, fileEncSHA256, fileLength = extractMediaInfo(msg.Message.Message, msgID)
			}
			if content == "" && mediaType == "" {
				continue
			}
			var sender string
			isFromMe := false
			if msg.Message.Key != nil {
				if msg.Message.Key.FromMe != nil {
					isFromMe = *msg.Message.Key.FromMe
				}
				if !isFromMe && msg.Message.Key.Participant != nil && *msg.Message.Key.Participant != "" {
					sender = *msg.Message.Key.Participant
				} else if isFromMe && client != nil {
					sender = client.OwnUser()
				} else {
					sender = jid.User
				}
			} else {
				sender = jid.User
			}
			ts := msg.Message.GetMessageTimestamp()
			if ts == 0 {
				continue
			}
			if err := store.StoreMessage(msgID, chatJID, sender, content, time.Unix(int64(ts), 0), isFromMe, mediaType, filename, url, mediaKey, fileSHA256, fileEncSHA256, fileLength); err != nil {
				return synced, err
			}
			synced++
		}
	}
	return synced, nil
}

func extractDirectPathFromURL(rawURL string) string {
	parts := strings.SplitN(rawURL, ".net/", 2)
	if len(parts) < 2 {
		return rawURL
	}
	pathPart := strings.SplitN(parts[1], "?", 2)[0]
	return "/" + pathPart
}
