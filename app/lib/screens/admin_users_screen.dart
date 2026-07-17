import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// Admin only: every account, searchable, tap one for the full story.
class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});
  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _users;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final users = await _supabase.adminUsers();
    if (mounted) setState(() => _users = users);
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

  Widget _userRow(Map<String, dynamic> u) {
    final coins = (u['coins_confirmed'] ?? 0) + (u['coins_pending'] ?? 0);
    return InkWell(
      onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => AdminUserDetailScreen(user: u))),
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
    if (mounted) setState(() => _activity = act);
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
        const SizedBox(height: 18),
        const Text('ACTIVITY',
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
                child: Text('No activity yet.',
                    style: TextStyle(color: Colors.grey.shade600))),
          )
        else
          ...act.map(_activityTile),
        const SizedBox(height: 24),
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
    );
  }
}
