import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config.dart';
import '../services/analytics_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';

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
  int _tab = 0;

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
    return Scaffold(
      appBar: AppBar(title: const Text('Leaderboard')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: _segmentedTabs(),
        ),
        Expanded(child: _tab == 0 ? _topList() : _liveFeed()),
      ]),
    );
  }

  /// Field-gray track, white active segment; Live carries a red dot.
  Widget _segmentedTabs() {
    Widget seg(int i, String label, {bool redDot = false}) {
      final active = _tab == i;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _tab = i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            height: 38,
            decoration: BoxDecoration(
              color: active ? Brand.surface : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              boxShadow: active ? Brand.shadowResting : null,
            ),
            child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: active
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: active
                              ? Brand.ink
                              : Brand.inkSecondary)),
                  if (redDot) ...[
                    const SizedBox(width: 6),
                    Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                            color: Brand.accent,
                            shape: BoxShape.circle)),
                  ],
                ]),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: Brand.field, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        seg(0, 'Top nomads'),
        seg(1, 'Live', redDot: true),
      ]),
    );
  }

  // ---------- top nomads ----------

  Widget _topList() {
    final top = _top;
    if (top == null) {
      return const Center(
          child: CircularProgressIndicator(color: Brand.accent));
    }
    if (top.isEmpty) {
      return _empty('No coins earned yet.\nBe the first on the board!');
    }
    final myId = _supabase.currentUser?.id;
    final onBoard = top.any((r) => r['user_id'] == myId);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          ...top.asMap().entries.map((e) =>
              _rankCard(e.value, e.key + 1, e.value['user_id'] == myId)),
          if (!onBoard) ...[
            const SizedBox(height: 10),
            DashedBorderBox(
              radius: 16,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 18),
                child: Column(children: [
                  const Text('Your rank: not on the board yet',
                      style: TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(
                      'Review a space to earn your first '
                      '${AppConfig.coinsNewVenue} coins',
                      style: const TextStyle(
                          fontSize: 13, color: Brand.inkMuted)),
                ]),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _rankCard(Map<String, dynamic> r, int rank, bool isMe) {
    final first = rank == 1;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: first
                ? const Color(0x80F4B23E)
                : isMe
                    ? Brand.accent.withValues(alpha: .4)
                    : Brand.border),
        boxShadow: first
            ? const [
                BoxShadow(
                    color: Color(0x24F4B23E),
                    blurRadius: 12,
                    offset: Offset(0, 3))
              ]
            : Brand.shadowResting,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showProfile(r),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            _medalAvatar(r, rank),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        (r['display_name'] ?? 'Nomad') +
                            (isMe ? '  (you)' : ''),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                        '${r['verified_count']} verified contribution'
                        '${r['verified_count'] == 1 ? '' : 's'}',
                        style: const TextStyle(
                            fontSize: 12.5, color: Brand.inkMuted)),
                  ]),
            ),
            const CoinDot(size: 14),
            const SizedBox(width: 6),
            Text('${r['coins']}',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 16)),
          ]),
        ),
      ),
    );
  }

  Widget _medalAvatar(Map<String, dynamic> r, int rank) {
    final medal = switch (rank) {
      1 => Brand.gold,
      2 => const Color(0xFFC3CBD4),
      3 => const Color(0xFFCD9A6B),
      _ => null,
    };
    return SizedBox(
      width: 54,
      height: 54,
      child: Stack(clipBehavior: Clip.none, children: [
        Container(
          width: 54,
          height: 54,
          decoration: rank == 1
              ? BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Brand.gold, width: 2))
              : null,
          child: Center(
            child: NomadAvatar(
                name: r['display_name'],
                photoUrl: r['avatar_url'],
                radius: 24),
          ),
        ),
        if (medal != null)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: medal,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: Text('$rank',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700)),
            ),
          ),
      ]),
    );
  }

  // ---------- live feed ----------

  static const _kindVerb = {
    'new_venue': 'reviewed',
    'confirm': 'confirmed',
    'wifi_test': 'tested the wifi at',
    'wifi_login': 'shared the wifi for',
  };

  static const _kindCoins = {
    'new_venue': AppConfig.coinsNewVenue,
    'wifi_test': AppConfig.coinsWifiTest,
    'wifi_login': AppConfig.coinsWifiLogin,
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
          child: CircularProgressIndicator(color: Brand.accent));
    }
    if (act.isEmpty) {
      return _empty('No activity yet.\nEvery verified contribution '
          'shows up here, live.');
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
        itemCount: act.length,
        separatorBuilder: (_, __) =>
            const Divider(height: 1, color: Brand.hairline),
        itemBuilder: (_, i) {
          final a = act[i];
          final verb = _kindVerb[a['kind']] ?? 'updated';
          final coins = _kindCoins[a['kind']];
          final place = [
            if (a['venue_name'] != null) a['venue_name'],
            if (a['city'] != null) a['city'],
          ].join(', ');
          return InkWell(
            onTap: () async {
              final stats = await _supabase.publicStats(a['user_id']);
              if (stats != null && mounted) _showProfile(stats);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    NomadAvatar(
                        name: a['display_name'],
                        photoUrl: a['avatar_url'],
                        radius: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            RichText(
                              text: TextSpan(
                                style: const TextStyle(
                                    fontFamily: 'InstrumentSans',
                                    color: Brand.ink,
                                    fontSize: 14,
                                    height: 1.4),
                                children: [
                                  TextSpan(
                                      text: a['display_name'],
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  TextSpan(
                                      text: ' $verb ',
                                      style: const TextStyle(
                                          color: Brand.inkSecondary)),
                                  TextSpan(
                                      text: place.isEmpty
                                          ? 'a space'
                                          : place,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                            const SizedBox(height: 5),
                            Row(children: [
                              Text(_ago(a['verified_at']),
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: Brand.inkMuted)),
                              if (coins != null) ...[
                                const SizedBox(width: 8),
                                CoinChip('+$coins', height: 20),
                              ],
                            ]),
                          ]),
                    ),
                  ]),
            ),
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
              style: const TextStyle(color: Brand.inkSecondary)),
        ),
      );

  // ---------- public profile ----------

  void _showProfile(Map<String, dynamic> r) {
    final since = DateTime.tryParse(r['member_since'] ?? '');
    showModalBottomSheet(
      context: context,
      backgroundColor: Brand.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          NomadAvatar(
              name: r['display_name'],
              photoUrl: r['avatar_url'],
              radius: 30),
          const SizedBox(height: 10),
          Text(r['display_name'] ?? 'Nomad',
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w700)),
          if (since != null)
            Text('Nomad since ${DateFormat('MMM yyyy').format(since)}',
                style: const TextStyle(
                    fontSize: 12, color: Brand.inkMuted)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 22, vertical: 10),
            decoration: BoxDecoration(
                color: Brand.goldTint,
                borderRadius: BorderRadius.circular(16)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const CoinDot(size: 18),
              const SizedBox(width: 8),
              Text('${r['coins']} coins',
                  style: const TextStyle(
                      color: Brand.ink,
                      fontSize: 20,
                      fontWeight: FontWeight.w700)),
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

  Widget _stat(IconData icon, dynamic value, String label) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: Brand.ink),
          const SizedBox(height: 4),
          Text('${value ?? 0}',
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 17)),
          Text(label,
              style: const TextStyle(
                  fontSize: 11, color: Brand.inkMuted)),
        ],
      );
}
