import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Emails (migration 272): every email we send space owners, and what
/// happened after it, opened from the Owner flow.
///
/// Jonathan, 6 Nov 2026: "how many were sent out, split between cafes
/// and coworking spaces, who opened them ... how many people actually
/// used them to create stickiness, and did the tip we mentioned, or led
/// to improving or reviewing their account ... and ultimately leading
/// them towards ... becoming premium."
///
/// One card per email, top to bottom in the order an owner meets them.
/// Each card is a short funnel: sent, opened, clicked, signed in within
/// 7 days, made a change within 14 days, did the tip (monthly email),
/// Premium within 60 days. Tap a step to see who got there and who
/// stopped just before it. Opens are rough (some inboxes hide them,
/// some invent them); clicks from inbox scanners are left out.
class AdminEmailFlowScreen extends StatefulWidget {
  const AdminEmailFlowScreen({super.key});

  @override
  State<AdminEmailFlowScreen> createState() => _AdminEmailFlowScreenState();
}

class _StepDef {
  final String key; // the field on a person that marks the step reached
  final String label;
  final String hint;
  const _StepDef(this.key, this.label, this.hint);
}

const _kSteps = [
  _StepDef('sent_at', 'Sent', 'Every email that went out'),
  _StepDef('opened_at', 'Opened', 'Opened, or clicked a link'),
  _StepDef('clicked_at', 'Clicked', 'Clicked a link (scanners left out)'),
  _StepDef('signed_in_at', 'Signed in', 'In their Owner account within 7 days'),
  _StepDef('acted_at', 'Made a change', 'Sent us an edit within 14 days'),
  _StepDef('tip_done', 'Did the tip', 'Completed the tip the email suggested'),
  _StepDef('premium_on', 'Premium', 'Started paying within 60 days'),
];

class _AdminEmailFlowScreenState extends State<AdminEmailFlowScreen> {
  final _supabase = SupabaseService();
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _data = {};
  int _days = 90; // 30, 90, or 0 for everything
  final Map<String, String> _picked = {}; // email group -> step key

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final from = _days == 0 ? null : DateTime.now().subtract(Duration(days: _days));
      final d = await _supabase.adminEmailFlow(from: from);
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'The email numbers could not be loaded. $e';
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _emails => ((_data['emails'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  static bool _reached(Map p, String key) {
    final v = p[key];
    if (key == 'tip_done') return v == true;
    return v != null;
  }

  static String _day(dynamic iso) {
    if (iso == null) return '';
    final d = DateTime.tryParse('$iso');
    if (d == null) return '';
    return DateFormat('d MMM').format(d.toLocal());
  }

  List<_StepDef> _stepsFor(Map<String, dynamic> e) => _kSteps
      .where((s) => s.key != 'tip_done' || ((e['tip_suggested'] as num?) ?? 0) > 0)
      .toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(
        title: const Text('Emails'),
        actions: [
          IconButton(tooltip: 'Look again', onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Brand.red))))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                      children: [
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 820),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              _intro(),
                              const SizedBox(height: 12),
                              if (_emails.isEmpty)
                                _card(
                                    child: const Text('No emails to owners in this period.',
                                        style: TextStyle(color: Brand.inkSecondary)))
                              else
                                for (final e in _emails) ...[
                                  _emailCard(e),
                                  const SizedBox(height: 12),
                                ],
                            ]),
                          ),
                        ),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _card({required Widget child, EdgeInsets? padding}) => Container(
        padding: padding ?? const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Brand.border),
        ),
        child: child,
      );

  Widget _intro() {
    final lastRead = _day(_data['last_read']);
    final since = _day(_data['tracking_since']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text(
          'Every email we send space owners, and what they did after it. '
          'Tap a step to see who got there and who stopped just before it.',
          style: TextStyle(fontSize: 13.5, color: Brand.inkSecondary, height: 1.4)),
      const SizedBox(height: 4),
      Text(
          'Clicks, sign-ins and changes are the numbers to trust; opens are rough. '
          'Inbox scanners that click every link are left out, and so are our own addresses.'
          '${since.isNotEmpty ? ' Opens and clicks from $since' : ''}${lastRead.isNotEmpty ? ', last read from Postmark ${DateFormat('d MMM, HH:mm').format(DateTime.parse('${_data['last_read']}').toLocal())}.' : '.'}',
          style: const TextStyle(fontSize: 12, color: Brand.inkMuted, height: 1.4)),
      const SizedBox(height: 10),
      Wrap(spacing: 6, children: [
        for (final d in const [30, 90, 0])
          ChoiceChip(
            label: Text(d == 0 ? 'Everything' : 'Last $d days'),
            selected: _days == d,
            onSelected: (_) {
              setState(() => _days = d);
              _load();
            },
          ),
      ]),
    ]);
  }

  Widget _emailCard(Map<String, dynamic> e) {
    final g = '${e['g']}';
    final people = ((e['people'] as List?) ?? const []).whereType<Map>().toList();
    final sent = (e['sent'] as num?)?.toInt() ?? 0;
    final steps = _stepsFor(e);
    final picked = _picked[g];
    final tracked = (e['tracked'] as num?)?.toInt() ?? 0;
    final bounced = (e['bounced'] as num?)?.toInt() ?? 0;
    final counts = {
      for (final s in steps) s.key: people.where((p) => _reached(p, s.key)).length,
    };
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text('${e['label']}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Brand.ink)),
          ),
          Text('last sent ${_day(e['last_sent'])}', style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
        ]),
        const SizedBox(height: 2),
        Text(
            '$sent sent · ${e['cowork'] ?? 0} coworking · ${e['cafe'] ?? 0} café'
            '${bounced > 0 ? ' · $bounced bounced' : ''}'
            // the emails an owner can switch off (monthly, tips): who did
            '${e['can_unsubscribe'] == true ? ' · ${e['unsubscribed'] ?? 0} unsubscribed' : ''}'
            '${tracked < sent ? ' · opens and clicks known for $tracked of $sent (recorded from 5 Nov)' : ''}',
            style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        const SizedBox(height: 12),
        // Opens and clicks exist only for emails sent since Postmark began
        // recording them (5 Nov 2026), so those two rates are out of those.
        for (var i = 0; i < steps.length; i++)
          _stepBar(
              g,
              steps[i],
              counts[steps[i].key] ?? 0,
              _tracking(steps[i].key) ? tracked : sent,
              picked == steps[i].key,
              i == 0 || _tracking(steps[i].key) != _tracking(steps[i - 1].key) ? null : counts[steps[i - 1].key]),
        if (picked != null) ...[
          const SizedBox(height: 8),
          _who(e, people, steps, picked),
        ],
      ]),
    );
  }

  // Under a step: those who got to the step before but not this one.
  static const _notYet = {
    'opened_at': 'not opened yet',
    'clicked_at': 'not clicked yet',
    'signed_in_at': 'not signed in yet',
    'acted_at': 'no change yet',
    'tip_done': 'tip not done yet',
    'premium_on': 'not Premium yet',
  };

  static bool _tracking(String key) => key == 'opened_at' || key == 'clicked_at';

  Widget _stepBar(String g, _StepDef s, int n, int sent, bool on, int? before) {
    final pct = sent == 0 ? 0.0 : n / sent;
    if (_tracking(s.key) && sent == 0) {
      // nothing sent since opens and clicks began to be recorded
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(children: [
          SizedBox(width: 112, child: Text(s.label, style: const TextStyle(fontSize: 13, color: Brand.inkMuted))),
          const Expanded(
              child: Text('not known for these (sent before 5 Nov)',
                  style: TextStyle(fontSize: 12, color: Brand.inkMuted))),
        ]),
      );
    }
    final lost = before == null ? 0 : before - n;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => on ? _picked.remove(g) : _picked[g] = s.key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: on ? Brand.accentTint : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          SizedBox(
            width: 112,
            child: Tooltip(
              message: s.hint,
              child: Text(s.label,
                  style: TextStyle(
                      fontSize: 13, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: Brand.ink)),
            ),
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, c) {
              return Stack(children: [
                Container(
                    height: 18,
                    decoration: BoxDecoration(color: Brand.field, borderRadius: BorderRadius.circular(8))),
                Container(
                    height: 18,
                    width: (c.maxWidth * pct).clamp(n > 0 ? 6.0 : 0.0, c.maxWidth).toDouble(),
                    decoration: BoxDecoration(
                        color: s.key == 'premium_on' ? Brand.gold : Brand.accent.withValues(alpha: on ? 1 : .8),
                        borderRadius: BorderRadius.circular(8))),
              ]);
            }),
          ),
          SizedBox(
            width: 92,
            child: Text(
                s.key == 'sent_at'
                    ? '$n'
                    : _tracking(s.key)
                        ? '$n of $sent'
                        : '$n · ${(pct * 100).round()}%',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Brand.ink)),
          ),
          SizedBox(
            width: 64,
            child: Text(lost > 0 ? '−$lost' : '',
                textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
          ),
        ]),
      ),
    );
  }

  /// Who reached the picked step, and who stopped just before it.
  Widget _who(Map<String, dynamic> e, List<Map> people, List<_StepDef> steps, String key) {
    final i = steps.indexWhere((s) => s.key == key);
    final prev = i <= 0 ? null : steps[i - 1].key;
    final got = people.where((p) => _reached(p, key)).toList();
    final stopped = prev == null ? <Map>[] : people.where((p) => _reached(p, prev) && !_reached(p, key)).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(color: Brand.bg, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${steps[i].label}: ${got.length}',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Brand.ink)),
        if (got.isEmpty)
          const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Nobody yet.', style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary))),
        for (final p in got) _person(p, steps),
        if (prev != null) ...[
          const SizedBox(height: 10),
          Text('${steps[i - 1].label}, ${_notYet[key] ?? 'not yet'}: ${stopped.length}',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Brand.ink)),
          if (stopped.isEmpty)
            const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Nobody.', style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary))),
          for (final p in stopped) _person(p, steps),
        ],
      ]),
    );
  }

  Widget _person(Map p, List<_StepDef> steps) {
    final links = ((p['links'] as List?) ?? const []).map((x) => '$x').where((x) => x != 'stop').toList();
    final bits = <String>[
      'sent ${_day(p['sent_at'])}',
      if (p['opened_at'] != null) 'opened ${_day(p['opened_at'])}',
      if (links.isNotEmpty) 'clicked ${links.join(', ')}',
      if (p['signed_in_at'] != null) 'signed in ${_day(p['signed_in_at'])}',
      if (p['acted_at'] != null) 'sent an edit ${_day(p['acted_at'])}',
      if (p['tip'] != null) 'tip: ${p['tip']}${p['tip_done'] == true ? ' (done)' : ''}',
      if (p['premium_on'] != null) 'Premium from ${_day(p['premium_on'])}',
      if (p['bounced_at'] != null) 'bounced',
      if (p['unsubscribed_at'] != null) 'unsubscribed ${_day(p['unsubscribed_at'])}',
      if (p['tracked'] != true) 'opens and clicks not known',
    ];
    final type = p['type'] == 'cafe' ? 'Café' : 'Coworking';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          margin: const EdgeInsets.only(top: 1, right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
              color: p['type'] == 'cafe' ? Brand.goldTint : Brand.logoTealTint,
              borderRadius: BorderRadius.circular(8)),
          child: Text(type,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: p['type'] == 'cafe' ? Brand.goldTextDark : Brand.logoNavy)),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p['space'] ?? p['email']}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Brand.ink)),
            Text(bits.join(' · '), style: const TextStyle(fontSize: 12, color: Brand.inkSecondary, height: 1.35)),
          ]),
        ),
      ]),
    );
  }
}
