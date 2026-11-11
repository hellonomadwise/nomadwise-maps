import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Owners, in the control centre: claims that were approved by
/// themselves (migration 312), and the switch for it.
///
/// Jonathan, 11 Nov 2026, after approving Olga (olga@stonesoup.io) for
/// Stone Soup by hand: "for situations where a person signing up is
/// doing so with an email address that is linked to the space ... if
/// that situation can be auto approved?" A claim whose email is on the
/// space's own website address is now approved the moment it is made.
/// Nothing about it is silent: a phone ping says why, and the last ones
/// are listed here with the reason.
class ClaimAutoCard extends StatefulWidget {
  final SupabaseService supabase;

  /// Opens the space a claim was for.
  final void Function(String venueId)? onOpenVenue;

  const ClaimAutoCard({super.key, required this.supabase, this.onOpenVenue});

  @override
  State<ClaimAutoCard> createState() => _ClaimAutoCardState();
}

class _ClaimAutoCardState extends State<ClaimAutoCard> {
  bool? _on; // null until loaded
  bool _saving = false;
  int _total = 0;
  List<Map<String, dynamic>> _recent = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.supabase.claimAuto();
    if (!mounted || r == null) return;
    setState(() {
      _on = r['on'] != false;
      _total = (r['total'] as num?)?.toInt() ?? 0;
      _recent = [
        for (final x in (r['recent'] as List?) ?? const [])
          if (x is Map) Map<String, dynamic>.from(x)
      ];
    });
  }

  Future<void> _set(bool on) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _on = on;
    });
    try {
      await widget.supabase.claimAutoSet(on);
    } catch (e) {
      if (!mounted) return;
      setState(() => _on = !on);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('That did not save: $e'),
          backgroundColor: Brand.red));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _s(Object? v) => (v ?? '').toString().trim();

  @override
  Widget build(BuildContext context) {
    final on = _on;
    // Not loaded (or the database is older than the app): show nothing.
    if (on == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 6, right: 12),
            child: Icon(Icons.verified_user_outlined, color: Brand.accent),
          ),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('Claims approved by themselves',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                  ),
                  const SizedBox(height: 3),
                  Text(
                      on
                          ? 'When someone claims a page that is live with an '
                              'email on that space\'s own website address '
                              '(olga@stonesoup.io for stonesoup.io), it is '
                              'approved at once and you get a phone ping. '
                              'Gmail and other addresses still wait for you.'
                          : 'Off: every claim waits for you, whatever the '
                              'email address.',
                      style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: Brand.inkSecondary)),
                ]),
          ),
          Switch(
              value: on,
              activeColor: Brand.success,
              onChanged: _saving ? null : _set),
        ]),
        if (_recent.isNotEmpty) ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: Text(
                _total > _recent.length
                    ? 'THE LAST ${_recent.length} OF $_total'
                    : 'SO FAR  ·  $_total',
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .8,
                    color: Brand.inkMuted)),
          ),
          for (final c in _recent) _row(c),
          const Padding(
            padding: EdgeInsets.fromLTRB(36, 6, 6, 0),
            child: Text(
                'Looks wrong? Open the space and take the owner off. That '
                'person is then never approved by itself again for that page.',
                style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
          ),
        ],
      ]),
    );
  }

  Widget _row(Map<String, dynamic> c) {
    final at = DateTime.tryParse(_s(c['at']))?.toLocal();
    final venueId = _s(c['venue_id']);
    final gone = _s(c['status']) == 'abandoned';
    final who = [_s(c['owner_name']), _s(c['owner_email'])]
        .where((x) => x.isNotEmpty)
        .join('  ·  ');
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(36, 8, 6, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            [
              _s(c['space']).isEmpty ? 'A space' : _s(c['space']),
              if (_s(c['plan']) == 'verified') 'Premium',
              if (at != null) DateFormat('d MMM, HH:mm').format(at),
              if (gone) 'owner taken off since',
            ].join('  ·  '),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        if (who.isNotEmpty)
          Text(who, style: const TextStyle(fontSize: 12.5)),
        if (_s(c['why']).isNotEmpty)
          Text(_s(c['why']),
              style: const TextStyle(fontSize: 12, color: Brand.success)),
      ]),
    );
    if (venueId.isEmpty || widget.onOpenVenue == null) return body;
    return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => widget.onOpenVenue!(venueId),
        child: body);
  }
}
