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
  Map<String, dynamic>? _economy;
  List<Map<String, dynamic>> _activity = [];
  Set<String> _internalUserIds = {};
  Set<String> _friendUserIds = {};
  Set<String> _friendAnonView = {};
  int _excludedVisitors = 0;
  int _segment = 0; // 0 everyone · 1 friends · 2 customers

  /// Fallback team list (the Group setting on each account is the
  /// living source; these emails are always team regardless).
  static const _excludedEmails = {
    'hellonomadwise@gmail.com',
    'leonie.poelking@googlemail.com',
    'jonnythebackpacker@gmail.com',
    'corneliousbeck@gmail.com',
  };

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
    final events = await _supabase.adminEvents(days: 14);
    final ids = events
        .map((e) => e['user_id'] as String?)
        .whereType<String>()
        .toSet()
        .toList();
    final names = await _supabase.displayNamesFor(ids);
    final economy = await _supabase.adminEconomy();
    final activity = await _supabase.liveActivity();
    final allUsers = await _supabase.adminUsers();
    final cohorts = await _supabase.profileCohorts();
    final internal = allUsers
        .where((u) => _excludedEmails
            .contains((u['email'] ?? '').toString().toLowerCase()))
        .map((u) => u['id'] as String)
        .toSet();
    cohorts.forEach((id, c) {
      if (c == 'team') internal.add(id);
    });
    final friends = cohorts.entries
        .where((e) => e.value == 'friend')
        .map((e) => e.key)
        .toSet();
    if (mounted) {
      setState(() {
        _events = events;
        _names = names;
        _economy = economy;
        _activity = activity;
        _internalUserIds = internal;
        _friendUserIds = friends;
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

  Widget _body(List<Map<String, dynamic>> allEvents) {
    final now = DateTime.now().toUtc();

    // Devices used by team accounts drop out of all the numbers.
    final internalAnon = allEvents
        .where((e) => _internalUserIds.contains(e['user_id']))
        .map((e) => e['anon_id'] as String)
        .toSet();
    _excludedVisitors = internalAnon.length;
    // Devices used by accounts marked as friends.
    final friendAnon = allEvents
        .where((e) => _friendUserIds.contains(e['user_id']))
        .map((e) => e['anon_id'] as String)
        .toSet()
      ..removeAll(internalAnon);
    _friendAnonView = friendAnon;
    final events = allEvents.where((e) {
      final anon = e['anon_id'] as String;
      if (internalAnon.contains(anon)) return false;
      if (_segment == 1) return friendAnon.contains(anon);
      if (_segment == 2) return !friendAnon.contains(anon);
      return true;
    }).toList();

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

    // ---- daily trend (14 days) + returning visitors ----
    final dayVisitors = <String, Set<String>>{};
    final visitorDays = <String, Set<String>>{};
    for (final e in events) {
      final t = DateTime.tryParse(e['created_at'] ?? '');
      if (t == null) continue;
      final day = DateFormat('yyyy-MM-dd').format(t.toLocal());
      dayVisitors.putIfAbsent(day, () => {}).add(e['anon_id']);
      visitorDays
          .putIfAbsent(e['anon_id'] as String, () => {})
          .add(day);
    }
    final days = List.generate(14, (i) {
      final d = DateTime.now().subtract(Duration(days: 13 - i));
      return DateFormat('yyyy-MM-dd').format(d);
    });
    final dayCounts =
        days.map((d) => dayVisitors[d]?.length ?? 0).toList();
    final maxDay =
        dayCounts.fold<int>(1, (a, b) => b > a ? b : a);
    final returning =
        visitorDays.values.where((s) => s.length >= 2).length;

    // ---- funnel: unique visitors reaching each step ----
    Set<String> whoDid(bool Function(Map<String, dynamic>) test) =>
        events.where(test).map((e) => e['anon_id'] as String).toSet();
    final fVisited = visitors.length;
    final fViewed = whoDid((e) => e['name'] == 'venue_viewed').length;
    final fSigned = visitors.entries
        .where((v) => v.value.any((e) => e['user_id'] != null))
        .length;
    final fSubmitted =
        whoDid((e) => e['name'] == 'submission_sent').length;

    // ---- top spaces (views + shares from events) ----
    final views = <String, int>{};
    final shares = <String, int>{};
    for (final e in events) {
      final venue = (e['props'] is Map)
          ? (e['props']['venue'] as String?)
          : null;
      if (venue == null) continue;
      if (e['name'] == 'venue_viewed') {
        views[venue] = (views[venue] ?? 0) + 1;
      }
      if (e['name'] == 'space_shared') {
        shares[venue] = (shares[venue] ?? 0) + 1;
      }
    }
    final topSpaces = views.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // ---- active cities (verified contributions) ----
    // Team contributions never count; friends follow the switcher.
    final cityCounts = <String, int>{};
    for (final a in _activity) {
      final uid = a['user_id'] as String?;
      if (_internalUserIds.contains(uid)) continue;
      final isFriend = _friendUserIds.contains(uid);
      if (_segment == 1 && !isFriend) continue;
      if (_segment == 2 && isFriend) continue;
      final city = a['city'] as String?;
      if (city != null) {
        cityCounts[city] = (cityCounts[city] ?? 0) + 1;
      }
    }
    final topCities = cityCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // The economy comes per group (migration 22). Before that
    // migration runs the old flat shape arrives; use it as-is.
    final ecoRaw = _economy;
    final segKey = _segment == 1
        ? 'friend'
        : _segment == 2
            ? 'customer'
            : 'all';
    final eco = ecoRaw == null
        ? null
        : ecoRaw.containsKey('all')
            ? (ecoRaw[segKey] is Map
                ? Map<String, dynamic>.from(ecoRaw[segKey])
                : null)
            : ecoRaw;
    final liabilityCents = eco == null
        ? 0
        : ((eco['coins_withdrawable'] as num? ?? 0).toInt() +
            (eco['euro_cents'] as num? ?? 0).toInt());

    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _audienceTabs(),
          const SizedBox(height: 14),
          Row(children: [
            _tile('${visitors.length}', 'Visitors · 14d'),
            const SizedBox(width: 10),
            _tile('$visitorsToday', 'Visitors · 24h'),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _tile('$opens', 'App opens · 14d'),
            const SizedBox(width: 10),
            _tile(
                '$signedVisitors of ${visitors.length}',
                'Signed in'),
          ]),
          const SizedBox(height: 22),

          const SectionLabel('DAILY VISITORS'),
          const SizedBox(height: 12),
          SizedBox(
            height: 70,
            child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < days.length; i++) ...[
                    Expanded(
                      child: Container(
                        height: dayCounts[i] == 0
                            ? 3
                            : 8 + 58 * dayCounts[i] / maxDay,
                        decoration: BoxDecoration(
                            color: dayCounts[i] == 0
                                ? Brand.field
                                : Brand.gold,
                            borderRadius: BorderRadius.circular(3)),
                      ),
                    ),
                    if (i != days.length - 1)
                      const SizedBox(width: 4),
                  ],
                ]),
          ),
          const SizedBox(height: 6),
          const Row(children: [
            Text('2 weeks ago',
                style: TextStyle(
                    fontSize: 11, color: Brand.inkFaint)),
            Spacer(),
            Text('today',
                style: TextStyle(
                    fontSize: 11, color: Brand.inkFaint)),
          ]),
          const SizedBox(height: 6),
          Text(
              '$returning visitor${returning == 1 ? '' : 's'} came '
              'back on more than one day',
              style: const TextStyle(
                  fontSize: 12.5, color: Brand.inkSecondary)),
          const SizedBox(height: 22),

          const SectionLabel('THE FUNNEL'),
          const SizedBox(height: 10),
          _funnelRow('Visited', fVisited, fVisited),
          _funnelRow('Viewed a space', fViewed, fVisited),
          _funnelRow('Signed in', fSigned, fVisited),
          _funnelRow('Sent a submission', fSubmitted, fVisited),
          const SizedBox(height: 22),

          if (topSpaces.isNotEmpty) ...[
            const SectionLabel('TOP SPACES'),
            const SizedBox(height: 8),
            ...topSpaces.take(5).map((s) => Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    Expanded(
                      child: Text(s.key,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600)),
                    ),
                    Text(
                        '${s.value} view${s.value == 1 ? '' : 's'}'
                        '${(shares[s.key] ?? 0) > 0 ? ' · ${shares[s.key]} shared' : ''}',
                        style: const TextStyle(
                            fontSize: 12.5,
                            color: Brand.inkSecondary)),
                  ]),
                )),
            const SizedBox(height: 22),
          ],

          if (topCities.isNotEmpty) ...[
            const SectionLabel('ACTIVE CITIES'),
            const SizedBox(height: 8),
            ...topCities.take(5).map((cEntry) => Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    const Icon(Icons.location_on,
                        size: 15, color: Brand.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(cEntry.key,
                          style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600)),
                    ),
                    Text(
                        '${cEntry.value} contribution'
                        '${cEntry.value == 1 ? '' : 's'}',
                        style: const TextStyle(
                            fontSize: 12.5,
                            color: Brand.inkSecondary)),
                  ]),
                )),
            const SizedBox(height: 22),
          ],

          if (eco != null) ...[
            const SectionLabel('COIN ECONOMY'),
            const SizedBox(height: 10),
            Row(children: [
              _tile('${eco['coins_withdrawable']}',
                  'Coins in circulation'),
              const SizedBox(width: 10),
              _tile('${eco['coins_pending']}', 'Coins pending'),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              _tile(
                  '€${((eco['euro_cents'] as num? ?? 0) / 100).toStringAsFixed(2)}',
                  'Converted to euros'),
              const SizedBox(width: 10),
              _tile(
                  '€${(liabilityCents / 100).toStringAsFixed(2)}',
                  'Payout liability'),
            ]),
            const SizedBox(height: 22),
          ],

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
          if (visitorList.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                  'No outside visitors yet. Share the link and watch '
                  'this fill up.',
                  style: TextStyle(
                      fontSize: 13, color: Brand.inkMuted)),
            )
          else
            ...visitorList.map((v) => _visitorRow(v.key, v.value)),
          if (_excludedVisitors > 0 || _segment != 0) ...[
            const SizedBox(height: 14),
            Text(
                [
                  if (_excludedVisitors > 0)
                    'Excluding $_excludedVisitors team '
                        'device${_excludedVisitors == 1 ? '' : 's'} '
                        '(your own accounts).',
                  if (_segment == 1)
                    'Showing friends only. Mark accounts as '
                        'friends in Users.',
                  if (_segment == 2)
                    'Showing customers only (friend devices '
                        'hidden).',
                ].join(' '),
                style: const TextStyle(
                    fontSize: 11.5, color: Brand.inkFaint)),
          ],
        ]);
  }

  Widget _audienceTabs() {
    Widget seg(int index, String label) {
      final active = _segment == index;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _segment = index),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: active ? Brand.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              boxShadow: active
                  ? [
                      BoxShadow(
                          color: Colors.black.withOpacity(.06),
                          blurRadius: 6,
                          offset: const Offset(0, 1))
                    ]
                  : null,
            ),
            child: Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight:
                        active ? FontWeight.w700 : FontWeight.w600,
                    color: active ? Brand.ink : Brand.inkMuted)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Brand.field,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        seg(0, 'Everyone'),
        seg(1, 'Friends'),
        seg(2, 'Customers'),
      ]),
    );
  }

  Widget _funnelRow(String label, int value, int base) {
    final pct = base == 0 ? 0 : (value / base * 100).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        SizedBox(
          width: 150,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: base == 0 ? 0 : value / base,
              minHeight: 10,
              backgroundColor: Brand.field,
              color: Brand.accent,
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 74,
          child: Text('$value · $pct%',
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
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
    final isFriend = _friendAnonView.contains(anonId);
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
                  Row(children: [
                    Flexible(
                      child: Text(name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600)),
                    ),
                    if (isFriend) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: Brand.goldTint,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text('Friend',
                            style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: Brand.goldTextDark)),
                      ),
                    ],
                  ]),
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
