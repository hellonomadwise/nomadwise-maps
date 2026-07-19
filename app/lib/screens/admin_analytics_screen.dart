import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// Admin only: who has been in the app (signed in or not) and what
/// they did, from the events the app records about itself.
class AdminAnalyticsScreen extends StatefulWidget {
  const AdminAnalyticsScreen({super.key});
  @override
  State<AdminAnalyticsScreen> createState() =>
      _AdminAnalyticsScreenState();
}

class _AdminAnalyticsScreenState extends State<AdminAnalyticsScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _events;
  Map<String, String> _names = {};

  static const _friendly = {
    'app_opened': 'Opened the app',
    'venue_viewed': 'Viewed a space',
    'area_searched': 'Searched an area',
    'screening_opened': 'Started screening a space',
    'global_search_used': 'Used global search',
    'directions_clicked': 'Opened directions',
    'signed_in': 'Signed in',
    'signed_out': 'Signed out',
    'submission_sent': 'Sent a submission',
    'wifi_test_measured': 'Measured wifi',
    'wallet_viewed': 'Opened the wallet',
    'leaderboard_viewed': 'Opened the leaderboard',
    'space_shared': 'Shared a space',
    'intro_shown': 'Saw the intro',
    'intro_completed': 'Finished the intro',
    'intro_skipped': 'Skipped the intro',
    'feedback_sent': 'Sent feedback',
    'add_to_home_opened': 'Opened Add to Home Screen',
    'coins_converted': 'Converted coins to euros',
    'cashout_requested': 'Tapped cash out',
    'avatar_updated': 'Changed profile photo',
    'nickname_set': 'Set a nickname',
    'anon_finds_claimed': 'Claimed their discoveries',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final events = await _supabase.adminEvents();
    final ids = events
        .map((e) => e['user_id'] as String?)
        .whereType<String>()
        .toSet()
        .toList();
    final names = await _supabase.displayNamesFor(ids);
    if (mounted) {
      setState(() {
        _events = events;
        _names = names;
      });
    }
  }

  String _label(String name) => _friendly[name] ?? name;

  String _ago(String? iso) {
    final t = DateTime.tryParse(iso ?? '');
    if (t == null) return '';
    final d = DateTime.now().toUtc().difference(t.toUtc());
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final events = _events;
    return Scaffold(
      appBar: AppBar(title: const Text('Analytics')),
      body: events == null
          ? const Center(
              child: CircularProgressIndicator(color: Brand.accent))
          : RefreshIndicator(
              onRefresh: _load,
              child: events.isEmpty
                  ? ListView(children: const [
                      Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                            'No activity recorded yet. Events start '
                            'collecting from the moment this feature '
                            'went live; PostHog holds the history from '
                            'before.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Brand.inkMuted)),
                      ),
                    ])
                  : _body(events),
            ),
    );
  }

  Widget _body(List<Map<String, dynamic>> events) {
    final now = DateTime.now().toUtc();
    final visitors = <String, List<Map<String, dynamic>>>{};
    for (final e in events) {
      visitors.putIfAbsent(e['anon_id'] as String, () => []).add(e);
    }
    final today = events.where((e) {
      final t = DateTime.tryParse(e['created_at'] ?? '');
      return t != null && now.difference(t.toUtc()).inHours < 24;
    });
    final visitorsToday =
        today.map((e) => e['anon_id']).toSet().length;
    final opens =
        events.where((e) => e['name'] == 'app_opened').length;
    final signedVisitors = visitors.values
        .where((list) => list.any((e) => e['user_id'] != null))
        .length;

    final counts = <String, int>{};
    for (final e in events) {
      counts[e['name'] as String] =
          (counts[e['name']] ?? 0) + 1;
    }
    final topActions = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxCount =
        topActions.isEmpty ? 1 : topActions.first.value;

    final visitorList = visitors.entries.toList()
      ..sort((a, b) => (b.value.first['created_at'] as String)
          .compareTo(a.value.first['created_at'] as String));

    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Row(children: [
            _tile('${visitors.length}', 'Visitors · 7d'),
            const SizedBox(width: 10),
            _tile('$visitorsToday', 'Visitors · 24h'),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _tile('$opens', 'App opens · 7d'),
            const SizedBox(width: 10),
            _tile(
                '$signedVisitors of ${visitors.length}',
                'Signed in'),
          ]),
          const SizedBox(height: 22),
          const SectionLabel('WHAT PEOPLE DO'),
          const SizedBox(height: 10),
          ...topActions.take(8).map((a) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  SizedBox(
                    width: 180,
                    child: Text(_label(a.key),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: a.value / maxCount,
                        minHeight: 8,
                        backgroundColor: Brand.field,
                        color: Brand.gold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('${a.value}',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ]),
              )),
          const SizedBox(height: 22),
          const SectionLabel('VISITORS'),
          const SizedBox(height: 6),
          ...visitorList.map((v) => _visitorRow(v.key, v.value)),
        ]);
  }

  Widget _tile(String value, String label) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: Brand.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Brand.border),
          ),
          child: Column(children: [
            Text(value,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(
                    fontSize: 11.5, color: Brand.inkMuted)),
          ]),
        ),
      );

  (String, bool) _who(List<Map<String, dynamic>> trail) {
    for (final e in trail) {
      final uid = e['user_id'] as String?;
      if (uid != null) return (_names[uid] ?? 'Nomad', true);
    }
    final anon = trail.first['anon_id'] as String;
    final short = anon.length > 6
        ? anon.substring(anon.length - 6)
        : anon;
    return ('Visitor $short', false);
  }

  Widget _visitorRow(
      String anonId, List<Map<String, dynamic>> trail) {
    final (name, signedIn) = _who(trail);
    return InkWell(
      onTap: () => _showTrail(name, trail),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          NomadAvatar(name: name, radius: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600)),
                  Text(
                      '${trail.length} action'
                      '${trail.length == 1 ? '' : 's'} · '
                      'last ${_ago(trail.first['created_at'])}'
                      '${signedIn ? '' : ' · not signed in'}',
                      style: const TextStyle(
                          fontSize: 12, color: Brand.inkMuted)),
                ]),
          ),
          const Icon(Icons.chevron_right,
              size: 18, color: Brand.inkFaint),
        ]),
      ),
    );
  }

  void _showTrail(String name, List<Map<String, dynamic>> trail) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Brand.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .6,
        maxChildSize: .92,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 30),
          children: [
            Text(name,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            ...trail.take(60).map((e) {
              final props =
                  Map<String, dynamic>.from(e['props'] ?? {});
              final detail = [
                if (props['venue'] != null) props['venue'],
                if (props['place'] != null) props['place'],
                if (props['query'] != null) '"${props['query']}"',
                if (props['kind'] != null) props['kind'],
                if (props['mbps'] != null) '${props['mbps']} Mbps',
              ].join(' · ');
              final t =
                  DateTime.tryParse(e['created_at'] ?? '');
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(_label(e['name'] as String),
                                  style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight:
                                          FontWeight.w600)),
                              if (detail.isNotEmpty)
                                Text(detail,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color:
                                            Brand.inkSecondary)),
                            ]),
                      ),
                      Text(
                          t == null
                              ? ''
                              : DateFormat('d MMM HH:mm')
                                  .format(t.toLocal()),
                          style: const TextStyle(
                              fontSize: 11.5,
                              color: Brand.inkMuted)),
                    ]),
              );
            }),
          ],
        ),
      ),
    );
  }
}
