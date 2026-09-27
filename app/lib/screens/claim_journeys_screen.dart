import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Admin only: every visit to the claim page, told as a story.
///
/// One card per opening of nomadmaps.io/?claim: where the visitor came
/// from, how far they got (Find, Space chosen, About you, Plan), how
/// it ended (went to Stripe, claimed free, or left, and on which step
/// after how long), and, opened up, everything they did in order with
/// the seconds since the page opened.
///
/// Built from the claim_* events the claim page records about itself
/// (app_events). Team devices are left out.
class ClaimJourneysScreen extends StatefulWidget {
  const ClaimJourneysScreen({super.key});
  @override
  State<ClaimJourneysScreen> createState() => _ClaimJourneysScreenState();
}

class _Visit {
  final String key;
  final String anon;
  final List<Map<String, dynamic>> events;
  _Visit(this.key, this.anon, this.events);

  DateTime get start =>
      DateTime.tryParse('${events.first['created_at']}')?.toLocal() ??
      DateTime.now();
  DateTime get last =>
      DateTime.tryParse('${events.last['created_at']}')?.toLocal() ??
      start;

  Map<String, dynamic> _props(Map<String, dynamic> e) =>
      (e['props'] is Map) ? Map<String, dynamic>.from(e['props']) : {};

  Map<String, dynamic> get opened => events
      .where((e) => e['name'] == 'claim_opened')
      .map(_props)
      .firstOrNull ??
      {};

  /// Furthest step reached: 0 find, 1 space chosen, 2 about, 3 plan.
  int get furthest {
    var f = 0;
    for (final e in events) {
      final p = _props(e);
      final n = e['name'];
      final step = '${p['to'] ?? p['step'] ?? ''}';
      if (n == 'claim_step' && step == 'about') f = f < 2 ? 2 : f;
      if (n == 'claim_step' && step == 'plan') f = 3;
      if (n == 'claim_to_payment' || n == 'claim_free') f = 3;
      if (n == 'claim_step' && step == 'add_space') f = f < 1 ? 1 : f;
      if (n == 'claim_typed') f = f < 2 ? 2 : f;
    }
    return f;
  }

  String? get space {
    for (final e in events.reversed) {
      final s = '${_props(e)['space'] ?? ''}';
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  /// How it ended, as a sentence, and a colour for the chip.
  (String, Color, Color) get outcome {
    final names = events.map((e) => e['name']).toSet();
    if (names.contains('claim_to_payment')) {
      return ('Chose Verified, went to Stripe', Brand.success, Brand.successTint);
    }
    if (names.contains('claim_free')) {
      return ('Claimed for free', Brand.success, Brand.successTint);
    }
    final left = events.where((e) => e['name'] == 'claim_left').lastOrNull;
    if (left != null) {
      final p = _props(left);
      return (
        'Left on ${_stepLabel('${p['step']}')} after ${_dur(p['secs'])}',
        Brand.goldTextDark,
        Brand.goldTint
      );
    }
    final since = DateTime.now().difference(last);
    if (since.inMinutes < 20) {
      return ('On the page now', Brand.inkSecondary, Brand.field);
    }
    final lastStep = _lastStep;
    return (
      'Stopped on ${_stepLabel(lastStep)}, no leave recorded',
      Brand.goldTextDark,
      Brand.goldTint
    );
  }

  String get _lastStep {
    for (final e in events.reversed) {
      final p = _props(e);
      final s = '${p['to'] ?? p['step'] ?? ''}';
      if (s.isNotEmpty) return s;
    }
    return 'find';
  }

  int get secondsOnPage {
    for (final e in events.reversed) {
      final s = _props(e)['secs'];
      if (s is num) return s.toInt();
    }
    return last.difference(start).inSeconds;
  }
}

String _stepLabel(String s) => switch (s) {
      'find' => 'Find your space',
      'add_space' => 'Add your space',
      'about' => 'About you',
      'plan' => 'the Free or Verified choice',
      _ => s,
    };

String _dur(dynamic secs) {
  final s = secs is num ? secs.toInt() : 0;
  if (s < 60) return '${s}s';
  final m = s ~/ 60;
  final r = s % 60;
  return r == 0 ? '${m}m' : '${m}m ${r}s';
}

String _clock(dynamic secs) {
  final s = secs is num ? secs.toInt() : 0;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:'
      '${(s % 60).toString().padLeft(2, '0')}';
}

class _ClaimJourneysScreenState extends State<ClaimJourneysScreen> {
  final _supabase = SupabaseService();
  List<_Visit>? _visits;
  Map<String, int> _visitsByDevice = {};
  int _days = 30;
  final Set<String> _open = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final events = await _supabase.claimJourneyEvents(days: _days);
    final team = await _supabase.teamDevices();
    final byKey = <String, _Visit>{};
    for (final e in events) {
      final anon = '${e['anon_id']}';
      if (team.contains(anon)) continue;
      final p = (e['props'] is Map) ? e['props'] as Map : const {};
      // Events from before the journey ids: group by device and hour.
      final t = DateTime.tryParse('${e['created_at']}') ?? DateTime.now();
      final key = '${p['visit'] ?? '$anon:${t.year}-${t.month}-${t.day}-${t.hour}'}';
      byKey.putIfAbsent(key, () => _Visit(key, anon, [])).events.add(e);
    }
    final visits = byKey.values.toList()
      ..sort((a, b) => b.start.compareTo(a.start));
    final byDevice = <String, int>{};
    for (final v in visits) {
      byDevice[v.anon] = (byDevice[v.anon] ?? 0) + 1;
    }
    if (mounted) {
      setState(() {
        _visits = visits;
        _visitsByDevice = byDevice;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final visits = _visits;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(
        title: const Text('Claim journeys'),
        actions: [
          PopupMenuButton<int>(
            initialValue: _days,
            onSelected: (d) {
              setState(() {
                _days = d;
                _visits = null;
              });
              _load();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 7, child: Text('Last 7 days')),
              PopupMenuItem(value: 30, child: Text('Last 30 days')),
              PopupMenuItem(value: 90, child: Text('Last 90 days')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                  child: Text('Last $_days days',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13.5))),
            ),
          ),
        ],
      ),
      body: visits == null
          ? const Center(
              child: CircularProgressIndicator(color: Brand.accent))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
                children: [
                  _summary(visits),
                  const SizedBox(height: 14),
                  if (visits.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(28),
                      child: Text(
                          'No visits to the claim page in this period. '
                          'Every opening of nomadmaps.io/?claim shows up '
                          'here within a few seconds.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Brand.inkMuted)),
                    ),
                  ...visits.map(_card),
                ],
              ),
            ),
    );
  }

  // ----------------------------------------------------------- summary

  Widget _summary(List<_Visit> visits) {
    final n = visits.length;
    final chose = visits.where((v) => v.furthest >= 1).length;
    final about = visits.where((v) => v.furthest >= 2).length;
    final plan = visits.where((v) => v.furthest >= 3).length;
    final paid = visits
        .where((v) => v.events.any((e) => e['name'] == 'claim_to_payment'))
        .length;
    final free =
        visits.where((v) => v.events.any((e) => e['name'] == 'claim_free'))
            .length;
    Widget tile(String label, int value) => Expanded(
          child: Column(children: [
            Text('$value',
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 22)),
            Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 11, color: Brand.inkSecondary, height: 1.2)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.border),
      ),
      child: Column(children: [
        const Text('HOW FAR VISITORS GET',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
                color: Brand.inkMuted)),
        const SizedBox(height: 10),
        Row(children: [
          tile('Opened', n),
          tile('Chose a space', chose),
          tile('About you', about),
          tile('Free or Verified', plan),
          tile('To Stripe', paid),
          tile('Free claim', free),
        ]),
      ]),
    );
  }

  // -------------------------------------------------------------- card

  Widget _card(_Visit v) {
    final o = v.opened;
    final from = '${o['from'] ?? ''}';
    final ref = '${o['referrer'] ?? ''}';
    final device = '${o['device'] ?? ''}';
    final seed = '${o['seed'] ?? ''}';
    final whence = from.isNotEmpty
        ? 'from nomadwise.io$from'
        : ref.isNotEmpty
            ? 'from ${ref.replaceFirst(RegExp(r'^https?://(www\.)?'), '').split('/').first}'
            : 'direct, no referrer';
    final (outcome, fg, bg) = v.outcome;
    final open = _open.contains(v.key);
    final repeat = (_visitsByDevice[v.anon] ?? 1) > 1;
    final when = DateFormat('EEE d MMM, HH:mm').format(v.start);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() {
          if (!_open.remove(v.key)) _open.add(v.key);
        }),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(
                  device == 'phone'
                      ? Icons.smartphone
                      : device == 'desktop'
                          ? Icons.laptop_mac
                          : Icons.person_outline,
                  size: 18,
                  color: Brand.inkMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    '$when  ·  ${_dur(v.secondsOnPage)} on the page'
                    '${repeat ? '  ·  came back' : ''}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13.5)),
              ),
              Icon(open ? Icons.expand_less : Icons.expand_more,
                  color: Brand.inkMuted),
            ]),
            const SizedBox(height: 4),
            Text(
                [
                  'Arrived $whence',
                  if (seed.isNotEmpty) 'with "$seed" in the search box',
                  if (v.space != null) 'space: ${v.space}',
                ].join('  ·  '),
                style: const TextStyle(
                    fontSize: 12.5, color: Brand.inkSecondary, height: 1.4)),
            const SizedBox(height: 10),
            _progress(v.furthest),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                  color: bg, borderRadius: BorderRadius.circular(8)),
              child: Text(outcome,
                  style: TextStyle(
                      color: fg, fontWeight: FontWeight.w700, fontSize: 12)),
            ),
            if (open) ...[
              const SizedBox(height: 14),
              const Divider(height: 1, color: Brand.hairline),
              const SizedBox(height: 12),
              ...v.events.map((e) => _line(v, e)),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _progress(int furthest) {
    const labels = ['Find', 'Space chosen', 'About you', 'Free or Verified'];
    return Row(children: [
      for (var i = 0; i < labels.length; i++) ...[
        Expanded(
          child: Column(children: [
            Container(
              height: 5,
              decoration: BoxDecoration(
                color: i <= furthest ? Brand.accent : Brand.field,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 4),
            Text(labels[i],
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: i <= furthest ? FontWeight.w700 : FontWeight.w500,
                    color: i <= furthest ? Brand.ink : Brand.inkMuted)),
          ]),
        ),
        if (i < labels.length - 1) const SizedBox(width: 6),
      ],
    ]);
  }

  // ---------------------------------------------------------- timeline

  Widget _line(_Visit v, Map<String, dynamic> e) {
    final p = (e['props'] is Map)
        ? Map<String, dynamic>.from(e['props'])
        : <String, dynamic>{};
    final text = _sentence('${e['name']}', p);
    if (text == null) return const SizedBox.shrink();
    final t = p['secs'];
    final clock = t is num
        ? _clock(t)
        : DateFormat('HH:mm').format(
            DateTime.tryParse('${e['created_at']}')?.toLocal() ?? v.start);
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 44,
          child: Text(clock,
              style: const TextStyle(
                  fontSize: 12,
                  color: Brand.inkMuted,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ),
        Expanded(
            child: Text(text,
                style: const TextStyle(fontSize: 13, height: 1.4))),
      ]),
    );
  }

  static const _fieldWords = {
    'name': 'their name',
    'role': 'their role',
    'email': 'their email',
    'phone': 'a phone number',
    'enquiry_email': 'where booking requests should go',
    'website': 'their website',
    'instagram': 'their Instagram',
    'note': 'a note to us',
  };

  String? _sentence(String name, Map<String, dynamic> p) {
    final space = '${p['space'] ?? ''}';
    switch (name) {
      case 'claim_opened':
        final seed = '${p['seed'] ?? ''}';
        return seed.isNotEmpty
            ? 'Opened the claim page with "$seed" already in the search box'
            : 'Opened the claim page';
      case 'claim_searched':
        final n = p['results'] ?? 0;
        return 'Searched "${p['q']}": '
            '${n == 0 ? 'nothing found' : '$n result${n == 1 ? '' : 's'}'}';
      case 'claim_place_searched':
        final n = p['results'] ?? 0;
        return 'Searched Google Maps for "${p['q']}": '
            '${n == 0 ? 'no suggestions' : '$n suggestion${n == 1 ? '' : 's'}'}';
      case 'claim_step':
        final how = '${p['how'] ?? ''}';
        final to = '${p['to'] ?? ''}';
        return switch (how) {
          'picked_listed' => 'Chose $space, a page already on nomadwise.io',
          'picked_unpublished' => 'Chose $space, not published yet',
          'link_matched' => 'Landed straight on $space from its page',
          'google_place' => 'Picked $space from Google Maps',
          'not_here' => 'Tapped "My space isn\'t here, add it"',
          'back' => 'Went back to ${_stepLabel(to)}',
          'continue' => 'Filled in About you and continued to the '
              'Free or Verified choice',
          _ => 'Moved to ${_stepLabel(to)}',
        };
      case 'claim_typed':
        return 'Typed ${_fieldWords['${p['field']}'] ?? p['field']}';
      case 'claim_blocked':
        return p['why'] == 'no_name'
            ? 'Tried to continue without a name'
            : 'Tried to continue without an email';
      case 'claim_already_verified':
        return 'Tapped $space, which is already Verified';
      case 'claim_to_payment':
        return 'Chose Verified and went to Stripe to pay for $space';
      case 'claim_free':
        return 'Claimed $space for free';
      case 'claim_failed':
        return 'Something went wrong: ${p['why']}';
      case 'claim_left':
        final filled = (p['filled'] is List)
            ? (p['filled'] as List)
                .map((f) => _fieldWords['$f'] ?? '$f')
                .toList()
            : const <String>[];
        return 'Left the page on ${_stepLabel('${p['step']}')} '
            'after ${_dur(p['secs'])}'
            '${filled.isEmpty ? '' : ', having typed ${filled.join(', ')}'}';
      default:
        return null;
    }
  }
}
