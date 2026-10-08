import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Sequences (migration 167): emails that go by themselves, step by
/// step. Jonathan, 8 Oct 2026: "clearly illustrate it within the Nomad
/// Maps admin area ... know exactly what spaces are included in
/// sequencing and what the sequencing route is and also for the
/// ability for us to switch that off ... either all together or for
/// each individual email or listing".
///
/// For each sequence: a switch for the whole of it, who it is for and
/// when it runs, the route (each email with its own switch and its
/// words), and every space it has to do with: where each stands, with
/// a switch to take that space out.
class AdminSequencesScreen extends StatefulWidget {
  const AdminSequencesScreen({super.key});

  @override
  State<AdminSequencesScreen> createState() => _AdminSequencesScreenState();
}

class _AdminSequencesScreenState extends State<AdminSequencesScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>> _sequences = const [];
  bool _loading = true;
  String? _error;
  // a switch being changed: no second press until it is done
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _supabase.adminSequences();
      if (!mounted) return;
      setState(() {
        _sequences = rows;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the sequences. $e';
      });
    }
  }

  Future<void> _change(String busyKey, Future<void> Function() call,
      String done) async {
    if (_busy.contains(busyKey)) return;
    setState(() => _busy.add(busyKey));
    try {
      await call();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('That did not save. $e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(busyKey));
    }
  }

  static DateTime? _date(dynamic v) =>
      v == null ? null : DateTime.tryParse('$v')?.toLocal();

  static String _day(dynamic v) {
    final d = _date(v);
    if (d == null) return '';
    final now = DateTime.now();
    return DateFormat(d.year == now.year ? 'EEE d MMM' : 'd MMM y').format(d);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(
        title: const Text('Sequences'),
        actions: [
          IconButton(
              tooltip: 'Look again',
              onPressed: _load,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Brand.red))))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                      children: [
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 860),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Text(
                                      'Emails that go by themselves, one step '
                                      'after another. Each can be switched off '
                                      'as a whole, email by email, or for a '
                                      'single space.',
                                      style: TextStyle(
                                          fontSize: 13.5,
                                          height: 1.45,
                                          color: Brand.inkSecondary)),
                                  const SizedBox(height: 16),
                                  for (final s in _sequences) _sequence(s),
                                ]),
                          ),
                        ),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Brand.border),
        ),
        child: child,
      );

  Widget _heading(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 10, 2, 8),
        child: Text(t,
            style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
                color: Brand.inkMuted)),
      );

  Widget _sequence(Map<String, dynamic> s) {
    final key = '${s['key']}';
    final on = s['enabled'] == true;
    final steps = [
      for (final x in (s['steps'] as List? ?? const []))
        if (x is Map) Map<String, dynamic>.from(x)
    ];
    final spaces = [
      for (final x in (s['spaces'] as List? ?? const []))
        if (x is Map) Map<String, dynamic>.from(x)
    ];
    final active = spaces
        .where((x) => x['status'] == 'due' || x['status'] == 'waiting')
        .toList();
    final rest = spaces
        .where((x) => x['status'] != 'due' && x['status'] != 'waiting')
        .toList();
    final changed = s['updated_by'] != null
        ? 'Last switched by ${s['updated_by']} on ${_day(s['updated_at'])}.'
        : null;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(Icons.timeline_outlined,
                color: on ? Brand.logoNavy : Brand.inkMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Text('${s['name'] ?? key}',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w800)),
            ),
            Text(on ? 'On' : 'Off',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: on ? Brand.success : Brand.inkMuted)),
            const SizedBox(width: 6),
            Switch(
              value: on,
              onChanged: _busy.contains('seq:$key')
                  ? null
                  : (v) => _change(
                      'seq:$key',
                      () => _supabase.adminSequenceSet(key, null, v),
                      v
                          ? 'Sequence switched on.'
                          : 'Sequence switched off: nothing is sent.'),
            ),
          ]),
          if (!on)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: Brand.goldTint,
                  borderRadius: BorderRadius.circular(10)),
              child: const Text(
                  'Switched off: no email of this sequence is sent until it '
                  'is switched on again.',
                  style: TextStyle(
                      fontSize: 13, color: Brand.goldTextDark, height: 1.4)),
            ),
          const SizedBox(height: 10),
          _line(Icons.group_outlined, 'Who', '${s['who'] ?? ''}'),
          _line(Icons.schedule_outlined, 'When', '${s['when'] ?? ''}'),
          _line(Icons.logout_outlined, 'Leaves', '${s['leaves'] ?? ''}'),
          if (changed != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(changed,
                  style: const TextStyle(
                      fontSize: 12, color: Brand.inkMuted)),
            ),
        ]),
      ),
      _heading('THE ROUTE'),
      _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _routeStop(
              icon: Icons.flag_outlined,
              title: 'Claimed and approved',
              text: 'The owner claimed the page themselves and the claim '
                  'was approved.',
              last: false),
          for (var i = 0; i < steps.length; i++)
            _routeEmail(key, steps[i], on, last: false),
          _routeStop(
              icon: Icons.check_circle_outline,
              title: 'Out of the sequence',
              text: 'When they sign in to their Owner account, when it is '
                  'switched off for their space, when they unsubscribe, or '
                  'after the last email.',
              last: true),
        ]),
      ),
      _heading('SPACES IN THE SEQUENCE (${active.length})'),
      if (active.isEmpty)
        _card(
            child: const Text(
                'No space is waiting for an email right now.',
                style: TextStyle(color: Brand.inkSecondary))),
      for (final x in active) _space(key, x, on),
      if (rest.isNotEmpty) ...[
        _heading('LEFT OR SWITCHED OFF (${rest.length})'),
        for (final x in rest) _space(key, x, on),
      ],
      const SizedBox(height: 18),
    ]);
  }

  Widget _line(IconData icon, String label, String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 17, color: Brand.inkSecondary),
          const SizedBox(width: 8),
          SizedBox(
              width: 58,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700))),
          Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: Brand.inkSecondary))),
        ]),
      );

  // One stop of the route, with the line down to the next.
  Widget _routeStop(
      {required IconData icon,
      required String title,
      required String text,
      required bool last,
      Widget? trailing,
      Widget? below,
      bool dim = false}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
              color: dim ? Brand.field : Brand.successTint,
              shape: BoxShape.circle),
          child: Icon(icon,
              size: 17, color: dim ? Brand.inkMuted : Brand.logoNavy),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(title,
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14.5,
                              color: dim ? Brand.inkMuted : Brand.ink)),
                    ),
                    if (trailing != null) trailing,
                  ]),
                  const SizedBox(height: 2),
                  Text(text,
                      style: const TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: Brand.inkSecondary)),
                  if (below != null) below,
                ]),
          ),
        ),
      ]),
      // the line down to the next stop
      if (!last)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 0, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(width: 2, height: 18, color: Brand.hairline),
          ),
        ),
    ]);
  }

  Widget _routeEmail(String key, Map<String, dynamic> st, bool seqOn,
      {required bool last}) {
    final step = (st['step'] as num?)?.toInt() ?? 0;
    final on = st['enabled'] == true;
    final sent = (st['sent'] as num?)?.toInt() ?? 0;
    final busyKey = 'step:$key:$step';
    return _routeStop(
      icon: Icons.mail_outline,
      title: 'Email $step: ${st['subject'] ?? ''}',
      text: '${st['when'] ?? ''}. '
          '${sent == 0 ? 'Not sent to anyone yet.' : 'Sent $sent ${sent == 1 ? 'time' : 'times'} so far.'}'
          '${on ? '' : ' Switched off: nobody gets this email.'}',
      last: last,
      dim: !on || !seqOn,
      trailing: Switch(
        value: on,
        onChanged: _busy.contains(busyKey)
            ? null
            : (v) => _change(
                busyKey,
                () => _supabase.adminSequenceSet(key, step, v),
                v ? 'Email $step switched on.' : 'Email $step switched off.'),
      ),
      below: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Read the email',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Brand.logoNavy)),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Brand.field,
                  borderRadius: BorderRadius.circular(10)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Subject: ${st['subject'] ?? ''}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13)),
                    const SizedBox(height: 8),
                    SelectableText('${st['body'] ?? ''}',
                        style: const TextStyle(fontSize: 13, height: 1.45)),
                    const SizedBox(height: 8),
                    Text('Button: ${st['button'] ?? ''}',
                        style: const TextStyle(
                            fontSize: 12.5, color: Brand.inkSecondary)),
                    const SizedBox(height: 4),
                    const Text(
                        'The words in braces are filled in for each space.',
                        style:
                            TextStyle(fontSize: 12, color: Brand.inkMuted)),
                  ]),
            ),
          ],
        ),
      ),
    );
  }

  // Where one space stands, in words.
  String _where(Map<String, dynamic> x, bool seqOn) {
    final s1 = x['sent_1'];
    final s2 = x['sent_2'];
    final sent = [
      if (s1 != null) 'Email 1 sent ${_day(s1)}',
      if (s2 != null) 'Email 2 sent ${_day(s2)}',
    ].join(' · ');
    final next = x['next_step'] == null
        ? ''
        : 'Email ${x['next_step']} ${x['status'] == 'due' ? 'goes at the next daily run' : 'on ${_day(x['next_at'])}'}';
    final what = switch ('${x['status']}') {
      'due' || 'waiting' =>
        seqOn ? next : '$next (the sequence is switched off)',
      'signed_in' =>
        'Has been into the Owner account${x['signed_in_at'] != null ? ' (${_day(x['signed_in_at'])})' : ''}: out of the sequence',
      'off' => 'Switched off for this space',
      'unsubscribed' => 'Unsubscribed: nothing is sent',
      'done' => 'Finished',
      _ => 'No email of the sequence is switched on',
    };
    return [if (sent.isNotEmpty) sent, what].join(' · ');
  }

  Widget _space(String key, Map<String, dynamic> x, bool seqOn) {
    final status = '${x['status']}';
    final vid = '${x['venue_id']}';
    final place = [
      if ('${x['city'] ?? ''}'.isNotEmpty) '${x['city']}',
      if ('${x['country'] ?? ''}'.isNotEmpty) '${x['country']}',
    ].join(', ');
    final owner = [
      if ('${x['owner_name'] ?? ''}'.trim().isNotEmpty)
        '${x['owner_name']}'.trim(),
      if ('${x['owner_email'] ?? ''}'.isNotEmpty) '${x['owner_email']}',
    ].join(' · ');
    final canSwitch = status == 'due' || status == 'waiting' || status == 'off';
    final included = status != 'off';
    final busyKey = 'space:$key:$vid';
    final colour = switch (status) {
      'due' => Brand.red,
      'waiting' => Brand.logoNavy,
      'signed_in' => Brand.success,
      _ => Brand.inkMuted,
    };
    return _card(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${x['name'] ?? 'A space'}',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 2),
            Text(
                [
                  if (owner.isNotEmpty) owner,
                  if (place.isNotEmpty) place,
                ].join(' · '),
                style: const TextStyle(
                    fontSize: 12.5, color: Brand.inkSecondary)),
            const SizedBox(height: 2),
            Text('Claimed ${_day(x['claimed_at'])}',
                style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
            const SizedBox(height: 6),
            Text(_where(x, seqOn),
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colour)),
          ]),
        ),
        if (canSwitch)
          Column(children: [
            Switch(
              value: included,
              onChanged: _busy.contains(busyKey)
                  ? null
                  : (v) => _change(
                      busyKey,
                      () => _supabase.adminSequenceExclude(key, vid, !v),
                      v
                          ? '${x['name']} is back in the sequence.'
                          : '${x['name']} is out of the sequence.'),
            ),
            Text(included ? 'Included' : 'Off',
                style: const TextStyle(
                    fontSize: 11.5, color: Brand.inkMuted)),
          ]),
      ]),
    );
  }
}
