import 'package:flutter/material.dart';
import '../core/message_store.dart';
import '../models/message.dart';

/// Reversed order keeps the same visible messages anchored when older pages
/// arrive; new items at the bottom are independent of history pagination.
class HistoryList extends StatefulWidget {
  final String chatId;
  final Widget Function(Message) itemBuilder;
  const HistoryList({
    super.key,
    required this.chatId,
    required this.itemBuilder,
  });
  @override
  State<HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<HistoryList> {
  late final Stream<List<Message>> _stream;
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    _stream = MessageStore.instance.watchMessages(widget.chatId);
  }

  Future<void> _older() async {
    if (_loading) return;
    setState(() => _loading = true);
    await MessageStore.instance.loadOlder(widget.chatId);
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<Message>>(
    stream: _stream,
    builder: (context, snapshot) {
      final messages = snapshot.data ?? [];
      return ListView.builder(
        reverse: true,
        itemCount: messages.length + 1,
        itemBuilder: (context, index) {
          if (index < messages.length) {
            final message = messages[messages.length - index - 1];
            return KeyedSubtree(
              key: ValueKey(message.id),
              child: widget.itemBuilder(message),
            );
          }
          final error = MessageStore.instance.historyError(widget.chatId);
          return Center(
            child: _loading
                ? const CircularProgressIndicator()
                : TextButton(
                    onPressed:
                        error != null ||
                            MessageStore.instance.hasMore(widget.chatId)
                        ? _older
                        : null,
                    child: Text(
                      error ??
                          (MessageStore.instance.hasMore(widget.chatId)
                              ? '加载更早消息'
                              : '没有更早消息'),
                    ),
                  ),
          );
        },
      );
    },
  );
}
