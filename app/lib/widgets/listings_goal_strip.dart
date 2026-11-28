import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';

/// The listings goal in one strip, at the top of Ready to approve, where
/// the pages are approved: live against the goal, today against the
/// daily target, the streak. The full card with the daily bars is on
/// Home (Jonathan, 28 Nov 2026: "I want a goal of getting 10k listings
/// live so want to gamify to get this done").
class ListingsGoalStrip extends StatelessWidget {
  const ListingsGoalStrip({super.key, required this.goal});

  /// admin_listings_goal() (migration 367).
  final Map<String, dynamic> goal;

  static int _n(Object? x) => x is num ? x.toInt() : int.tryParse('$x') ?? 0;

  @override
  Widget build(BuildContext context) {
    final f = NumberFormat.decimalPattern();
    final live = _n(goal['live']);
    final target = _n(goal['goal']) > 0 ? _n(goal['goal']) : 10000;
    final daily = _n(goal['daily']) > 0 ? _n(goal['daily']) : 25;
    final days = goal['days'] is List ? goal['days'] as List : const [];
    final today = days.isEmpty || days.last is! Map ? 0 : _n((days.last as Map)['n']);
    final streak = _n(goal['streak']);
    final pace = goal['pace'] is num ? (goal['pace'] as num).toDouble() : 0.0;
    final left = target - live;
    final done = pace > 0 && left > 0
        ? DateFormat('MMM yyyy')
            .format(DateTime.now().add(Duration(days: (left / pace).ceil())))
        : null;
    const small = TextStyle(fontSize: 12, color: Brand.inkSecondary);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(
            spacing: 10,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('${f.format(live)} of ${f.format(target)} live',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w800, color: Brand.ink)),
              Text('Today $today of $daily',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: today >= daily ? Brand.success : Brand.inkSecondary)),
              if (streak > 0)
                Text(streak == 1 ? '1 day in a row' : '$streak days in a row',
                    style: small),
              Text(
                  '${pace.toStringAsFixed(1)} a day${done == null ? '' : ' · done by $done'}',
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Brand.accent)),
            ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: (live / target).clamp(0.005, 1.0),
            minHeight: 7,
            backgroundColor: Brand.field,
            color: Brand.accent,
          ),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: (today / daily).clamp(0.0, 1.0),
            minHeight: 4,
            backgroundColor: Brand.field,
            color: today >= daily ? Brand.success : const Color(0xFF1F6FB2),
          ),
        ),
        const SizedBox(height: 4),
        const Text('Top: the goal. Below: today against the daily target.',
            style: TextStyle(fontSize: 11, color: Brand.inkMuted)),
      ]),
    );
  }
}
