import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

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
          title: Text(users == null
              ? 'Users'
              : 'Users (${users.length})')),
      body: users == null
          ? const Center(
              child: CircularProgressIndicator(color: Brand.red))
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: 'Search name or email',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: _filtered.length,
                    itemBuilder: (_, i) => _userCard(_filtered[i]),
                  ),
                ),
              ),
            ]),
    );
  }

  Widget _userCard(Map<String, dynamic> u) {
    final coins = (u['coins_confirmed'] ?? 0) + (u['coins_pending'] ?? 0);
    return Card(
      elevation: 0.5,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Colors.grey.shade200)),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => AdminUserDetailScreen(user: u))),
        leading: _avatar(u, radius: 22, fontSize: 18),
        title: Row(children: [
          Flexible(
            child: Text(u['display_name'] ?? 'Nomad',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
          if (u['is_admin'] == true) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                  color: Brand.red.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(8)),
              child: const Text('admin',
                  style: TextStyle(
                      fontSize: 10,
                      color: Brand.red,
                      fontWeight: FontWeight.w800)),
            ),
          ],
        ]),
        subtitle: Text(
            '${u['email'] ?? ''}\n'
            'Joined ${_shortDate(u['joined_at'])} · '
            '${_lastSeen(u['last_sign_in_at'])}',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        isThreeLine: true,
        trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.monetization_on,
                    color: Brand.amber, size: 16),
                const SizedBox(width: 3),
                Text('$coins',
                    style:
                        const TextStyle(fontWeight: FontWeight.w900)),
              ]),
              Text('${u['submissions_verified'] ?? 0} verified',
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade600)),
            ]),
      ),
    );
  }

  Widget _avatar(Map<String, dynamic> u,
      {double radius = 16, double fontSize = 14}) {
    final url = u['avatar_url'] as String?;
    return CircleAvatar(
      radius: radius,
      backgroundColor: Brand.red.withValues(alpha: .1),
      backgroundImage: url != null ? NetworkImage(url) : null,
      child: url == null
          ? Text(
              ((u['display_name'] ?? 'N') as String)
                  .substring(0, 1)
                  .toUpperCase(),
              style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w900,
                  color: Brand.red))
          : null,
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
              gradient: Brand.gradient,
              borderRadius: BorderRadius.circular(18)),
          child: Column(children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: Colors.white.withValues(alpha: .25),
              backgroundImage: u['avatar_url'] != null
                  ? NetworkImage(u['avatar_url'])
                  : null,
              child: u['avatar_url'] == null
                  ? Text(
                      ((u['display_name'] ?? 'N') as String)
                          .substring(0, 1)
                          .toUpperCase(),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w900))
                  : null,
            ),
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
