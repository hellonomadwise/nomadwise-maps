import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/analytics_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';

/// Leaderboard (top nomads by coins) + live activity feed.
/// Tap any player to see their public stats.
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key});
  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _top;
  List<Map<String, dynamic>>? _activity;

  @override
  void initState() {
    super.initState();
    Analytics.capture('leaderboard_viewed');
    _load();
  }

  Future<void> _load() async {
    final top = await _supabase.leaderboard();
    final act = await _supabase.liveActivity();
    if (mounted) {
      setState(() {
        _top = top;
        _activity = act;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Leaderboard'),
          bottom: TabBar(
            labelColor: Brand.red,
            unselectedLabelColor: Colors.grey.shade500,
            indicatorColor: Brand.red,
            labelStyle: const TextStyle(fontWeight: FontWeight.w800),
            tabs: const [
              Tab(text: 'TOP NOMADS'),
              Tab(text: 'LIVE'),
            ],
          ),
        ),
        body: TabBarView(children: [
          _topList(),
          _liveFeed(),
        ]),
      ),
    );
  }

  // ---------- top nomads ----------

  Widget _topList() {
    final top = _top;
    if (top == null) {
      return const Center(
          child: CircularProgressIndicator(color: Brand.red));
    }
    if (top.isEmpty) {
      return _empty('No coins earned yet.\nBe the first on the board!');
    }
    final myId = _supabase.currentUser?.id;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: top.length,
        itemBuilder: (_, i) {
          final r = top[i];
          final isMe = r['user_id'] == myId;
          return Card(
            elevation: isMe ? 3 : 0.5,
            color: isMe ? Brand.red.withValues(alpha: .06) : Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                    color: isMe ? Brand.red : Colors.grey.shade200)),
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              onTap: () => _showProfile(r),
              leading: _rankBadge(i + 1),
              title: Row(children: [
                _avatar(r, radius: 14),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    r['display_name'] + (isMe ? '  (you)' : ''),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ]),
              subtitle: Text(
                  '${r['verified_count']} verified contribution'
                  '${r['verified_count'] == 1 ? '' : 's'}',
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade600)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.monetization_on,
                    color: Brand.amber, size: 18),
                const SizedBox(width: 4),
                Text('${r['coins']}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w900, fontSize: 16)),
              ]),
            ),
          );
        },
      ),
    );
  }

  Widget _rankBadge(int rank) {
    final (color, textColor) = switch (rank) {
      1 => (Brand.amber, Colors.white),
      2 => (const Color(0xFFB8C0CC), Colors.white),
      3 => (const Color(0xFFCD8A55), Colors.white),
      _ => (Brand.lightGrey, Brand.charcoal),
    };
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text('$rank',
          style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.w900,
              fontSize: rank < 100 ? 15 : 12)),
    );
  }

  // ---------- live feed ----------

  static const _kindVerb = {
    'new_venue': 'reviewed',
    'confirm': 'confirmed',
    'wifi_test': 'tested the wifi at',
    'wifi_login': 'shared the wifi for',
  };

  static const _kindIcon = {
    'new_venue': Icons.rate_review_outlined,
    'confirm': Icons.verified_outlined,
    'wifi_test': Icons.speed,
    'wifi_login': Icons.key,
  };

  String _ago(String? iso) {
    final t = DateTime.tryParse(iso ?? '');
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return DateFormat('d MMM').format(t);
  }

  Widget _liveFeed() {
    final act = _activity;
    if (act == null) {
      return const Center(
          child: CircularProgressIndicator(color: Brand.red));
    }
    if (act.isEmpty) {
      return _empty('No activity yet.\nEvery verified contribution '
          'shows up here, live.');
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: act.length,
        itemBuilder: (_, i) {
          final a = act[i];
          final verb = _kindVerb[a['kind']] ?? 'updated';
          final place = [
            if (a['venue_name'] != null) a['venue_name'],
            if (a['city'] != null) a['city'],
          ].join(', ');
          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            leading: a['avatar_url'] != null
                ? _avatar(a, radius: 18)
                : CircleAvatar(
                    radius: 18,
                    backgroundColor: Brand.amber.withValues(alpha: .18),
                    child: Icon(_kindIcon[a['kind']] ?? Icons.bolt,
                        size: 18, color: Brand.charcoal),
                  ),
            title: RichText(
              text: TextSpan(
                style: const TextStyle(
                    color: Brand.charcoal, fontSize: 14),
                children: [
                  TextSpan(
                      text: a['display_name'],
                      style:
                          const TextStyle(fontWeight: FontWeight.w800)),
                  TextSpan(text: ' $verb '),
                  TextSpan(
                      text: place.isEmpty ? 'a space' : place,
                      style:
                          const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            subtitle: Text(_ago(a['verified_at']),
                style: TextStyle(
                    fontSize: 12, color: Colors.grey.shade500)),
            onTap: () async {
              final stats =
                  await _supabase.publicStats(a['user_id']);
              if (stats != null && mounted) _showProfile(stats);
            },
          );
        },
      ),
    );
  }

  Widget _empty(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600)),
        ),
      );

  // ---------- public profile ----------

  void _showProfile(Map<String, dynamic> r) {
    final since = DateTime.tryParse(r['member_since'] ?? '');
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _avatar(r, radius: 30, fontSize: 26),
          const SizedBox(height: 10),
          Text(r['display_name'],
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w900)),
          if (since != null)
            Text('Nomad since ${DateFormat('MMM yyyy').format(since)}',
                style: TextStyle(
                    fontSize: 12, color: Colors.grey.shade600)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 22, vertical: 10),
            decoration: BoxDecoration(
                gradient: Brand.gradient,
                borderRadius: BorderRadius.circular(16)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.monetization_on,
                  color: Brand.amber, size: 24),
              const SizedBox(width: 8),
              Text('${r['coins']} coins',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900)),
            ]),
          ),
          const SizedBox(height: 18),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            _stat(Icons.rate_review_outlined, r['reviews'], 'Reviews'),
            _stat(Icons.verified_outlined, r['confirms'], 'Confirms'),
            _stat(Icons.speed, r['wifi_tests'], 'WiFi tests'),
            _stat(Icons.key, r['wifi_logins'], 'WiFi logins'),
          ]),
        ]),
      ),
    );
  }

  Widget _avatar(Map<String, dynamic> r,
      {double radius = 16, double fontSize = 14}) {
    final url = r['avatar_url'] as String?;
    return CircleAvatar(
      radius: radius,
      backgroundColor: Brand.red.withValues(alpha: .1),
      backgroundImage: url != null ? NetworkImage(url) : null,
      child: url == null
          ? Text(
              ((r['display_name'] ?? 'N') as String)
                  .substring(0, 1)
                  .toUpperCase(),
              style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w900,
                  color: Brand.red))
          : null,
    );
  }

  Widget _stat(IconData icon, dynamic value, String label) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: Brand.charcoal),
          const SizedBox(height: 4),
          Text('${value ?? 0}',
              style: const TextStyle(
                  fontWeight: FontWeight.w900, fontSize: 17)),
          Text(label,
              style: TextStyle(
                  fontSize: 11, color: Colors.grey.shade600)),
        ],
      );
}
