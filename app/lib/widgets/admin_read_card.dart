import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// "What does this show?" for a control-centre page of numbers
/// (migration 326), first on Emails.
///
/// Jonathan, 12 Nov 2026: "when I'm looking at this information, I'm
/// thinking 'okay cool, but what does this mean', so my next thought
/// is to copy and paste screenshots to show you to analyse. but if we
/// can streamline this then lets do it ... I want to know what the
/// data is showing, and what action or actions to take to improve it
/// ... so I can iterate through this."
///
/// One press sends the page's counts (no names or addresses) to Claude
/// and shows the answer here: a headline, what the numbers show, what
/// to do next, what moved since the last read. The last read is kept
/// and shown when the page opens, with its date; under it, a line for
/// what they have changed since and "Update the read".
/// [page] and [scope] say which numbers (scope is the period on
/// Emails: '30', '90' or '0'); give the card a key that changes with
/// them so it starts again.
class AdminReadCard extends StatefulWidget {
  final String page;
  final String scope;

  /// Said under the answer, e.g. "Last 30 days".
  final String scopeLabel;

  const AdminReadCard(
      {super.key, required this.page, this.scope = '', this.scopeLabel = ''});

  @override
  State<AdminReadCard> createState() => _AdminReadCardState();
}

class _AdminReadCardState extends State<AdminReadCard> {
  final _supabase = SupabaseService();
  Map<String, dynamic>? _read; // the last finished read
  bool _busy = false;
  String? _error;
  int _seq = 0;
  // What the founder changed since the last read, for the next one.
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _seq++; // stops a wait that is still going
    _note.dispose();
    super.dispose();
  }

  /// The last read of these numbers, if there is one; and if one was
  /// asked for a moment ago (on another device, say), wait for it.
  Future<void> _open() async {
    try {
      final r = await _supabase.adminReadLatest(widget.page, widget.scope);
      if (!mounted || r == null) return;
      if ('${r['status']}' == 'waiting') {
        final id = (r['id'] as num?)?.toInt();
        if (id != null) _wait(id);
        return;
      }
      setState(() => _read = r);
    } catch (_) {
      // nothing to show yet; the button still works
    }
  }

  Future<void> _ask() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await _supabase.adminReadAsk(widget.page, widget.scope,
          note: _read == null ? null : _note.text);
      await _wait(id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _plain(e);
      });
    }
  }

  Future<void> _wait(int id) async {
    final seq = ++_seq;
    if (mounted) setState(() => _busy = true);
    for (var i = 0; i < 65; i++) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted || seq != _seq) return;
      Map<String, dynamic> a;
      try {
        a = await _supabase.adminReadAnswer(id);
      } catch (_) {
        continue; // a blip in the connection: ask again
      }
      if (!mounted || seq != _seq) return;
      final status = '${a['status'] ?? ''}';
      if (status == 'waiting') continue;
      setState(() {
        _busy = false;
        if (status == 'done') {
          _read = a;
          _error = null;
          _note.clear();
        } else {
          _error = '${a['error'] ?? 'Something went wrong. Please try again.'}';
        }
      });
      return;
    }
    if (!mounted || seq != _seq) return;
    setState(() {
      _busy = false;
      _error = 'No answer came back. Please try again.';
    });
  }

  static String _plain(Object e) {
    final s = '$e';
    final m = RegExp(r'message: ([^,]+)').firstMatch(s);
    return m != null ? m.group(1)!.trim() : 'That did not work. Please try again.';
  }

  static String _when(dynamic iso, {bool time = true}) {
    final d = DateTime.tryParse('${iso ?? ''}');
    if (d == null) return '';
    return DateFormat(time ? 'd MMM, HH:mm' : 'd MMM').format(d.toLocal());
  }

  static List<String> _lines(dynamic v) => ((v as List?) ?? const [])
      .map((x) => '$x'.trim())
      .where((x) => x.isNotEmpty)
      .toList();

  static const _body = TextStyle(fontSize: 13.5, height: 1.5, color: Brand.ink);
  static const _soft =
      TextStyle(fontSize: 13, height: 1.45, color: Brand.inkSecondary);
  static const _label = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.6,
      color: Brand.inkSecondary);

  @override
  Widget build(BuildContext context) {
    final r = _read;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.insights_outlined, size: 18, color: Brand.ink),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('What this shows, and what to do next',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: Brand.ink)),
          ),
        ]),
        if (_busy) ...[
          const SizedBox(height: 12),
          const Row(children: [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 10),
            Expanded(
                child: Text('Reading the numbers. This takes about 20 seconds.',
                    style: _soft)),
          ]),
        ],
        if (_error != null && !_busy) ...[
          const SizedBox(height: 10),
          Text(_error!,
              style: const TextStyle(
                  fontSize: 13, height: 1.4, color: Color(0xFFD42F3A))),
        ],
        if (r == null && !_busy) ...[
          const SizedBox(height: 6),
          const Text(
              'A plain read of the numbers on this page: what they show, '
              'where owners drop away, and one to three things to change. '
              'Ask again after you have made a change and it says what moved.',
              style: _soft),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _ask,
              style: FilledButton.styleFrom(
                  backgroundColor: Brand.red,
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8))),
              child: const Text('What does this show?'),
            ),
          ),
        ],
        if (r != null) ..._answer(r),
        if (r != null && !_busy) ...[
          const SizedBox(height: 12),
          const Divider(height: 1, color: Brand.border),
          const SizedBox(height: 12),
          // Look again: the next read is told the last one's numbers and
          // actions, and this line if they wrote one.
          Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: TextField(
                    controller: _note,
                    maxLength: 600,
                    minLines: 1,
                    maxLines: 3,
                    style: const TextStyle(fontSize: 13.5),
                    decoration: InputDecoration(
                      isDense: true,
                      counterText: '',
                      hintText: 'What have you changed since this read? (optional)',
                      hintStyle:
                          const TextStyle(fontSize: 13.5, color: Brand.inkMuted),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 11),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Brand.border)),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Brand.border)),
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: _ask,
                  style: FilledButton.styleFrom(
                      backgroundColor: Brand.ink,
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8))),
                  child: const Text('Update the read'),
                ),
              ]),
        ],
        const SizedBox(height: 10),
        const Text(
            'Written by Claude from the counts on this page. No names or '
            'email addresses are sent.',
            style: TextStyle(fontSize: 11.5, height: 1.4, color: Brand.inkMuted)),
      ]),
    );
  }

  List<Widget> _answer(Map<String, dynamic> r) {
    final shows = _lines(r['shows']);
    final changed = _lines(r['changed']);
    final actions = ((r['actions'] as List?) ?? const [])
        .whereType<Map>()
        .where((a) => '${a['do'] ?? ''}'.trim().isNotEmpty)
        .toList();
    final headline = '${r['headline'] ?? ''}'.trim();
    final caveat = '${r['caveat'] ?? ''}'.trim();
    final prev = _when(r['previous_at'], time: false);
    final faded = _busy ? 0.45 : 1.0; // the old read, while a new one comes
    return [
      Opacity(
        opacity: faded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (headline.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(headline,
                style: const TextStyle(
                    fontSize: 15,
                    height: 1.4,
                    fontWeight: FontWeight.w700,
                    color: Brand.ink)),
          ],
          if (shows.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('WHAT IT SHOWS', style: _label),
            const SizedBox(height: 4),
            for (final s in shows) _point(s),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('WHAT TO DO NEXT', style: _label),
            const SizedBox(height: 6),
            for (var i = 0; i < actions.length; i++) _action(i + 1, actions[i]),
          ],
          if (changed.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
                prev.isEmpty
                    ? 'SINCE THE LAST READ'
                    : 'SINCE THE LAST READ (${prev.toUpperCase()})',
                style: _label),
            const SizedBox(height: 4),
            for (final s in changed) _point(s),
          ],
          if (caveat.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Bear in mind: $caveat', style: _soft),
          ],
          if ('${r['note'] ?? ''}'.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('You said you had changed: ${'${r['note']}'.trim()}', style: _soft),
          ],
          const SizedBox(height: 10),
          Text(
              'Read on ${_when(r['asked_at'])}'
              '${widget.scopeLabel.isEmpty ? '' : ' · ${widget.scopeLabel}'}',
              style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
        ]),
      ),
    ];
  }

  Widget _point(String s) => Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 8, right: 9, left: 2),
            child: SizedBox(
                width: 5,
                height: 5,
                child: DecoratedBox(
                    decoration: BoxDecoration(
                        color: Brand.inkMuted, shape: BoxShape.circle))),
          ),
          Expanded(child: Text(s, style: _body)),
        ]),
      );

  Widget _action(int n, Map a) {
    final why = '${a['why'] ?? ''}'.trim();
    final watch = '${a['watch'] ?? ''}'.trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
          color: Brand.bg, borderRadius: BorderRadius.circular(8)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration:
              const BoxDecoration(color: Brand.ink, shape: BoxShape.circle),
          child: Text('$n',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${a['do']}'.trim(),
                style: const TextStyle(
                    fontSize: 13.5,
                    height: 1.45,
                    fontWeight: FontWeight.w600,
                    color: Brand.ink)),
            if (why.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Why: $why', style: _soft),
            ],
            if (watch.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text('Watch: $watch', style: _soft),
            ],
          ]),
        ),
      ]),
    );
  }
}
