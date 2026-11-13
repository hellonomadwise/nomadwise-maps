import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// "When we send" on Claim plan (migration 328).
///
/// Jonathan, 13 Nov 2026: "Also want to track the days I send outreach
/// and times, to over time work out when is the best to send outreach
/// or comms out."
///
/// Every "I sent it" already keeps its day and time. This reads them
/// back: first hellos (or follow-ups) by day of the week and by time
/// of day in the SPACE'S OWN local time, with what came of each (claim
/// page opened, claimed, replied), and the days we sent on in the
/// reader's own time. A day or a time of day is only compared once it
/// has enough sends (30, from the database); until then it is shown in
/// grey and no winner is named.
class OutreachTimingCard extends StatefulWidget {
  const OutreachTimingCard({super.key});

  @override
  State<OutreachTimingCard> createState() => _OutreachTimingCardState();
}

const _dayNames = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
];

/// (name, the hours it covers) in the space's local time.
const _bandNames = <(String, String)>[
  ('Morning', '6am to noon'),
  ('Afternoon', 'noon to 5pm'),
  ('Evening', '5pm to 10pm'),
  ('Night', '10pm to 6am'),
];

int _bandOf(int hour) => hour >= 6 && hour < 12
    ? 0
    : hour >= 12 && hour < 17
        ? 1
        : hour >= 17 && hour < 22
            ? 2
            : 3;

class _OutreachTimingCardState extends State<OutreachTimingCard> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _rows;
  int _min = 30;
  DateTime? _since;
  String? _error;
  bool _open = false;
  String _kind = 'hello'; // hello, nudge

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _supabase.adminOutreachTiming();
      if (!mounted) return;
      setState(() {
        _rows = [
          for (final x in (d['rows'] as List? ?? const []))
            Map<String, dynamic>.from(x as Map)
        ];
        _min = ((d['min_sample'] as num?) ?? 30).toInt();
        _since = DateTime.tryParse('${d['since'] ?? ''}');
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _rows = const [];
        _error = '$e'.contains('admin_outreach_timing')
            ? 'Not installed yet: migration 328 has not run. Check the last build on GitHub.'
            : 'Could not load: $e';
      });
    }
  }

  /// [sent, opened claim page, claimed, replied]
  static void _count(List<int> g, Map<String, dynamic> r) {
    g[0]++;
    if (r['opened'] == true) g[1]++;
    if (r['claimed'] == true) g[2]++;
    if (r['replied'] == true) g[3]++;
  }

  static String _plural(int n, String one, String many) => n == 1 ? '1 $one' : '$n $many';

  /// The best of the slots that have enough sends, in words; null when
  /// fewer than two of them have enough to be compared.
  String? _best(List<List<int>> gs, List<String> names, String what) {
    final ok = [
      for (var i = 0; i < gs.length; i++)
        if (gs[i][0] >= _min) i
    ];
    if (ok.length < 2) return null;
    double rate(int i, int col) => gs[i][col] / gs[i][0];
    // most claims for each send; then most claim pages opened
    ok.sort((a, b) {
      final c = rate(b, 2).compareTo(rate(a, 2));
      return c != 0 ? c : rate(b, 1).compareTo(rate(a, 1));
    });
    final first = ok[0];
    final second = ok[1];
    final w = gs[first];
    if (w[2] == 0 && w[1] == 0) {
      return 'No $what with $_min sends or more has a claim or an opened claim page yet.';
    }
    if (rate(first, 2) == rate(second, 2) && rate(first, 1) == rate(second, 1)) {
      return 'No difference yet between the best two by $what.';
    }
    return w[2] > 0
        ? '${names[first]} has the most claims for each send so far: ${w[2]} of ${w[0]}.'
        : '${names[first]} has the most claim pages opened for each send so far: '
            '${w[1]} of ${w[0]}.';
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final hellos = (rows ?? const []).where((r) => r['kind'] == 'hello').length;
    final nudges = (rows ?? const []).where((r) => r['kind'] == 'nudge').length;
    final String summary;
    if (rows == null) {
      summary = 'Loading...';
    } else if (_error != null) {
      summary = _error!;
    } else if (rows.isEmpty) {
      summary = 'Nothing sent yet. Each time you press I sent it, the day and time are kept here.';
    } else {
      summary = '${_plural(hellos, 'first hello', 'first hellos')} and '
          '${_plural(nudges, 'follow-up', 'follow-ups')} recorded. '
          'Which days and times of day they landed on, and what came of them.';
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('When we send',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(summary,
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: _error != null
                              ? const Color(0xFFD42F3A)
                              : Brand.inkSecondary)),
                ]),
              ),
              Icon(_open ? Icons.expand_less : Icons.expand_more, color: Brand.inkMuted),
            ]),
          ),
        ),
        if (_open && rows != null && _error == null && rows.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
            child: LayoutBuilder(
                builder: (context, box) => _detail(rows, hellos, nudges, box.maxWidth < 520)),
          ),
      ]),
    );
  }

  Widget _detail(List<Map<String, dynamic>> rows, int hellos, int nudges, bool narrow) {
    final mine = rows.where((r) => r['kind'] == _kind).toList();
    final byDay = [for (var i = 0; i < 7; i++) [0, 0, 0, 0]];
    final byBand = [for (var i = 0; i < 4; i++) [0, 0, 0, 0]];
    var noPlace = 0;
    for (final r in mine) {
      final dow = (r['dow'] as num?)?.toInt();
      final hour = (r['hour'] as num?)?.toInt();
      if (dow == null || hour == null || dow < 1 || dow > 7) {
        noPlace++;
        continue;
      }
      _count(byDay[dow - 1], r);
      _count(byBand[_bandOf(hour)], r);
    }

    // The days we sent on, in the reader's own time: newest first.
    final days = <DateTime, List<DateTime>>{};
    for (final r in mine) {
      final at = DateTime.tryParse('${r['at'] ?? ''}')?.toLocal();
      if (at == null) continue;
      days.putIfAbsent(DateTime(at.year, at.month, at.day), () => []).add(at);
    }
    final sendDays = days.keys.toList()..sort((a, b) => b.compareTo(a));

    final what = _kind == 'hello' ? 'first hellos' : 'follow-ups';
    final String verdict;
    if (mine.isEmpty) {
      verdict = 'No $what recorded yet.';
    } else {
      final found = [
        _best(byDay, _dayNames, 'day'),
        _best(byBand, [for (final b in _bandNames) b.$1], 'time of day'),
      ].whereType<String>().toList();
      if (found.isEmpty) {
        var most = 0;
        for (final g in [...byDay, ...byBand]) {
          if (g[0] > most) most = g[0];
        }
        verdict = 'Too early to say which day or time is best. A day or a time of day '
            'needs $_min sends before it is compared, and the busiest so far has $most. '
            'Spread your sending over different days and times, so there is '
            'something to compare.';
      } else {
        verdict = '${found.join(' ')} Small gaps can still be chance: look for one '
            'that holds as the numbers grow.';
      }
    }

    final noPlaceNote = noPlace == 0
        ? ''
        : noPlace == 1
            ? ' 1 send has no known place and is left out of these two tables.'
            : ' $noPlace sends have no known place and are left out of these two tables.';

    final cw = narrow ? 56.0 : 84.0;
    final sentW = narrow ? 60.0 : 84.0;
    final betweenW = narrow ? 112.0 : 130.0;
    const headStyle =
        TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Brand.inkMuted);

    Widget head(String first) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            Expanded(child: Text(first, style: headStyle)),
            for (final h in const ['Sent', 'Opened', 'Claimed', 'Replied'])
              SizedBox(
                  width: cw, child: Text(h, textAlign: TextAlign.right, style: headStyle)),
          ]),
        );

    Widget line(String name, String? sub, List<int> g) {
      final enough = g[0] >= _min;
      final colour = enough ? Brand.ink : Brand.inkMuted;
      String cell(int i) => i == 0 || !enough || g[i] == 0
          ? '${g[i]}'
          : '${g[i]} (${(g[i] * 100 / g[0]).round()}%)';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: colour)),
              if (sub != null)
                Text(sub, style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
            ]),
          ),
          for (var i = 0; i < 4; i++)
            SizedBox(
                width: cw,
                child: Text(cell(i),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    style: TextStyle(
                        fontSize: narrow ? 13 : 14,
                        fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w500,
                        color: enough && i == 2 && g[i] > 0 ? Brand.success : colour))),
        ]),
      );
    }

    const small = TextStyle(fontSize: 12.5, color: Brand.inkMuted, height: 1.4);
    final dayFmt = DateFormat('EEE d MMM');
    final timeFmt = DateFormat('HH:mm');

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final k in [
          ('hello', 'First hellos ($hellos)'),
          ('nudge', 'Follow-ups ($nudges)'),
        ])
          ChoiceChip(
            label: Text(k.$2),
            selected: _kind == k.$1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            onSelected: (_) => setState(() => _kind = k.$1),
          ),
      ]),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(color: Brand.bg, borderRadius: BorderRadius.circular(8)),
        child: Text(verdict,
            style: const TextStyle(fontSize: 14, height: 1.45, fontWeight: FontWeight.w600)),
      ),
      const SizedBox(height: 10),
      const Text(
          'Days and times are in each space\'s own local time: an email you send '
          'in the morning can land in the evening in Bali. The time kept is when '
          'you press I sent it, so press it as you send.',
          style: TextStyle(fontSize: 13, color: Brand.inkSecondary, height: 1.4)),
      const SizedBox(height: 16),
      head('Day of the week'),
      for (var i = 0; i < 7; i++) line(_dayNames[i], null, byDay[i]),
      const SizedBox(height: 16),
      head('Time of day'),
      for (var i = 0; i < 4; i++) line(_bandNames[i].$1, _bandNames[i].$2, byBand[i]),
      const SizedBox(height: 10),
      Text(
          'Grey rows have fewer than $_min sends: too few to judge. Opened means a '
          'person opened the space\'s claim page after the message.$noPlaceNote',
          style: small),
      if (sendDays.isNotEmpty) ...[
        const SizedBox(height: 18),
        Row(children: [
          const Expanded(child: Text('Days you sent on, your time', style: headStyle)),
          SizedBox(
              width: sentW,
              child: const Text('Sent', textAlign: TextAlign.right, style: headStyle)),
          SizedBox(
              width: betweenW,
              child: const Text('Between', textAlign: TextAlign.right, style: headStyle)),
        ]),
        const SizedBox(height: 4),
        for (final d in sendDays.take(10))
          Builder(builder: (context) {
            final at = days[d]!..sort();
            final from = timeFmt.format(at.first);
            final to = timeFmt.format(at.last);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Expanded(
                    child: Text(dayFmt.format(d),
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
                SizedBox(
                    width: sentW,
                    child: Text('${at.length}',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
                SizedBox(
                    width: betweenW,
                    child: Text(from == to ? from : '$from to $to',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 14, color: Brand.inkSecondary))),
              ]),
            );
          }),
        if (sendDays.length > 10) ...[
          const SizedBox(height: 4),
          Text('The last 10 of ${sendDays.length} days.', style: small),
        ],
      ],
      if (_since != null) ...[
        const SizedBox(height: 10),
        Text(
            'Counted since ${DateFormat('d MMMM yyyy').format(_since!.toUtc())}, on every '
            'channel (email, WhatsApp, Instagram). Answers to their messages are not counted.',
            style: small),
      ],
    ]);
  }
}
