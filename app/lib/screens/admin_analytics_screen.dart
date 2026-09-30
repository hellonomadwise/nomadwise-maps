import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'claim_journeys_screen.dart';
import 'google_usage_screen.dart';

/// Admin only: who has been in the app (signed in or not) and what
/// they did. Since 30 Sep 2026 the counting happens in the database
/// (admin_analytics, migration 109) over every recorded action, for
/// 7, 30 or 90 days, with the period before for comparison. The page
/// used to download at most 2,000 actions and count them here, which
/// quietly undercounted once traffic grew.
class AdminAnalyticsScreen extends StatefulWidget {
  const AdminAnalyticsScreen({super.key});

  @override
  State<AdminAnalyticsScreen> createState() => _AdminAnalyticsScreenState();
}

class _AdminAnalyticsScreenState extends State<AdminAnalyticsScreen> {
  final _supabase = SupabaseService();
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = false;
  int _days = 7;
  int _segment = 0; // 0 everyone · 1 friends · 2 customers · 3 owners

  // Active cities and the coin economy come from their own sources.
  Map<String, dynamic>? _economy;
  List<Map<String, dynamic>> _activity = [];
  Set<String> _internalUserIds = {};
  Set<String> _friendUserIds = {};
  Set<String> _ownerUserIds = {};

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
    'place_searched': 'Searched for a place',
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
    'claim_opened': 'Opened the claim page',
    'claim_step': 'Moved through the claim form',
    'claim_typed': 'Typed in the claim form',
    'claim_free': 'Claimed a free listing',
    'claim_to_payment': 'Went to payment',
    'claim_searched': 'Searched on the claim page',
    'page_left': 'Left the page',
  };

  String get _segKey => switch (_segment) {
        1 => 'friends',
        2 => 'customers',
        3 => 'owners',
        _ => 'all',
      };

  @override
  void initState() {
    super.initState();
    _load();
    _loadSide();
  }

  int _seq = 0; // only the newest request's answer is shown

  Future<void> _load() async {
    final mine = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d =
          await _supabase.adminAnalytics(days: _days, segment: _segKey);
      if (mounted && mine == _seq) setState(() => _data = d ?? {});
    } catch (e) {
      if (!mounted || mine != _seq) return;
      const msg = 'The numbers did not load. If the app was updated in the '
          'last few minutes, the database may still be catching up: pull '
          'down to try again.';
      setState(() => _error = msg);
      if (_data != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text(msg)));
      }
    } finally {
      if (mounted && mine == _seq) setState(() => _loading = false);
    }
  }

  Future<void> _loadSide() async {
    try {
      await _loadSideInner();
    } catch (_) {
      // Active cities and the coin economy are extras; the rest stands.
    }
  }

  Future<void> _loadSideInner() async {
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
    if (!mounted) return;
    setState(() {
      _economy = economy;
      _activity = activity;
      _internalUserIds = internal;
      _friendUserIds = cohorts.entries
          .where((e) => e.value == 'friend')
          .map((e) => e.key)
          .toSet();
      _ownerUserIds = cohorts.entries
          .where((e) => e.value == 'owner')
          .map((e) => e.key)
          .toSet();
    });
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

  static int _n(Object? v) => (v as num?)?.toInt() ?? 0;

  Map<String, dynamic> _map(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  List<Map<String, dynamic>> _list(Object? v) => v is List
      ? v.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
      : <Map<String, dynamic>>[];

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(title: const Text('Analytics'), actions: [
        TextButton.icon(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const ClaimJourneysScreen())),
          icon: const Icon(Icons.route_outlined, size: 18),
          label: const Text('Claim journeys'),
        ),
        TextButton.icon(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const GoogleUsageScreen())),
          icon: const Icon(Icons.receipt_long_outlined, size: 18),
          label: const Text('Google calls'),
        ),
        const SizedBox(width: 6),
      ]),
      body: data == null && _error == null
          ? const Center(child: CircularProgressIndicator(color: Brand.accent))
          : RefreshIndicator(
              onRefresh: () async {
                await _load();
                await _loadSide();
              },
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: _error != null && data == null
                      ? ListView(children: [
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(_error!,
                                textAlign: TextAlign.center,
                                style:
                                    const TextStyle(color: Brand.inkMuted)),
                          ),
                        ])
                      : _body(data!),
                ),
              ),
            ),
    );
  }

  Widget _body(Map<String, dynamic> data) {
    final cur = _map(data['cur']);
    final prev = _map(data['prev']);
    final daily = _list(data['daily']);
    final sources = _list(data['sources']);
    final owners = _map(data['owners']);
    final oCur = _map(owners['cur']);
    final oPrev = _map(owners['prev']);
    final searches = _list(data['searches']);
    final topSpaces = _list(data['top_spaces']);
    final actions = _list(data['actions']);
    final visitors = _list(data['visitors']);
    final excluded = _n(data['excluded']);
    final days = _n(data['days']) == 0 ? _days : _n(data['days']);

    final visitorsN = _n(cur['visitors']);
    final maxDay =
        daily.fold<int>(1, (a, b) => _n(b['n']) > a ? _n(b['n']) : a);
    final maxAct = actions.isEmpty ? 1 : _n(actions.first['n']);
    final back = _n(cur['returning']);

    // ---- active cities (verified contributions, newest 50) ----
    final cityCounts = <String, int>{};
    for (final a in _activity) {
      final uid = a['user_id'] as String?;
      if (_internalUserIds.contains(uid)) continue;
      final isFriend = _friendUserIds.contains(uid);
      if (_segment == 1 && !isFriend) continue;
      if (_segment == 2 && (isFriend || _ownerUserIds.contains(uid))) continue;
      if (_segment == 3 && !_ownerUserIds.contains(uid)) continue;
      final city = a['city'] as String?;
      if (city != null) cityCounts[city] = (cityCounts[city] ?? 0) + 1;
    }
    final topCities = cityCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // The economy comes per group (migration 22).
    final ecoRaw = _economy;
    final segEco = _segment == 1
        ? 'friend'
        : _segment == 2
            ? 'customer'
            : 'all';
    // Owners earn no coins, so the coin economy has no Owners view.
    final eco = ecoRaw == null || _segment == 3
        ? null
        : ecoRaw.containsKey('all')
            ? (ecoRaw[segEco] is Map
                ? Map<String, dynamic>.from(ecoRaw[segEco])
                : null)
            : ecoRaw;
    final liabilityCents = eco == null
        ? 0
        : (_n(eco['coins_withdrawable']) + _n(eco['euro_cents']));

    final period = '$days days';
    return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _audienceTabs(),
          const SizedBox(height: 10),
          _periodPicker(),
          if (_loading) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 2, color: Brand.accent),
          ],
          const SizedBox(height: 14),
          Row(children: [
            _tile('$visitorsN', 'Visitors · $period',
                _n(cur['visitors']), _n(prev['visitors'])),
            const SizedBox(width: 10),
            _tile('${_n(data['visitors_24h'])}', 'Visitors · last 24 hours',
                null, null),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _tile('${_n(cur['opens'])}', 'App opens · $period',
                _n(cur['opens']), _n(prev['opens'])),
            const SizedBox(width: 10),
            _tile('${_n(cur['signed'])} of $visitorsN', 'Signed in',
                _n(cur['signed']), _n(prev['signed'])),
          ]),
          const SizedBox(height: 6),
          Text('Changes compare with the $days days before.',
              style: const TextStyle(fontSize: 11.5, color: Brand.inkFaint)),
          const SizedBox(height: 20),

          const SectionLabel('DAILY VISITORS'),
          const SizedBox(height: 12),
          SizedBox(
            height: 70,
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (var i = 0; i < daily.length; i++) ...[
                Expanded(
                  child: Tooltip(
                    message: '${_dayLabel(daily[i]['day'])}: '
                        '${_n(daily[i]['n'])}',
                    child: Container(
                      height: _n(daily[i]['n']) == 0
                          ? 3
                          : 8 + 58 * _n(daily[i]['n']) / maxDay,
                      decoration: BoxDecoration(
                          color: _n(daily[i]['n']) == 0
                              ? Brand.field
                              : Brand.gold,
                          borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ),
                if (i != daily.length - 1)
                  SizedBox(width: daily.length > 40 ? 1 : 3),
              ],
            ]),
          ),
          const SizedBox(height: 6),
          Row(children: [
            Text(days == 7 ? 'a week ago' : '$days days ago',
                style: const TextStyle(fontSize: 11, color: Brand.inkFaint)),
            const Spacer(),
            const Text('today',
                style: TextStyle(fontSize: 11, color: Brand.inkFaint)),
          ]),
          const SizedBox(height: 6),
          Text(
              '$back visitor${back == 1 ? '' : 's'} came back on more '
              'than one day',
              style:
                  const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
          const SizedBox(height: 22),

          const SectionLabel('THE FUNNEL'),
          const SizedBox(height: 10),
          _funnelRow('Visited', visitorsN, visitorsN),
          _funnelRow('Viewed a space', _n(cur['viewed']), visitorsN),
          _funnelRow('Opened directions', _n(cur['directions']), visitorsN),
          _funnelRow('Signed in', _n(cur['signed']), visitorsN),
          _funnelRow('Sent a submission', _n(cur['submitted']), visitorsN),
          const SizedBox(height: 22),

          const SectionLabel('WHERE VISITORS COME FROM'),
          const SizedBox(height: 8),
          if (sources.isEmpty)
            _quiet('No visits in this period.')
          else
            ...sources.map((s) => _countRow(
                '${s['source']}', _n(s['n']), _n(s['before']),
                unit: 'visitor')),
          const SizedBox(height: 4),
          const Text(
              'From the link they arrived by (utm_source or ref) or the site '
              'that sent them. Sites that send no address show as "Direct '
              'or unknown"; WhatsApp and many apps do that.',
              style: TextStyle(fontSize: 11.5, color: Brand.inkFaint)),
          const SizedBox(height: 22),

          const SectionLabel('OWNERS'),
          const SizedBox(height: 10),
          _funnelRow('Opened the claim page', _n(oCur['opened']),
              _n(oCur['opened']),
              before: _n(oPrev['opened'])),
          _funnelRow('Started the form', _n(oCur['started']),
              _n(oCur['opened']),
              before: _n(oPrev['started'])),
          _funnelRow('Claimed free', _n(oCur['free']), _n(oCur['opened']),
              before: _n(oPrev['free'])),
          _funnelRow('Went to payment', _n(oCur['to_payment']),
              _n(oCur['opened']),
              before: _n(oPrev['to_payment'])),
          _funnelRow('Paid for Verified', _n(oCur['paid']),
              _n(oCur['opened']),
              before: _n(oPrev['paid'])),
          const SizedBox(height: 22),

          const SectionLabel('SEARCHED FOR, LITTLE FOUND'),
          const SizedBox(height: 8),
          if (searches.isEmpty)
            _quiet('Nothing yet. Places people search for that have two '
                'spaces or fewer nearby appear here, which shows where to '
                'sweep next. Recorded from 30 September 2026.')
          else
            ...searches.map((s) {
              final near = _n(s['near']);
              final where = (s['place_where'] ?? '').toString();
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  const Icon(Icons.search, size: 15, color: Brand.inkMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                        TextSpan(children: [
                          TextSpan(
                              text: _title('${s['q']}'),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                          if (where.isNotEmpty)
                            TextSpan(
                                text: '  $where',
                                style: const TextStyle(
                                    color: Brand.inkMuted, fontSize: 12)),
                        ]),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5)),
                  ),
                  Text(
                      '${_n(s['searches'])} search'
                      '${_n(s['searches']) == 1 ? '' : 'es'} · '
                      '${near == 0 ? 'no spaces' : '$near space${near == 1 ? '' : 's'}'} nearby',
                      style: const TextStyle(
                          fontSize: 12.5, color: Brand.inkSecondary)),
                ]),
              );
            }),
          const SizedBox(height: 22),

          if (topSpaces.isNotEmpty) ...[
            const SectionLabel('TOP SPACES'),
            const SizedBox(height: 8),
            ...topSpaces.map((s) {
              final views = _n(s['views']);
              final shares = _n(s['shares']);
              final dirs = _n(s['directions']);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Expanded(
                    child: Text('${s['venue']}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600)),
                  ),
                  Text(
                      [
                        '$views view${views == 1 ? '' : 's'}',
                        if (dirs > 0) '$dirs directions',
                        if (shares > 0) '$shares shared',
                      ].join(' · '),
                      style: const TextStyle(
                          fontSize: 12.5, color: Brand.inkSecondary)),
                ]),
              );
            }),
            const SizedBox(height: 22),
          ],

          if (topCities.isNotEmpty) ...[
            const SectionLabel('ACTIVE CITIES'),
            const SizedBox(height: 8),
            ...topCities.take(5).map((c) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    const Icon(Icons.location_on,
                        size: 15, color: Brand.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(c.key,
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w600)),
                    ),
                    Text('${c.value} contribution${c.value == 1 ? '' : 's'}',
                        style: const TextStyle(
                            fontSize: 12.5, color: Brand.inkSecondary)),
                  ]),
                )),
            const SizedBox(height: 4),
            const Text('From the latest 50 contributions.',
                style: TextStyle(fontSize: 11.5, color: Brand.inkFaint)),
            const SizedBox(height: 22),
          ],

          if (eco != null) ...[
            const SectionLabel('COIN ECONOMY'),
            const SizedBox(height: 10),
            Row(children: [
              _tile('${eco['coins_withdrawable']}', 'Coins in circulation',
                  null, null),
              const SizedBox(width: 10),
              _tile('${eco['coins_pending']}', 'Coins pending', null, null),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              _tile(
                  '€${(_n(eco['euro_cents']) / 100).toStringAsFixed(2)}',
                  'Converted to euros',
                  null,
                  null),
              const SizedBox(width: 10),
              _tile('€${(liabilityCents / 100).toStringAsFixed(2)}',
                  'Payout liability', null, null),
            ]),
            const SizedBox(height: 22),
          ],

          const SectionLabel('WHAT PEOPLE DO'),
          const SizedBox(height: 10),
          if (actions.isEmpty) _quiet('No actions in this period.'),
          ...actions.map((a) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  SizedBox(
                    width: 180,
                    child: Text(_label('${a['name']}'),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _n(a['n']) / maxAct,
                        minHeight: 8,
                        backgroundColor: Brand.field,
                        color: Brand.gold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('${_n(a['n'])}',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                ]),
              )),
          const SizedBox(height: 22),

          SectionLabel(visitors.length >= 100
              ? 'VISITORS (LATEST 100)'
              : 'VISITORS'),
          const SizedBox(height: 6),
          if (visitors.isEmpty)
            _quiet('No outside visitors in this period.')
          else
            ...visitors.map(_visitorRow),
          if (excluded > 0 || _segment != 0) ...[
            const SizedBox(height: 14),
            Text(
                [
                  if (excluded > 0)
                    'Leaving out $excluded team device'
                        '${excluded == 1 ? '' : 's'} and automated '
                        'visitor${excluded == 1 ? '' : 's'}.',
                  if (_segment == 1)
                    'Showing friends only. Mark accounts as friends in '
                        'Users.',
                  if (_segment == 2)
                    'Showing customers only (friend and owner devices '
                        'hidden).',
                  if (_segment == 3)
                    'Showing owners only: devices used by accounts that run '
                        'a space.',
                ].join(' '),
                style: const TextStyle(fontSize: 11.5, color: Brand.inkFaint)),
          ],
        ]);
  }

  static String _title(String s) => s
      .split(' ')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');

  String _dayLabel(Object? iso) {
    final t = DateTime.tryParse('$iso');
    return t == null ? '' : DateFormat('EEE d MMM').format(t);
  }

  Widget _quiet(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text,
            style: const TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
      );

  /// "▲ 12%" in green, "▼ 5%" in red, "new" when there was nothing
  /// before, nothing when both are zero.
  Widget _change(int now, int before) {
    if (now == 0 && before == 0) return const SizedBox.shrink();
    final String text;
    final Color color;
    if (before == 0) {
      text = 'new';
      color = Brand.success;
    } else {
      final pct = ((now - before) / before * 100).round();
      if (pct == 0) {
        text = 'same';
        color = Brand.inkMuted;
      } else {
        text = pct > 0 ? '▲ $pct%' : '▼ ${-pct}%';
        color = pct > 0 ? Brand.success : Brand.accent;
      }
    }
    return Text(text,
        style: TextStyle(
            fontSize: 11.5, fontWeight: FontWeight.w700, color: color));
  }

  Widget _countRow(String label, int n, int before, {String unit = ''}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600)),
          ),
          Text('$n${unit.isEmpty ? '' : ' $unit${n == 1 ? '' : 's'}'}',
              style:
                  const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
          const SizedBox(width: 8),
          SizedBox(
              width: 52,
              child: Align(
                  alignment: Alignment.centerRight,
                  child: _change(n, before))),
        ]),
      );

  Widget _periodPicker() {
    Widget chip(int d, String label) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(
            label: Text(label),
            selected: _days == d,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            selectedColor: Brand.ink,
            labelStyle: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _days == d ? Colors.white : Brand.ink),
            onSelected: (_) {
              if (_days == d) return;
              setState(() => _days = d);
              _load();
            },
          ),
        );
    return Row(children: [
      chip(7, '7 days'),
      chip(30, '30 days'),
      chip(90, '90 days'),
    ]);
  }

  Widget _audienceTabs() {
    Widget seg(int index, String label) {
      final active = _segment == index;
      return Expanded(
        child: GestureDetector(
          onTap: () {
            if (_segment == index) return;
            setState(() => _segment = index);
            _load();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: active ? Brand.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              boxShadow: active
                  ? [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: .06),
                          blurRadius: 6,
                          offset: const Offset(0, 1))
                    ]
                  : null,
            ),
            child: Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                    color: active ? Brand.ink : Brand.inkMuted)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Brand.field,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(children: [
        seg(0, 'Everyone'),
        seg(1, 'Friends'),
        seg(2, 'Customers'),
        seg(3, 'Owners'),
      ]),
    );
  }

  Widget _funnelRow(String label, int value, int base, {int? before}) {
    final pct = base == 0 ? 0 : (value / base * 100).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        SizedBox(
          width: 160,
          child: Text(label,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: base == 0 ? 0 : (value / base).clamp(0.0, 1.0),
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
              style:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
        ),
        if (before != null)
          SizedBox(
              width: 52,
              child: Align(
                  alignment: Alignment.centerRight,
                  child: _change(value, before))),
      ]),
    );
  }

  Widget _tile(String value, String label, int? now, int? before) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          decoration: BoxDecoration(
            color: Brand.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Brand.border),
          ),
          child: Column(children: [
            Text(value,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
            if (now != null && before != null) ...[
              const SizedBox(height: 4),
              _change(now, before),
            ],
          ]),
        ),
      );

  Widget _visitorRow(Map<String, dynamic> v) {
    final anon = '${v['anon']}';
    final signed = v['signed'] == true;
    final name = (v['name'] ?? '').toString().isNotEmpty
        ? '${v['name']}'
        : signed
            ? 'Nomad'
            : 'Visitor ${anon.length > 6 ? anon.substring(anon.length - 6) : anon}';
    final isFriend = v['friend'] == true;
    final n = _n(v['actions']);
    return InkWell(
      onTap: () => _showTrail(name, anon),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          NomadAvatar(name: name, radius: 18),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600)),
                ),
                if (isFriend) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
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
                  '$n action${n == 1 ? '' : 's'} · '
                  'last ${_ago(v['last_at']?.toString())}'
                  '${signed ? '' : ' · not signed in'}',
                  style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
            ]),
          ),
          const Icon(Icons.chevron_right, size: 18, color: Brand.inkFaint),
        ]),
      ),
    );
  }

  void _showTrail(String name, String anon) {
    final trailFuture = _supabase.adminVisitorTrail(anon);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Brand.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .6,
        maxChildSize: .92,
        builder: (ctx, scroll) => FutureBuilder<List<Map<String, dynamic>>>(
          future: trailFuture,
          builder: (ctx, snap) {
            final trail = snap.data;
            return ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 30),
              children: [
                Text(name,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                if (trail == null)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(
                        child: CircularProgressIndicator(color: Brand.accent)),
                  )
                else if (trail.isEmpty)
                  _quiet('No actions recorded.')
                else
                  ...trail.map((e) {
                    final props = e['props'] is Map
                        ? Map<String, dynamic>.from(e['props'])
                        : <String, dynamic>{};
                    final detail = [
                      if (props['venue'] != null) props['venue'],
                      if (props['place'] != null) props['place'],
                      if (props['query'] != null) '"${props['query']}"',
                      if (props['kind'] != null) props['kind'],
                      if (props['mbps'] != null) '${props['mbps']} Mbps',
                      if (props['utm_source'] != null)
                        'from ${props['utm_source']}',
                      if (props['referrer'] != null)
                        'from ${props['referrer']}',
                    ].join(' · ');
                    final t = DateTime.tryParse('${e['created_at']}');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(_label('${e['name']}'),
                                        style: const TextStyle(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w600)),
                                    if (detail.isNotEmpty)
                                      Text(detail,
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Brand.inkSecondary)),
                                  ]),
                            ),
                            Text(
                                t == null
                                    ? ''
                                    : DateFormat('d MMM HH:mm')
                                        .format(t.toLocal()),
                                style: const TextStyle(
                                    fontSize: 11.5, color: Brand.inkMuted)),
                          ]),
                    );
                  }),
              ],
            );
          },
        ),
      ),
    );
  }
}
