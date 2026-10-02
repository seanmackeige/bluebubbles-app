# services/backend/notifications/ — Local Notifications

`notifications_service.dart` — dispatches local notifications across all platforms.

## Notification Channels
| Channel | Purpose |
|---------|---------|
| `NEW_MESSAGE` | Incoming message notification |
| `ERROR` | App error alerts |
| `REMINDER` | Scheduled message reminders |
| `FACETIME` | Incoming FaceTime call alert |
| `FOREGROUND_SERVICE` | Android persistent foreground service notification |

## Platform Implementations
| Platform | Library |
|----------|---------|
| Android / iOS | `flutter_local_notifications` |
| Desktop (Windows, Linux) | `flutter_local_notifications` via the `DesktopNotifications` adapter (`desktop_notification.dart`) |
| Web | Browser Notification API |

## Key Behaviors
- Message preview display (text, sender name, avatar)
- Group notifications (grouped by chat on Android)
- Toast management via `PendingToastItem`
- FaceTime incoming call with accept/decline actions

## Triggering Notifications
Called from `IncomingMessageHandler` when a new message arrives, and from `ScheduledMessage` reminders.
Don't call directly from UI code — route through the handler/service layer.

## Logical Conversation Identity

- `conversation_key` is the stable notification/group/shortcut identity. Derive it from
  `ChatsSvc.conversationKeyFor(presentationChat)`. Derive the positive Android ID from
  `LogicalNotificationIdentity.fromLogicalId(ChatsSvc.conversationIdentityFor(presentationChat))`.
- `chat_guid` remains a compatible physical navigation route; `source_chat_guid` records
  the physical source that produced the notification; `message_guid` remains exact.
- Legacy Android/desktop payloads omit the logical key and must default to `chat_guid`.
- Evaluate mute state on the current presentation chat, never only on an incoming member.
- Desktop reply and mark-read actions resolve the current presentation chat and use the
  existing logical mutation admission. Never report an unqualified logical read as success.
