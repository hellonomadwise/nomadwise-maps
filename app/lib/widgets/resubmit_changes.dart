import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';

/// Owner changes, when an owner submits again after we sent their
/// changes back: our note, then only what they changed since, with the
/// description marked word by word (added in green, removed struck
/// through in red). Checking a resubmission then takes seconds rather
/// than reading the whole thing again.
class ResubmitChanges extends StatelessWidget {
  final Map<String, dynamic> sentBack; // note, at, previous
  final Map<String, dynamic> current; // the draft as submitted now
  const ResubmitChanges(
      {super.key, required this.sentBack, required this.current});

  static String _s(dynamic x) => (x ?? '').toString().trim();
  static Map<String, dynamic> _m(dynamic x) =>
      x is Map ? Map<String, dynamic>.from(x) : <String, dynamic>{};

  static const _prices = [
    ('day', 'Day pass'),
    ('week', 'Week pass'),
    ('month', 'Month pass'),
    ('coffee', 'Cappuccino'),
  ];
  static const _days = [
    ('mon', 'Monday'),
    ('tue', 'Tuesday'),
    ('wed', 'Wednesday'),
    ('thu', 'Thursday'),
    ('fri', 'Friday'),
    ('sat', 'Saturday'),
    ('sun', 'Sunday'),
  ];
  static const _facts = [
    ('laptops_allowed', 'Laptops welcome'),
    ('power_outlets', 'Plug sockets'),
    ('good_for_calls', 'Good for calls'),
    ('quiet_space', 'Quiet area'),
    ('comfortable_seating', 'Comfortable seating'),
    ('aircon', 'Aircon'),
    ('access_24h', '24 hour access'),
    ('call_room', 'Call room'),
    ('monitor', 'Monitors'),
    ('office_chairs', 'Office chairs'),
    ('cozy', 'Cozy'),
  ];
  static const _contact = [
    ('website', 'Website'),
    ('instagram', 'Instagram'),
    ('whatsapp', 'WhatsApp'),
    ('enquiry_email', 'Enquiries to'),
  ];
  static const _mention = [
    ('kind', 'Message kind'),
    ('title', 'Message headline'),
    ('body', 'Message text'),
    ('cta', 'Message button'),
    ('url', 'Message link'),
  ];

  /// Everything that differs between the two submissions, except the
  /// description (shown on its own, word by word): label, before, after.
  static List<(String, String, String)> _changes(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    final out = <(String, String, String)>[];
    void add(String label, dynamic x, dynamic y) {
      final bx = _s(x), by = _s(y);
      if (bx != by) out.add((label, bx, by));
    }

    final pa = _m(a['prices']), pb = _m(b['prices']);
    for (final (k, l) in _prices) {
      add(l, pa[k], pb[k]);
    }
    final ha = _m(a['hours']), hb = _m(b['hours']);
    for (final (k, l) in _days) {
      add(l, ha[k], hb[k]);
    }
    String yn(dynamic x) => x == null ? '' : (x == true ? 'Yes' : 'No');
    final fa = _m(a['facts']), fb = _m(b['facts']);
    for (final (k, l) in _facts) {
      add(l, yn(fa[k]), yn(fb[k]));
    }
    for (final (k, l) in _contact) {
      add(l, a[k], b[k]);
    }
    final ma = _m(a['mention']), mb = _m(b['mention']);
    for (final (k, l) in _mention) {
      add(l, ma[k], mb[k]);
    }
    final oldPhotos = List<String>.from((a['photos'] ?? const []) as List);
    final newPhotos = List<String>.from((b['photos'] ?? const []) as List);
    final added = newPhotos.where((p) => !oldPhotos.contains(p)).length;
    final removed = oldPhotos.where((p) => !newPhotos.contains(p)).length;
    final reordered = added == 0 &&
        removed == 0 &&
        oldPhotos.join('|') != newPhotos.join('|');
    if (added > 0 || removed > 0 || reordered) {
      out.add((
        'Photos',
        '${oldPhotos.length} photo${oldPhotos.length == 1 ? '' : 's'}',
        [
          if (added > 0) '$added added',
          if (removed > 0) '$removed removed',
          if (reordered) 'order changed',
        ].join(', ')
      ));
    }
    return out;
  }

  /// Word by word: which words stayed, which went, which are new.
  /// Line breaks count as words so a new paragraph shows too.
  static List<(int, String)> _wordDiff(String a, String b) {
    List<String> words(String t) => RegExp(r'\n|[^\s]+')
        .allMatches(t)
        .map((m) => m.group(0)!)
        .toList();
    final x = words(a), y = words(b);
    final n = x.length, m = y.length;
    // Longest common run of words (fine for page-length text).
    final t = List.generate(n + 1, (_) => List.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        t[i][j] = x[i] == y[j]
            ? t[i + 1][j + 1] + 1
            : (t[i + 1][j] >= t[i][j + 1] ? t[i + 1][j] : t[i][j + 1]);
      }
    }
    final out = <(int, String)>[]; // 0 same, -1 removed, 1 added
    var i = 0, j = 0;
    while (i < n && j < m) {
      if (x[i] == y[j]) {
        out.add((0, x[i]));
        i++;
        j++;
      } else if (t[i + 1][j] >= t[i][j + 1]) {
        out.add((-1, x[i++]));
      } else {
        out.add((1, y[j++]));
      }
    }
    while (i < n) {
      out.add((-1, x[i++]));
    }
    while (j < m) {
      out.add((1, y[j++]));
    }
    return out;
  }

  Widget _description(String before, String after) {
    final parts = _wordDiff(before, after);
    final spans = <InlineSpan>[];
    for (final (kind, w) in parts) {
      if (w == '\n') {
        // A removed line break is left out; others keep the layout.
        if (kind != -1) spans.add(const TextSpan(text: '\n'));
        continue;
      }
      spans.add(TextSpan(
          text: w,
          style: switch (kind) {
            1 => const TextStyle(
                backgroundColor: Brand.successTint,
                color: Color(0xFF1E6B35),
                fontWeight: FontWeight.w600),
            -1 => const TextStyle(
                backgroundColor: Brand.accentTint,
                color: Brand.accent,
                decoration: TextDecoration.lineThrough),
            _ => null,
          }));
      spans.add(const TextSpan(text: ' '));
    }
    return Text.rich(TextSpan(
        style: const TextStyle(fontSize: 13, height: 1.55, color: Brand.ink),
        children: spans));
  }

  static Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Text(t,
            style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: Brand.inkSecondary)),
      );

  @override
  Widget build(BuildContext context) {
    final note = _s(sentBack['note']);
    final at = DateTime.tryParse(_s(sentBack['at']))?.toLocal();
    final prevRaw = sentBack['previous'];
    final prev = _m(prevRaw);
    final known = prevRaw is Map;
    final descBefore = _s(prev['description']);
    final descAfter = _s(current['description']);
    final descChanged = known && descBefore != descAfter;
    final changes = known ? _changes(prev, current) : const <(String, String, String)>[];
    final nothing = known && !descChanged && changes.isEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.compare_arrows, size: 18, color: Brand.accent),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('Submitted again after your note',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
          ),
          if (at != null)
            Text('note sent ${DateFormat('d MMM, HH:mm').format(at)}',
                style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
        ]),
        if (note.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: Brand.bg,
              borderRadius: BorderRadius.circular(8),
              border: const Border(
                  left: BorderSide(color: Brand.goldTextDark, width: 3)),
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('YOUR NOTE'),
                  SelectableText(note,
                      style: const TextStyle(fontSize: 13, height: 1.5)),
                ]),
          ),
        ],
        const SizedBox(height: 12),
        if (!known)
          const Text(
              'What they sent before your note was not kept (it predates '
              'the history), so the full comparison with the page is below.',
              style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary))
        else if (nothing)
          Row(children: const [
            Icon(Icons.info_outline, size: 16, color: Brand.goldTextDark),
            SizedBox(width: 6),
            Expanded(
              child: Text('They submitted again without changing anything.',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Brand.goldTextDark)),
            ),
          ])
        else ...[
          Text(
              'WHAT THEY CHANGED SINCE  ·  '
              '${(descChanged ? 1 : 0) + changes.length} '
              'change${(descChanged ? 1 : 0) + changes.length == 1 ? '' : 's'}',
              style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: .4,
                  color: Brand.accent)),
          const SizedBox(height: 8),
          if (descChanged) ...[
            _label('Description'),
            _description(descBefore, descAfter),
            const SizedBox(height: 4),
            const Text('Green is new, red was taken out.',
                style: TextStyle(fontSize: 11, color: Brand.inkMuted)),
            const SizedBox(height: 10),
          ],
          for (final (label, before, after) in changes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label(label),
                    Text.rich(TextSpan(
                        style: const TextStyle(fontSize: 13, height: 1.4),
                        children: [
                          if (before.isNotEmpty) ...[
                            TextSpan(
                                text: before,
                                style: const TextStyle(
                                    color: Brand.accent,
                                    decoration: TextDecoration.lineThrough)),
                            const TextSpan(
                                text: '  →  ',
                                style: TextStyle(color: Brand.inkMuted)),
                          ],
                          TextSpan(
                              text: after.isEmpty ? '(cleared)' : after,
                              style: const TextStyle(
                                  color: Color(0xFF1E6B35),
                                  fontWeight: FontWeight.w600)),
                        ])),
                  ]),
            ),
          if (!descChanged && known)
            const Text('Description: unchanged.',
                style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
          const SizedBox(height: 2),
          const Text('Everything else is as they sent it before.',
              style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
        ],
      ]),
    );
  }
}
