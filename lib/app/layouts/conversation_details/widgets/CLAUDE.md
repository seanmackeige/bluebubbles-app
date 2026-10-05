# conversation_details/widgets/ — Detail Panel Sub-Widgets

Reusable widgets composing the conversation details / info panel.

## Root widgets

| File | Purpose |
|------|---------|
| `chat_info.dart` | Top section: avatar/name/count; logical read-only mode suppresses edit controls |
| `chat_options.dart` | Action row: mute, pin, archive, block, delete |
| `logical_conversation_health_card.dart` | Collapsed read-only diagnostics projected from the central logical application snapshot; no provider coordinates, PII, or actions |
| `contact_tile.dart` | Single participant row (avatar, name, address, remove button) |
| `participants_list.dart` | Group members; logical read-only mode suppresses add/remove controls |
| `attachment_section_header.dart` | Section label + "Show more" for attachment previews |
| `attachments_loader.dart` | Aggregates exact-identity attachments across every certified logical source |
| `media_gallery_card.dart` | Tappable thumbnail card for media or file items |

## `filters/`

| File | Purpose |
|------|---------|
| `media_filters_sheet.dart` | Shared attachment filters bottom sheet + app bar tune button |

## `sections/`

| Path | Purpose |
|------|---------|
| `media/media_grid_section.dart` | Photo/video grid (preview + full page) |
| `media/media_filter_selector.dart` | Inline All/Images/Videos segmented control |
| `links/links_section.dart` | Shared URL link previews |
| `links/links_search_helper.dart` | Link search scoring and sort |
| `documents/documents_section.dart` | Shared files/documents grid |
| `documents/documents_search_helper.dart` | File search scoring and sort |
| `locations/locations_section.dart` | Shared location message cards |

## Related
- Parent panel: `../CLAUDE.md` (conversation_details)
- Dialogs (add participant, leave chat, etc.): `../dialogs/CLAUDE.md`
- Contact avatar: `lib/app/components/avatars/CLAUDE.md`

Explicit health-card expansion may run the bounded LOCAL admission snapshot/policy
probe. It reads existing preferences/authority only; no provider refresh, draft
write, reservation, queue or transport. Optional supplied test snapshots skip it.
No work is scheduled from build or projection, preserving the Build108 ANR fix.
