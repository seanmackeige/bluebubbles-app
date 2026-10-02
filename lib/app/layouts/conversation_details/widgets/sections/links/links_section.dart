import 'dart:async';
import 'dart:math';

import 'package:bluebubbles/app/layouts/conversation_details/attachment_section_type.dart';
import 'package:bluebubbles/app/layouts/conversation_details/conversation_attachments.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/attachment_section_header.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/sections/links/links_search_helper.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/search/conversation_search_field.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/interactive/url_preview.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/chat/logical_membership_refresh.dart';
import 'package:bluebubbles/services/ui/chat/logical_message_chronology.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

String? _linkMessageIdentity(Message message) {
  if (message.guid != null) return 'guid:${message.guid}';
  if (message.originalROWID != null) return 'row:${message.originalROWID}';
  if (message.id != null) return 'local:${message.id}';
  return null;
}

String? _linkSourceChatIdentity(Message message) {
  final chat = message.chat.target;
  if (chat?.guid != null) return 'guid:${chat!.guid}';
  if (chat?.id != null) return 'local:${chat!.id}';
  return null;
}

@visibleForTesting
List<Message> dedupeLinkMessagesByExactIdentity(Iterable<Message> messages) {
  final deduplicated = <Message>[];
  final seen = <String>{};
  for (final message in messages) {
    final identity = _linkMessageIdentity(message);
    final sourceChatIdentity = _linkSourceChatIdentity(message);
    if (identity == null || sourceChatIdentity == null || seen.add('$sourceChatIdentity\u0000$identity')) {
      deduplicated.add(message);
    }
  }
  return deduplicated;
}

@visibleForTesting
int compareLogicalLinkMessagesDescending(Message left, Message right) {
  final byMessage = compareLogicalMessagesDescending(left, right);
  if (byMessage != 0) return byMessage;
  return (_linkSourceChatIdentity(left) ?? '').compareTo(_linkSourceChatIdentity(right) ?? '');
}

/// Widget that handles links section display with loading state
class LinksSection extends StatefulWidget {
  final Chat chat;
  final bool fullPage;
  final MediaSenderFilter senderFilter;
  final DateTime? sinceDate;

  const LinksSection({
    super.key,
    required this.chat,
    this.fullPage = false,
    this.senderFilter = const MediaSenderFilter.any(),
    this.sinceDate,
  });

  @override
  State<LinksSection> createState() => _LinksSectionState();
}

class _LinksSectionState extends State<LinksSection> with ThemeHelpers {
  static const int _chunkSize = 20;
  late int _displayCount = widget.fullPage ? _chunkSize : kAttachmentPreviewLimit;
  List<Message> links = [];
  bool _isLoading = true;
  bool _loadingMore = false;
  String _searchQuery = '';
  StreamSubscription? _membershipSubscription;
  int _loadEpoch = 0;

  List<Message> get _filteredLinks {
    if (!widget.fullPage) return links;
    return applyMessageFilters(links, senderFilter: widget.senderFilter, sinceDate: widget.sinceDate);
  }

  List<Message> get _displayedLinks {
    final filtered = _filteredLinks;
    if (!widget.fullPage || _searchQuery.isEmpty) return filtered;
    return filterAndSortLinks(filtered, _searchQuery);
  }

  void _applySearchQuery(String query) {
    final nextQuery = query.trim();
    if (nextQuery == _searchQuery) return;
    setState(() {
      _searchQuery = nextQuery;
      _displayCount = widget.fullPage ? _chunkSize : kAttachmentPreviewLimit;
    });
  }

  @override
  void initState() {
    super.initState();
    _membershipSubscription = EventDispatcherSvc.stream.listen((event) {
      if (event.type != logicalMembershipAdvancedEvent ||
          !shouldRefreshLogicalMembershipProjection(
            eventData: event.data,
            currentLogicalId: ChatsSvc.logicalConversationIdFor(widget.chat),
          )) {
        return;
      }
      unawaited(_fetchLinks());
    });
    if (!kIsWeb) {
      unawaited(_fetchLinks());
    } else {
      _isLoading = false;
    }
  }

  @override
  void didUpdateWidget(LinksSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final conversationChanged = ChatsSvc.conversationKeyFor(oldWidget.chat) != ChatsSvc.conversationKeyFor(widget.chat);
    if (oldWidget.fullPage != widget.fullPage ||
        oldWidget.senderFilter != widget.senderFilter ||
        oldWidget.sinceDate != widget.sinceDate) {
      _displayCount = widget.fullPage ? _chunkSize : kAttachmentPreviewLimit;
    }
    if (!kIsWeb && conversationChanged) {
      unawaited(_fetchLinks());
    }
  }

  @override
  void dispose() {
    _membershipSubscription?.cancel();
    super.dispose();
  }

  Future<void> _fetchLinks() async {
    final loadEpoch = ++_loadEpoch;
    if (kIsWeb) {
      setState(() => _isLoading = false);
      return;
    }
    if (mounted) setState(() => _isLoading = true);

    final sourceChats = ChatsSvc.logicalSourceChatsFor(widget.chat);
    final sourceChatIds = sourceChats.map((chat) => chat.id).whereType<int>().toList(growable: false);
    if (sourceChatIds.isEmpty || sourceChatIds.length != sourceChats.length) {
      setState(() => _isLoading = false);
      return;
    }

    try {
      final query =
          (Database.messages.query(
                  Message_.dateDeleted.isNull() &
                      Message_.dbPayloadData.notNull() &
                      Message_.balloonBundleId.contains("URLBalloonProvider"),
                )
                ..link(Message_.chat, Chat_.id.oneOf(sourceChatIds))
                ..order(Message_.dateCreated, flags: Order.descending))
              .build();
      final fetchedLinks = await query.findAsync();
      query.close();

      if (mounted && loadEpoch == _loadEpoch) {
        setState(() {
          links = dedupeLinkMessagesByExactIdentity(fetchedLinks)..sort(compareLogicalLinkMessagesDescending);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted && loadEpoch == _loadEpoch) setState(() => _isLoading = false);
    }
  }

  int get _visibleCount {
    if (widget.fullPage) return min(_displayCount, _displayedLinks.length);
    return min(kAttachmentPreviewLimit, _displayedLinks.length);
  }

  void _loadMore() {
    if (_loadingMore || _displayCount >= _displayedLinks.length) return;
    _loadingMore = true;
    setState(() => _displayCount = min(_displayCount + _chunkSize, _displayedLinks.length));
    _loadingMore = false;
  }

  Widget _buildLinkTile(BuildContext context, int index) {
    if (_displayedLinks[index].payloadData?.urlData?.firstOrNull == null) {
      return const Text("Failed to load link!");
    }
    return Material(
      color: context.theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () async {
          final data = _displayedLinks[index].payloadData!.urlData!.first;
          if ((data.url ?? data.originalUrl) == null) return;
          await launchUrl(Uri.parse((data.url ?? data.originalUrl)!), mode: LaunchMode.externalApplication);
        },
        child: Center(child: UrlPreview(data: _displayedLinks[index].payloadData!.urlData!.first)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    return SliverMainAxisGroup(
      slivers: [
        if (!widget.fullPage)
          SliverToBoxAdapter(
            child: AttachmentSectionHeader(
              title: AttachmentSectionType.links.sectionLabel,
              onShowMore: () =>
                  ConversationAttachments.open(context, chat: widget.chat, section: AttachmentSectionType.links),
            ),
          ),
        if (widget.fullPage)
          SliverToBoxAdapter(
            child: Obx(() {
              final submitOnly = SettingsSvc.settings.highPerfMode.value;
              return ConversationSearchField(
                onChanged: submitOnly ? null : _applySearchQuery,
                onSubmitted: _applySearchQuery,
              );
            }),
          ),
        if (_isLoading)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 20.0),
              child: Center(child: buildProgressIndicator(context, size: 24)),
            ),
          )
        else if (_displayedLinks.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 20.0),
              child: Center(
                child: Text(
                  links.isEmpty ? "No links" : "No matching links",
                  style: context.theme.textTheme.bodyMedium!.copyWith(color: context.theme.colorScheme.outline),
                ),
              ),
            ),
          )
        else ...[
          Obx(
            () => SliverPadding(
              padding: attachmentSectionListPadding(
                fullPage: widget.fullPage,
                iOS: SettingsSvc.settings.skin.value == Skins.iOS,
                top: widget.fullPage ? 10 : 0,
              ),
              sliver: SliverToBoxAdapter(
                child: MasonryGridView.count(
                  crossAxisCount: max(2, NavigationSvc.width(context) ~/ 200),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemBuilder: (context, index) => _buildLinkTile(context, index),
                  itemCount: _visibleCount,
                ),
              ),
            ),
          ),
          if (widget.fullPage && _displayCount < _displayedLinks.length)
            SliverToBoxAdapter(
              child: Builder(
                builder: (context) {
                  if (!_loadingMore) {
                    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20.0),
                    child: Center(child: buildProgressIndicator(context, size: 24)),
                  );
                },
              ),
            ),
        ],
      ],
    );
  }
}
