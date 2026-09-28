import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Admin only: every Google Places call we made, counted by the line
/// it appears under on the Google bill and by who made it (a nightly
/// job, the website push, or visitors in the app). Read it next to
/// the Google Cloud billing report to see which job a charge came
/// from, and whether the app's share grows with traffic.
class GoogleUsageScreen extends StatefulWidget {
  const GoogleUsageScreen({super.key});
  @override
  State<GoogleUsageScreen> createState() => _GoogleUsageScreenState();
}

class _GoogleUsageScreenState extends State<GoogleUsageScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _rows;
  String? _error;

  static const _who = {
    'app': 'Visitors in the app',
    'nightly refresh': 'Nightly refresh',
    'website sync': 'Nightly website sync',
    'website push': 'Website push (every 10 min)',
    'photo check': 'Nightly photo check',
    'photo suggestions': 'Photo suggestions',
    'webflow import': 'Webflow import',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, dynamic>? _budget;

  Future<void> _load() async {
    _supabase.googleBudget().then((b) {
      if (mounted) setState(() => _budget = b);
    });
    try {
      final rows = await _supabase.apiUsage(days: 35);
      if (mounted) {
        setState(() {
          _rows = rows;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _rows = [];
          _error = '$e';
        });
      }
    }
  }

  int _n(dynamic v) => (v as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: const Text('Google calls')),
      body: rows == null
          ? const Center(child: CircularProgressIndicator(color: Brand.accent))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
                children: [
                  const Text(
                      'Every Google Places call we made, under the same '
                      'names as the Google bill, and who made it. Refused '
                      'calls are shown apart; Google does not charge for '
                      'them. Counting started 28 September 2026.',
                      style: TextStyle(
                          fontSize: 12.5, color: Brand.inkSecondary)),
                  const SizedBox(height: 12),
                  if (_error != null)
                    _note(_error!.contains('api_usage')
                        ? 'Not installed yet: migration 89 has not run. '
                            'Check the last build on GitHub.'
                        : 'Could not load: $_error'),
                  if (_error == null && rows.isEmpty)
                    _note('Nothing counted yet. The first numbers arrive '
                        'with the next job run or app visit.'),
                  if (_budget != null) ...[
                    _todayCard(_budget!),
                    const SizedBox(height: 14),
                  ],
                  if (rows.isNotEmpty) ...[
                    _monthCard(rows),
                    const SizedBox(height: 14),
                    ..._days(rows),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _note(String t) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Brand.goldTint, borderRadius: BorderRadius.circular(12)),
        child: Text(t,
            style: const TextStyle(fontSize: 13, color: Brand.goldTextDark)),
      );

  /// Today against the daily limits (migration 90).
  Widget _todayCard(Map<String, dynamic> b) {
    final spent = (b['spent_gbp'] as num?)?.toDouble() ?? 0;
    final lim = (b['limit_gbp'] as num?)?.toDouble() ?? 10;
    final loads = (b['map_loads'] as num?)?.toInt() ?? 0;
    final cap = (b['map_cap'] as num?)?.toInt() ?? 0;
    final over = b['over'] == true;
    return _box([
      const Text('Today (UTC)',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
      const SizedBox(height: 8),
      Text(
          over
              ? 'Lookups paused: about £${spent.toStringAsFixed(2)} of the '
                  '£${lim.toStringAsFixed(0)} daily limit used. Google is not '
                  'asked again until midnight UTC.'
              : 'Lookups: about £${spent.toStringAsFixed(2)} of the '
                  '£${lim.toStringAsFixed(0)} daily limit.',
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: over ? Brand.red : Brand.ink)),
      const SizedBox(height: 4),
      Text('Map loads: $loads of the $cap daily cap.',
          style: const TextStyle(fontSize: 13)),
      const SizedBox(height: 6),
      const Text(
          'Estimated at Google\'s list prices without the free monthly '
          'allowance, so the real bill is lower. Your phone is pinged at '
          'half the limit, at the limit, and at 80% and 100% of the map cap.',
          style: TextStyle(fontSize: 12, color: Brand.inkSecondary)),
    ]);
  }

  /// This month so far, per bill line, split by who made the calls.
  Widget _monthCard(List<Map<String, dynamic>> rows) {
    final month = DateFormat('yyyy-MM').format(DateTime.now().toUtc());
    final bySku = <String, Map<String, int>>{};
    final errs = <String, int>{};
    for (final r in rows.where((r) => '${r['day']}'.startsWith(month))) {
      final sku = '${r['sku']}';
      final who = '${r['source']}';
      (bySku[sku] ??= {})[who] = (bySku[sku]![who] ?? 0) + _n(r['calls']);
      errs[sku] = (errs[sku] ?? 0) + _n(r['errors']);
    }
    int total(String s) => bySku[s]!.values.fold(0, (a, b) => a + b);
    final skus = bySku.keys.toList()..sort((a, b) => total(b) - total(a));
    return _box([
      Text('This month so far (${DateFormat('MMMM').format(DateTime.now())})',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
      const SizedBox(height: 8),
      for (final s in skus) ...[
        Row(children: [
          Expanded(
              child: Text(s,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13))),
          Text(NumberFormat.decimalPattern().format(total(s)),
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 8),
          child: Text(
              [
                for (final e in (bySku[s]!.entries.toList()
                      ..sort((a, b) => b.value - a.value)))
                  '${_who[e.key] ?? e.key} ${e.value}',
                if ((errs[s] ?? 0) > 0) 'refused ${errs[s]}',
              ].join('  ·  '),
              style: const TextStyle(
                  fontSize: 12, color: Brand.inkSecondary)),
        ),
      ],
    ]);
  }

  /// One line per day: total calls, the biggest bill lines.
  List<Widget> _days(List<Map<String, dynamic>> rows) {
    final byDay = <String, Map<String, int>>{};
    for (final r in rows) {
      final d = '${r['day']}';
      final k = '${r['sku']}'.replaceFirst('Place Details ', '');
      (byDay[d] ??= {})[k] = (byDay[d]![k] ?? 0) + _n(r['calls']);
    }
    final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      const Text('By day',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
      const SizedBox(height: 6),
      for (final d in days)
        Builder(builder: (_) {
          final m = byDay[d]!;
          final sum = m.values.fold(0, (a, b) => a + b);
          final parts = m.entries.toList()
            ..sort((a, b) => b.value - a.value);
          final when = DateTime.tryParse(d);
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _box([
              Row(children: [
                Expanded(
                    child: Text(
                        when == null ? d : DateFormat('EEE d MMM').format(when),
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13))),
                Text('$sum calls',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13)),
              ]),
              const SizedBox(height: 2),
              Text(parts.map((e) => '${e.key} ${e.value}').join('  ·  '),
                  style: const TextStyle(
                      fontSize: 12, color: Brand.inkSecondary)),
            ]),
          );
        }),
    ];
  }

  Widget _box(List<Widget> children) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Brand.border),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}
