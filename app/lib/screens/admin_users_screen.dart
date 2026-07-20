import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'venue_detail.dart';

/// Admin only: every account, searchable, tap one for the full story.
class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});
  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _users;
  Map<String, String> _cohorts = {};
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final users = await _supabase.adminUsers();
    final cohorts = await _supabase.profileCohorts();
    if (mounted) {
      setState(() {
        _users = users;
        _cohorts = cohorts;
      });
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final all = _users ?? [];
    if (_query.trim().isEmpty) return all;
    final q = _query.toLowerCase();
    return all
        .where((u) =>
            (u['display_name'] ?? '').toString().toLowerCase().contains(q) ||
            (u['email'] ?? '').toString().toLowerCase().contains(q))
        .toList();
  }

  String _shortDate(String? iso) {
    final t = DateTime.tryParse(iso ?? '');
    if (t == null) return 'never';
    return DateFormat('d MMM yyyy').format(t);
  }

  String _lastSeen(String? iso) {
    final t = DateTime.tryParse(iso ?? '');
    if (t == null) return 'never signed in';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 60) return 'active ${d.inMinutes}m ago';
    if (d.inHours < 24) return 'active ${d.inHours}h ago';
    if (d.inDays < 7) return 'active ${d.inDays}d ago';
    return 'last seen ${DateFormat('d MMM').format(t)}';
  }

  @override
  Widget build(BuildContext context) {
    final users = _users;
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Text('Users'),
          if (users != null) ...[
            const SizedBox(width: 8),
            Text('${users.length}',
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: Brand.inkMuted)),
          ],
        ]),
      ),
      body: users == null
          ? const Center(
              child: CircularProgressIndicator(color: Brand.accent))
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: SizedBox(
                  height: 42,
                  child: TextField(
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: 'Search name or email',
                      prefixIcon: const Icon(Icons.search,
                          size: 20, color: Brand.inkMuted),
                      isDense: true,
                      filled: true,
                      fillColor: Brand.field,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: _filtered.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, color: Brand.hairline),
                    itemBuilder: (_, i) => _userRow(_filtered[i]),
                  ),
                ),
              ),
            ]),
    );
  }

  /// Small pill saying which group the account belongs to.
  Widget _groupTag(String? cohort) {
    final (label, bg, fg) = switch (cohort) {
      'team' => ('Team', Brand.ink, Colors.white),
      'friend' => ('Friend', Brand.goldTint, Brand.goldTextDark),
      _ => ('Customer', Brand.field, Brand.inkSecondary),
    };
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: fg)),
    );
  }

  Widget _userRow(Map<String, dynamic> u) {
    final coins = (u['coins_confirmed'] ?? 0) + (u['coins_pending'] ?? 0);
    return InkWell(
      onTap: () async {
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => AdminUserDetailScreen(user: u)));
        _load(); // the group may have been changed in the detail
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(children: [
          NomadAvatar(
              name: u['display_name'],
              photoUrl: u['avatar_url'],
              radius: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(u['display_name'] ?? 'Nomad',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600)),
                    ),
                    if (u['is_admin'] == true) ...[
                      const SizedBox(width: 7),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                            color: Brand.accentTint,
                            borderRadius: BorderRadius.circular(8)),
                        child: const Text('ADMIN',
                            style: TextStyle(
                                fontSize: 10,
                                color: Brand.accent,
                                letterSpacing: .5,
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                    const SizedBox(width: 7),
                    _groupTag(_cohorts[u['id']]),
                  ]),
                  const SizedBox(height: 1),
                  Text(u['email'] ?? '',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5, color: Brand.inkMuted)),
                  const SizedBox(height: 1),
                  Text(
                      'Joined ${_shortDate(u['joined_at'])} · '
                      '${_lastSeen(u['last_sign_in_at'])}',
                      style: const TextStyle(
                          fontSize: 11.5, color: Brand.inkFaint)),
                ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const CoinDot(size: 12),
              const SizedBox(width: 5),
              Text('$coins',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14)),
            ]),
            const SizedBox(height: 2),
            Text('${u['submissions_verified'] ?? 0} verified',
                style: const TextStyle(
                    fontSize: 11.5, color: Brand.inkMuted)),
          ]),
        ]),
      ),
    );
  }
}

/// One user's account details + full activity trail.
class AdminUserDetailScreen extends StatefulWidget {
  final Map<String, dynamic> user;
  const AdminUserDetailScreen({super.key, required this.user});
  @override
  State<AdminUserDetailScreen> createState() =>
      _AdminUserDetailScreenState();
}

class _AdminUserDetailScreenState extends State<AdminUserDetailScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _activity;
  List<Map<String, dynamic>>? _appEvents;
  String? _cohort; // 'team' | 'friend' | null = customer

  static const _eventNames = {
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
    'coins_converted': 'Converted coins to euros',
    'cashout_requested': 'Tapped cash out',
    'avatar_updated': 'Changed profile photo',
    'nickname_set': 'Set a nickname',
    'anon_finds_claimed': 'Claimed their discoveries',
    'add_to_home_opened': 'Opened Add to Home Screen',
  };

  static const _kindLabel = {
    'new_venue': 'NEW SPACE',
    'confirm': 'CONFIRMATION',
    'wifi_test': 'WIFI TEST',
    'wifi_login': 'WIFI LOGIN',
  };

  static const _kindIcon = {
    'new_venue': Icons.rate_review_outlined,
    'confirm': Icons.verified_outlined,
    'wifi_test': Icons.speed,
    'wifi_login': Icons.key,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final act =
        await _supabase.adminUserActivity(widget.user['id'] as String);
    final cohorts = await _supabase.profileCohorts();
    // Everything this person did in the app (taps, views, searches):
    // their signed-in events plus everything else from the same
    // devices, so pre-sign-in browsing shows too.
    final all = await _supabase.adminEvents(days: 14);
    final id = widget.user['id'];
    final devices = all
        .where((e) => e['user_id'] == id)
        .map((e) => e['anon_id'] as String)
        .toSet();
    final events = all
        .where((e) =>
            e['user_id'] == id || devices.contains(e['anon_id']))
        .toList()
      ..sort((a, b) => (b['created_at'] as String)
          .compareTo(a['created_at'] as String));
    if (mounted) {
      setState(() {
        _activity = act;
        _cohort = cohorts[widget.user['id']];
        _appEvents = events;
      });
    }
  }

  Future<void> _setCohort(String? value) async {
    await _supabase.setCohort(widget.user['id'] as String, value);
    if (mounted) setState(() => _cohort = value);
  }

  String _fmt(String? iso) {
    final t = DateTime.tryParse(iso ?? '');
    if (t == null) return 'never';
    return DateFormat('d MMM yyyy, HH:mm').format(t);
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    final act = _activity;
    return Scaffold(
      appBar: AppBar(title: Text(u['display_name'] ?? 'Nomad')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        // ---- account card ----
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
              color: Brand.ink,
              borderRadius: BorderRadius.circular(18)),
          child: Column(children: [
            NomadAvatar(
                name: u['display_name'],
                photoUrl: u['avatar_url'],
                radius: 32),
            const SizedBox(height: 10),
            Text(u['display_name'] ?? 'Nomad',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900)),
            Text(u['email'] ?? '',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: .9),
                    fontSize: 13)),
            const SizedBox(height: 14),
            Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _bigStat('${u['coins_confirmed'] ?? 0}', 'Coins'),
                  _bigStat('${u['coins_pending'] ?? 0}', 'Pending'),
                  _bigStat(
                      '${u['submissions_verified'] ?? 0}', 'Verified'),
                  _bigStat(
                      '${u['submissions_rejected'] ?? 0}', 'Rejected'),
                ]),
          ]),
        ),
        const SizedBox(height: 12),
        _infoRow(Icons.calendar_today_outlined, 'Joined',
            _fmt(u['joined_at'])),
        _infoRow(Icons.login, 'Last sign-in',
            _fmt(u['last_sign_in_at'])),
        const SizedBox(height: 14),

        // ---- analytics group ----
        Row(children: [
          const Icon(Icons.group_work_outlined,
              size: 16, color: Brand.inkSecondary),
          const SizedBox(width: 8),
          const Text('Group:  ',
              style: TextStyle(
                  color: Brand.inkSecondary, fontSize: 13)),
          Wrap(spacing: 6, children: [
            for (final (label, value) in [
              ('Customer', null),
              ('Friend', 'friend'),
              ('Team', 'team'),
            ])
              ChoiceChip(
                label: Text(label,
                    style: const TextStyle(fontSize: 12)),
                selected: _cohort == value,
                showCheckmark: false,
                selectedColor: Brand.ink,
                labelStyle: TextStyle(
                    fontSize: 12,
                    color: _cohort == value
                        ? Colors.white
                        : Brand.ink),
                visualDensity: VisualDensity.compact,
                onSelected: (_) => _setCohort(value),
              ),
          ]),
        ]),
        const SizedBox(height: 14),
        const Text('APP ACTIVITY · 14 DAYS',
            style: TextStyle(
                color: Brand.red,
                fontWeight: FontWeight.w900,
                fontSize: 13,
                letterSpacing: 1)),
        const SizedBox(height: 6),
        if (_appEvents == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
                child: CircularProgressIndicator(color: Brand.red)),
          )
        else if (_appEvents!.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Nothing recorded in the last two weeks.',
                style: TextStyle(color: Colors.grey.shade600)),
          )
        else
          ..._appEvents!.take(40).map(_eventRow),
        const SizedBox(height: 18),
        const Text('CONTRIBUTIONS',
            style: TextStyle(
                color: Brand.red,
                fontWeight: FontWeight.w900,
                fontSize: 13,
                letterSpacing: 1)),
        const SizedBox(height: 6),
        if (act == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
                child: CircularProgressIndicator(color: Brand.red)),
          )
        else if (act.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
                child: Text('No reviews or submissions yet.',
                    style: TextStyle(color: Colors.grey.shade600))),
          )
        else
          ...act.map(_activityTile),
        const SizedBox(height: 24),
      ]),
    );
  }

  String _agoShort(String? iso) {
    final t = DateTime.tryParse(iso ?? '');
    if (t == null) return '';
    final d = DateTime.now().toUtc().difference(t.toUtc());
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  Widget _eventRow(Map<String, dynamic> e) {
    final props = (e['props'] is Map)
        ? Map<String, dynamic>.from(e['props'])
        : <String, dynamic>{};
    final detail = [
      if (props['venue'] != null) props['venue'],
      if (props['place'] != null) props['place'],
      if (props['query'] != null) '"${props['query']}"',
      if (props['mbps'] != null) '${props['mbps']} Mbps',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    _eventNames[e['name']] ?? e['name'] as String,
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
        Text(_agoShort(e['created_at']),
            style: const TextStyle(
                fontSize: 11.5, color: Brand.inkFaint)),
      ]),
    );
  }

  Widget _bigStat(String value, String label) => Column(children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w900)),
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: .85),
                fontSize: 11)),
      ]);

  Widget _infoRow(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(icon, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Text('$label:  ',
              style: TextStyle(
                  color: Colors.grey.shade600, fontSize: 13)),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13)),
          ),
        ]),
      );

  /// What the payload's database names mean in plain words.
  static const _fieldLabels = {
    'name': 'Space name',
    'type': 'Type',
    'neighbourhood': 'Neighbourhood',
    'wifi_speed_mbps': 'WiFi speed (Mbps)',
    'connection_type': 'Connection during test',
    'ssid': 'WiFi network',
    'password': 'WiFi password',
    'laptops_allowed': 'Laptops allowed',
    'power_outlets': 'Power outlets',
    'aircon': 'Aircon',
    'comfortable_seating': 'Comfortable seating',
    'cozy': 'Cozy',
    'quiet_space': 'Quiet space',
    'good_for_calls': 'Good for calls',
    'call_room': 'Call/Skype room',
    'monitor': 'Monitor available',
    'office_chairs': 'Office chairs',
    'access_24h': '24h access',
  };

  Future<void> _openListing(String venueId) async {
    final v = await _supabase.venueById(venueId);
    if (v == null || !mounted) return;
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                VenueDetailScreen(venue: v, onConfirm: () {})));
  }

  void _openActivity(Map<String, dynamic> a) {
    final status = a['status'] as String? ?? 'pending';
    final (chipColor, chipText) = switch (status) {
      'verified' => (Brand.success, 'verified'),
      'rejected' => (Brand.accent, 'rejected'),
      _ => (Brand.gold, 'pending'),
    };
    final payload = Map<String, dynamic>.from(a['payload'] ?? {});
    final entries = _fieldLabels.entries
        .where((e) =>
            payload.containsKey(e.key) &&
            payload[e.key] != null &&
            '${payload[e.key]}'.trim().isNotEmpty)
        .map((e) {
      final v = payload[e.key];
      final text = v == true
          ? 'Yes'
          : v == false
              ? 'No'
              : '$v';
      return (e.value, text);
    }).toList();
    final dist = a['gps_distance_m'] as num?;
    final photoPath = a['photo_path'] as String?;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Brand.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .65,
        maxChildSize: .92,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
          children: [
            Row(children: [
              Icon(_kindIcon[a['kind']] ?? Icons.bolt,
                  size: 20, color: Brand.ink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_kindLabel[a['kind']] ?? '${a['kind']}',
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: .5)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                    color: chipColor.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(10)),
                child: Text(chipText,
                    style: TextStyle(
                        fontSize: 12,
                        color: chipColor,
                        fontWeight: FontWeight.w700)),
              ),
              if ((a['coins'] ?? 0) != 0) ...[
                const SizedBox(width: 8),
                CoinChip('+${a['coins']}', height: 22),
              ],
            ]),
            const SizedBox(height: 6),
            Text(
                [
                  if (a['venue_name'] != null) a['venue_name'],
                  if (a['city'] != null) a['city'],
                ].join(', '),
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
                '${_fmt(a['created_at'])}'
                '${dist != null ? ' · submitted ${dist < 1000 ? '${dist.round()} m' : '${(dist / 1000).toStringAsFixed(1)} km'} from the space' : ''}',
                style: const TextStyle(
                    fontSize: 12.5, color: Brand.inkMuted)),
            const SizedBox(height: 16),
            const SectionLabel('WHAT THEY SUBMITTED'),
            const SizedBox(height: 8),
            if (entries.isEmpty)
              const Text('No field changes in this submission.',
                  style: TextStyle(
                      fontSize: 13.5, color: Brand.inkMuted))
            else
              ...entries.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(e.$1,
                                style: const TextStyle(
                                    fontSize: 13.5,
                                    color: Brand.inkSecondary)),
                          ),
                          Text(e.$2,
                              style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700)),
                        ]),
                  )),
            if (photoPath != null) ...[
              const SizedBox(height: 14),
              const SectionLabel('THEIR PHOTO'),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.network(_supabase.photoUrl(photoPath),
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox()),
              ),
            ],
            if (a['venue_id'] != null) ...[
              const SizedBox(height: 18),
              PrimaryCta(
                label: 'View the listing',
                onPressed: () {
                  Navigator.pop(ctx);
                  _openListing(a['venue_id'] as String);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _activityTile(Map<String, dynamic> a) {
    final status = a['status'] as String? ?? 'pending';
    final (chipColor, chipText) = switch (status) {
      'verified' => (Colors.green.shade700, 'verified'),
      'rejected' => (Brand.red, 'rejected'),
      _ => (Brand.amber, 'pending'),
    };
    final place = [
      if (a['venue_name'] != null) a['venue_name'],
      if (a['city'] != null) a['city'],
    ].join(', ');
    final dist = a['gps_distance_m'] as num?;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.grey.shade200)),
      margin: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openActivity(a),
        child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(children: [
          Icon(_kindIcon[a['kind']] ?? Icons.bolt,
              size: 20, color: Brand.charcoal),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      '${_kindLabel[a['kind']] ?? a['kind']}'
                      '${place.isEmpty ? '' : ' · $place'}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13)),
                  Text(
                      '${_fmt(a['created_at'])}'
                      '${dist != null ? ' · ${dist < 1000 ? '${dist.round()} m away' : '${(dist / 1000).toStringAsFixed(1)} km away'}' : ''}',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600)),
                ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                  color: chipColor.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(10)),
              child: Text(chipText,
                  style: TextStyle(
                      fontSize: 11,
                      color: chipColor,
                      fontWeight: FontWeight.w800)),
            ),
            if ((a['coins'] ?? 0) != 0)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text('+${a['coins']}',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        color: Brand.charcoal)),
              ),
          ]),
        ]),
        ),
      ),
    );
  }
}
