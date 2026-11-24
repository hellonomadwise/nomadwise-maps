import 'package:flutter/material.dart';

import '../theme.dart';

/// Clean-up, day by day: how many were waiting at the end of each day,
/// as bars that should fall to nothing (Jonathan, 24 Nov 2026: "like
/// bar chart overtime, similar to google search console indexing,
/// where the goal is to have the bar chart line be zero. so i can see
/// it reducing, and it increases if there's actions to take").
///
/// [days] come from admin_quality_history (migration 354): one row a
/// day, the last being today. [group] is the list on show, 'closed' or
/// 'nolocation'. [now] is what that list holds this minute, so the last
/// bar moves the moment a page is retired, without reading the days
/// again.
class CleanupChart extends StatefulWidget {
  const CleanupChart({
    super.key,
    required this.days,
    required this.group,
    required this.now,
  });

  final List<Map<String, dynamic>> days;
  final String group;
  final int now;

  @override
  State<CleanupChart> createState() => _CleanupChartState();
}

class _CleanupChartState extends State<CleanupChart> {
  int? _picked;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _day(DateTime d) => '${d.day} ${_months[d.month - 1]}';

  static int _n(Object? x) => x is num ? x.toInt() : int.tryParse('$x') ?? 0;

  @override
  void didUpdateWidget(CleanupChart old) {
    super.didUpdateWidget(old);
    if (old.group != widget.group) _picked = null;
  }

  @override
  Widget build(BuildContext context) {
    final closed = widget.group == 'closed';
    // (day, how many were waiting, worked out afterwards)
    final pts = <(DateTime, int, bool)>[];
    for (final d in widget.days) {
      final day = DateTime.tryParse('${d['day']}');
      if (day == null) continue;
      if (closed) {
        pts.add((day, _n(d['closed_temp']) + _n(d['closed_perm']), d['estimated'] == true));
      } else if (d['no_location'] != null) {
        pts.add((day, _n(d['no_location']), false));
      }
    }
    if (pts.isEmpty) return const SizedBox.shrink();
    pts[pts.length - 1] = (pts.last.$1, widget.now, false);

    var max = 0;
    for (final p in pts) {
      if (p.$2 > max) max = p.$2;
    }
    final last = pts.length - 1;
    final i = (_picked ?? last).clamp(0, last);
    final at = pts[i];
    final color = closed ? Brand.accent : Brand.inkSecondary;

    // Against a week before today, when that day is held.
    String? change;
    Color changeColor = Brand.inkSecondary;
    final weekAgo = pts.last.$1.subtract(const Duration(days: 7));
    for (final p in pts) {
      if (p.$1.year == weekAgo.year && p.$1.month == weekAgo.month && p.$1.day == weekAgo.day) {
        final diff = pts.last.$2 - p.$2;
        if (diff == 0) {
          change = 'The same as a week ago';
        } else if (diff < 0) {
          change = '${-diff} fewer than a week ago';
          changeColor = Brand.success;
        } else {
          change = '$diff more than a week ago';
          changeColor = Brand.accent;
        }
      }
    }

    final worked = pts.where((p) => p.$3).toList();
    final what = closed ? 'closed places to decide on' : 'live pages with no Location';
    const h = 56.0;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 2,
            children: [
              Text(
                  at.$2 == 0
                      ? (i == last ? 'Nothing waiting' : 'Nothing waiting on ${_day(at.$1)}')
                      : '${at.$2} $what${i == last ? '' : ' on ${_day(at.$1)}'}',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: at.$2 == 0 ? Brand.success : Brand.ink)),
              if (change != null && i == last)
                Text(change,
                    style: TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w700, color: changeColor)),
            ]),
        const SizedBox(height: 10),
        SizedBox(
          height: h,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var k = 0; k < pts.length; k++)
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 18),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _picked = k == last ? null : k),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 0.75),
                        height: max == 0
                            ? 1.0
                            : (h * pts[k].$2 / max)
                                .clamp(pts[k].$2 > 0 ? 2.0 : 1.0, h)
                                .toDouble(),
                        decoration: BoxDecoration(
                            color: pts[k].$2 == 0
                                ? Brand.inkFaint
                                : (k == i ? color : color.withValues(alpha: .45)),
                            borderRadius:
                                const BorderRadius.vertical(top: Radius.circular(2))),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ),
        Container(height: 1, color: Brand.border),
        const SizedBox(height: 4),
        Row(children: [
          Text(_day(pts.first.$1),
              style: const TextStyle(fontSize: 11.5, color: Brand.inkSecondary)),
          const Spacer(),
          const Text('today',
              style: TextStyle(fontSize: 11.5, color: Brand.inkSecondary)),
        ]),
        const SizedBox(height: 6),
        Text(
            'One bar a day. The aim is none: it falls as you decide and rises '
            'when something new needs you. Tap a bar for that day.'
            '${worked.isNotEmpty ? ' Days up to ${_day(worked.last.$1)} are worked out from when each closure was reported and each page retired.' : ''}'
            '${!closed && pts.length < 7 ? ' Counted from ${_day(pts.first.$1)}, so it fills in from here.' : ''}',
            style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted, height: 1.4)),
      ]),
    );
  }
}
