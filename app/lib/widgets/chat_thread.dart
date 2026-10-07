import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../theme.dart';

/// One conversation, as in the chat apps people already use: their
/// messages on the left, yours on the right, the time under each, one
/// tick for sent and two once the other side has opened the chat, a
/// small note above the box, and a box to write in.
///
/// Used twice (migration 161): by an owner in their Owner account, to
/// write to Nomadwise, and by a founder in the Chats screen, to answer.
/// Each side passes its own way of loading and sending; the picture is
/// the same. It looks again every few seconds while it is on screen,
/// so an answer appears without reloading.
class ChatThread extends StatefulWidget {
  /// The messages, oldest first. Each: id, team (true when it is from
  /// Nomadwise), author, body, at, read, email (true when it arrived
  /// as an answer by email, migration 162).
  final Future<List<Map<String, dynamic>>> Function() load;

  /// Sends one message and returns the conversation after it.
  final Future<List<Map<String, dynamic>>> Function(String body) send;

  /// True when this side is Nomadwise (the founder's screen).
  final bool team;

  /// The small note above the box.
  final String note;

  /// Shown while nothing has been written yet.
  final String emptyTitle;
  final String emptyText;

  /// The grey words in the empty box.
  final String hint;

  /// When set, nothing can be written and this says why.
  final String? closedText;

  /// Called after each look, with the messages (for a badge elsewhere).
  final void Function(List<Map<String, dynamic>> messages)? onLoaded;

  const ChatThread({
    super.key,
    required this.load,
    required this.send,
    required this.team,
    required this.note,
    required this.emptyTitle,
    required this.emptyText,
    this.hint = 'Write your message',
    this.closedText,
    this.onLoaded,
  });

  @override
  State<ChatThread> createState() => _ChatThreadState();
}

class _ChatThreadState extends State<ChatThread> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  Timer? _timer;
  List<Map<String, dynamic>> _messages = const [];
  bool _loading = true;
  bool _looking = false;
  bool _sending = false;
  String? _error;
  // The error on screen is from a look, not from a send: only then
  // may a later look that works take it away.
  bool _lookFailed = false;
  // Counts sends, so a look that was already on its way when one was
  // made does not put the older picture back.
  int _sends = 0;
  // The first look has been made (so the next ones are quiet ones).
  bool _opened = false;

  @override
  void initState() {
    super.initState();
    _look();
    _timer = Timer.periodic(const Duration(seconds: 8), (_) => _look());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _text.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _look() async {
    if (_looking || _sending) return;
    // Looking is what marks the other side's messages as seen, so it
    // stops while the page is out of sight (another browser tab, the
    // phone locked): nothing is "seen" that nobody saw, and the email
    // that tells an owner we wrote still goes. A chat opened out of
    // sight makes its first look when the page is looked at.
    final life = WidgetsBinding.instance.lifecycleState;
    if (life == AppLifecycleState.hidden ||
        life == AppLifecycleState.paused ||
        life == AppLifecycleState.detached) {
      return;
    }
    final first = !_opened;
    _opened = true;
    _looking = true;
    final sends = _sends;
    try {
      final rows = await widget.load();
      if (!mounted) return;
      // a message was sent meanwhile: this picture is the older one
      if (sends != _sends || _sending) return;
      _show(rows, jump: first);
      if (_lookFailed || _loading) {
        setState(() {
          if (_lookFailed) _error = null;
          _lookFailed = false;
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      // A look that fails in the background says nothing: the next
      // one is seconds away. Only the first is worth a word.
      if (first) {
        setState(() {
          _loading = false;
          _lookFailed = true;
          _error = _plain(e);
        });
      }
    } finally {
      _looking = false;
    }
  }

  /// Puts the messages on screen; goes to the newest when there is a
  /// new one (or on opening), and otherwise leaves the reader where
  /// they have scrolled to.
  void _show(List<Map<String, dynamic>> rows, {bool jump = false}) {
    // (by the newest message, not the count: the list stops at 400)
    final grew = rows.isNotEmpty &&
        (_messages.isEmpty ||
            '${rows.last['id']}' != '${_messages.last['id']}');
    final changed = grew || _signature(rows) != _signature(_messages);
    if (changed) setState(() => _messages = rows);
    widget.onLoaded?.call(rows);
    if (grew || jump) _toEnd();
  }

  static String _signature(List<Map<String, dynamic>> rows) =>
      rows.map((m) => '${m['id']}:${m['read']}').join(',');

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // (the list is drawn from the newest up, so its start is the end)
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(0);
    });
  }

  Future<void> _send() async {
    final typed = _text.text;
    final words = typed.trim();
    if (words.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
      _lookFailed = false;
    });
    _sends++;
    try {
      final rows = await widget.send(words);
      if (!mounted) return;
      // The box stays open while a message is on its way (closing it
      // would drop the keyboard on a phone), so what was typed
      // meanwhile is kept and only what was sent is taken out.
      if (_text.text == typed) {
        _text.clear();
      } else if (_text.text.startsWith(typed)) {
        _text.text = _text.text.substring(typed.length).trimLeft();
      }
      setState(() {
        _sending = false;
        _loading = false;
      });
      _show(rows, jump: true);
      _focus.requestFocus();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _loading = false;
        _error = _plain(e);
      });
    }
  }

  static String _plain(Object e) {
    final s = '$e';
    final m = RegExp(r'message: (.+?)(, code:|, details:|\)$)').firstMatch(s);
    return (m?.group(1) ?? s).replaceFirst('Exception: ', '').trim();
  }

  /// "Today at 17:43", "Yesterday at 09:10", "3 Oct at 14:02".
  static String when(DateTime at) {
    final now = DateTime.now();
    // (whole days apart, also on the day the clocks change)
    final day = DateTime.utc(at.year, at.month, at.day);
    final today = DateTime.utc(now.year, now.month, now.day);
    final time = DateFormat('HH:mm').format(at);
    final days = today.difference(day).inDays;
    if (days == 0) return 'Today at $time';
    if (days == 1) return 'Yesterday at $time';
    final date = DateFormat(at.year == now.year ? 'd MMM' : 'd MMM y').format(at);
    return '$date at $time';
  }

  bool _mine(Map<String, dynamic> m) => (m['team'] == true) == widget.team;

  Widget _bubble(Map<String, dynamic> m) {
    final mine = _mine(m);
    final at = DateTime.tryParse('${m['at'] ?? ''}')?.toLocal();
    final read = m['read'] == true;
    final byEmail = m['email'] == true;
    final author = '${m['author'] ?? ''}'.trim();
    // Whose words these are, above the other side's messages.
    final from = mine
        ? ''
        : m['team'] == true
            ? (author.isEmpty ? 'Nomadwise' : '$author from Nomadwise')
            : author;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (from.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Text(from,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Brand.inkSecondary)),
              ),
            Padding(
              // room on the far side, so the two voices do not line up
              padding:
                  EdgeInsets.only(left: mine ? 44 : 0, right: mine ? 0 : 44),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: mine ? Brand.logoNavy : Brand.field,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(mine ? 16 : 4),
                      bottomRight: Radius.circular(mine ? 4 : 16),
                    ),
                  ),
                  child: SelectableText('${m['body'] ?? ''}',
                      style: TextStyle(
                          fontSize: 14.5,
                          height: 1.4,
                          color: mine ? Colors.white : Brand.ink)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4, right: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(
                    at == null
                        ? ''
                        : when(at) + (byEmail ? ', by email' : ''),
                    style: const TextStyle(
                        fontSize: 11.5, color: Brand.inkMuted)),
                if (mine) ...[
                  const SizedBox(width: 5),
                  Tooltip(
                    message: read ? 'Seen' : 'Sent',
                    child: Icon(read ? Icons.done_all : Icons.done,
                        size: 15,
                        color: read ? Brand.success : Brand.inkMuted),
                  ),
                ],
              ]),
            ),
          ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final closed = widget.closedText;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: Brand.red))
            : _messages.isEmpty
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.forum_outlined,
                                size: 34, color: Brand.inkFaint),
                            const SizedBox(height: 10),
                            Text(widget.emptyTitle,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800)),
                            const SizedBox(height: 6),
                            Text(widget.emptyText,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 13.5,
                                    height: 1.45,
                                    color: Brand.inkSecondary)),
                          ]),
                    ),
                  )
                // Drawn from the newest message up, so opening a long
                // chat lands on its end without measuring all of it;
                // a short one still starts at the top.
                : Align(
                    alignment: Alignment.topCenter,
                    child: ListView.builder(
                      controller: _scroll,
                      reverse: true,
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                      itemCount: _messages.length,
                      itemBuilder: (_, i) =>
                          _bubble(_messages[_messages.length - 1 - i]),
                    ),
                  ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(_error!,
              style: const TextStyle(color: Brand.red, fontSize: 13)),
        ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
            color: Brand.logoTealTint,
            borderRadius: BorderRadius.circular(10)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 1, right: 8),
            child: Icon(Icons.history_toggle_off,
                size: 16, color: Brand.logoNavy),
          ),
          Expanded(
            child: Text(closed ?? widget.note,
                style: const TextStyle(
                    fontSize: 12.5, height: 1.4, color: Brand.logoNavy)),
          ),
        ]),
      ),
      if (closed == null) ...[
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            // On a computer, Enter sends and Shift+Enter starts a new
            // line. On a phone Enter starts a new line and the button
            // sends. Enter that only confirms a word being composed
            // (Japanese, Chinese, Korean) is left alone.
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: (_, e) {
                if (e is KeyDownEvent &&
                    (e.logicalKey == LogicalKeyboardKey.enter ||
                        e.logicalKey == LogicalKeyboardKey.numpadEnter) &&
                    defaultTargetPlatform != TargetPlatform.android &&
                    defaultTargetPlatform != TargetPlatform.iOS &&
                    !_text.value.composing.isValid &&
                    !HardwareKeyboard.instance.isShiftPressed) {
                  _send();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: _text,
                focusNode: _focus,
                minLines: 1,
                maxLines: 5,
                maxLength: 4000,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                    hintText: widget.hint,
                    counterText: '',
                    border: const OutlineInputBorder(),
                    isDense: true),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 46,
            child: FilledButton(
              onPressed: _sending ? null : _send,
              child: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Send'),
            ),
          ),
        ]),
      ],
    ]);
  }
}
