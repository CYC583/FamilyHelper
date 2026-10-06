// Copyright (c) 2026 cyc. FamilyHelper License — see LICENSE.
import 'dart:async';

import 'package:flutter/material.dart';

import 'firebase_service.dart';
import 'native_bridge.dart';
import 'ui/fh_tokens.dart';

const photoQuickPhrases = ['好漂亮！', '今天也想你', '這是在哪裡拍的？'];

/// Hearts and short comments on one shared photo. Readable only while photo
/// sharing is on; the server re-checks that the photo is still visible.
///
/// Each family member has one heart and one short comment per photo; sending
/// again replaces their comment, so this is "留一句話／修改留言", not a chat.
class PhotoReactions extends StatefulWidget {
  final FirebaseService api;
  final String hostId;
  final String mediaId;
  final Map<String, String> names;
  final bool large;

  /// Grandma never types: her side shows who sent hearts and the comments,
  /// with a button that reads the comments aloud.
  final bool allowComment;
  final Stream<Map<String, dynamic>>? reactions;
  final Future<void> Function(String text)? speak;
  const PhotoReactions({
    super.key,
    required this.api,
    required this.hostId,
    required this.mediaId,
    this.names = const {},
    this.large = false,
    this.allowComment = true,
    this.reactions,
    this.speak,
  });

  @override
  State<PhotoReactions> createState() => _PhotoReactionsState();
}

class _PhotoReactionsState extends State<PhotoReactions> {
  final _comment = TextEditingController();
  Stream<Map<String, dynamic>>? _stream;
  bool _busy = false, _composing = false;
  String? _status;
  bool _statusError = false;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant PhotoReactions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaId != widget.mediaId) {
      _comment.clear();
      _status = null;
      _composing = false;
      _bind();
    }
  }

  void _bind() {
    try {
      _stream =
          widget.reactions ??
          widget.api.watch(
            'care/${widget.hostId}/photoReactions/${widget.mediaId}',
          );
    } catch (_) {
      _stream = null;
    }
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  String _name(String uid) => uid == widget.hostId
      ? '長輩'
      : uid == widget.api.uid && widget.allowComment
      ? '我'
      : widget.names[uid] ?? '家人';

  Future<void> _save({required bool heart, String? comment}) async {
    final text = (comment ?? '').trim();
    if (text.length > 60) {
      setState(() {
        _status = '留言最多 60 字';
        _statusError = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在送出…';
      _statusError = false;
    });
    try {
      await widget.api.call('reactToPhoto', {
        'hostId': widget.hostId,
        'mediaId': widget.mediaId,
        'heart': heart,
        'comment': text,
      });
      if (!mounted) return;
      setState(() {
        _status = '已送出';
        _composing = false;
      });
      _comment.clear();
    } catch (e) {
      // Keep the typed words so the person can simply press send again.
      if (mounted) {
        setState(() {
          _status = '沒有送出，請再按一次：${errorMessage(e)}';
          _statusError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _readAloud(List<MapEntry<String, Map<String, dynamic>>> items) {
    final line = items
        .map((e) => '${_name(e.key)}說：${e.value['comment']}')
        .join('。');
    return (widget.speak ?? NativeBridge.speakText)(line).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.large ? 20.0 : 16.0;
    if (_stream == null) return const SizedBox.shrink();
    return StreamBuilder<Map<String, dynamic>>(
      stream: _stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text('照片互動暫時無法讀取', style: TextStyle(fontSize: size));
        }
        final all = (snapshot.data ?? const {}).map(
          (k, v) => MapEntry(k, asMap(v)),
        );
        final mine = all[widget.api.uid] ?? const {};
        final heartNames = [
          for (final e in all.entries)
            if (e.value['heart'] == true) _name(e.key),
        ];
        final comments = all.entries
            .where((e) => (e.value['comment'] as String? ?? '').isNotEmpty)
            .toList();
        final liked = mine['heart'] == true;
        final myComment = mine['comment'] as String? ?? '';
        final heartLine = heartNames.isEmpty
            ? (widget.allowComment ? '還沒有人送愛心' : '家人的愛心會出現在這裡')
            : '${heartNames.join('、')}送來了愛心 ♥';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.allowComment) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    key: Key('photo-heart-${widget.mediaId}'),
                    onPressed: _busy
                        ? null
                        : () => _save(heart: !liked, comment: myComment),
                    icon: Icon(
                      liked ? Icons.favorite : Icons.favorite_border,
                      color: FhColors.danger,
                    ),
                    label: Text(liked ? '已送愛心（再按收回）' : '送愛心'),
                  ),
                  OutlinedButton.icon(
                    key: Key('photo-compose-${widget.mediaId}'),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _composing = !_composing;
                            if (_composing && _comment.text.isEmpty) {
                              _comment.text = myComment;
                            }
                          }),
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(myComment.isEmpty ? '留一句話' : '修改留言'),
                  ),
                ],
              ),
              if (_composing) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final p in photoQuickPhrases)
                      ActionChip(
                        label: Text(p),
                        onPressed: () => setState(() => _comment.text = p),
                      ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: Key('photo-comment-${widget.mediaId}'),
                        controller: _comment,
                        maxLength: 60,
                        style: TextStyle(fontSize: size),
                        decoration: const InputDecoration(
                          labelText: '想對長輩說的一句話',
                          counterText: '',
                        ),
                      ),
                    ),
                    FilledButton(
                      key: Key('photo-send-${widget.mediaId}'),
                      onPressed: _busy
                          ? null
                          : () => _save(heart: liked, comment: _comment.text),
                      child: const Text('送出'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
            ],
            Text(
              heartLine,
              key: Key('photo-hearts-${widget.mediaId}'),
              style: TextStyle(
                fontSize: size,
                fontWeight: widget.large ? FontWeight.bold : null,
              ),
            ),
            for (final e in comments)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${_name(e.key)}：${e.value['comment']}',
                  style: TextStyle(fontSize: size),
                ),
              ),
            if (!widget.allowComment && comments.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton.icon(
                    key: Key('photo-listen-${widget.mediaId}'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(180, 56),
                    ),
                    onPressed: () => _readAloud(comments),
                    icon: const Icon(Icons.volume_up, size: 28),
                    label: Text('聽家人的留言', style: TextStyle(fontSize: size)),
                  ),
                ),
              ),
            if (_status != null)
              Text(
                _status!,
                style: TextStyle(
                  fontSize: size - 2,
                  color: _statusError ? FhColors.danger : null,
                ),
              ),
          ],
        );
      },
    );
  }
}
