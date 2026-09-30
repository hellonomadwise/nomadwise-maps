import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

// Control centre extras (30 Sep 2026): the health check on the title
// bar and the money line at the top of Owners.

// ------------------------------------------------------------- health

/// One automatic job and how its last run went.
class _Job {
  final String label;
  final String file;
  final Duration late; // no finished run for this long = worth a look
  const _Job(this.label, this.file, this.late);
}

const _jobs = [
  _Job('Nightly jobs', 'enrich.yml', Duration(hours: 27)),
  _Job('Website push', 'webflow_push.yml', Duration(hours: 1)),
  _Job('Stripe plans', 'stripe_sync.yml', Duration(hours: 3)),
  _Job('App build', 'build.yml', Duration(days: 3650)),
];

class _Run {
  final _Job job;
  final String? conclusion; // success, failure, cancelled, null = running
  final String status;
  final DateTime? at;
  final String? url;
  _Run(this.job, this.conclusion, this.status, this.at, this.url);

  bool get running => status != 'completed';
  bool get failed =>
      !running && conclusion != null && conclusion != 'success' &&
      conclusion != 'skipped';
  bool get isLate =>
      at != null && DateTime.now().difference(at!) > job.late;
}

/// The title bar's health check: a heart with a green, amber or red dot.
/// Reads the last run of each automatic job straight from GitHub (the
/// repository is public, no key needed) and today's Google spend. Tap
/// for the details and links to each run.
class HealthButton extends StatefulWidget {
  const HealthButton({super.key});

  @override
  State<HealthButton> createState() => _HealthButtonState();
}

class _HealthButtonState extends State<HealthButton> {
  static const _repo = 'hellonomadwise/nomadwise-maps';
  // Kept between visits for ten minutes: GitHub allows 60 unsigned
  // requests an hour from one connection.
  static List<_Run>? _cache;
  static DateTime? _cachedAt;

  final _supabase = SupabaseService();
  List<_Run>? _runs;
  Map<String, dynamic>? _google;
  bool _unreachable = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    final fresh = _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < const Duration(minutes: 10);
    if (!force && fresh && _cache != null) {
      _runs = _cache;
    } else {
      final out = <_Run>[];
      var failedCalls = 0;
      for (final j in _jobs) {
        try {
          final r = await http
              .get(
                  Uri.parse('https://api.github.com/repos/$_repo/actions/'
                      'workflows/${j.file}/runs?per_page=1'),
                  headers: {'Accept': 'application/vnd.github+json'})
              .timeout(const Duration(seconds: 8));
          if (r.statusCode != 200) {
            failedCalls++;
            continue;
          }
          final runs = (jsonDecode(r.body)['workflow_runs'] as List?) ?? [];
          if (runs.isEmpty) continue;
          final x = runs.first as Map;
          out.add(_Run(
              j,
              x['conclusion'] as String?,
              '${x['status']}',
              DateTime.tryParse('${x['updated_at']}')?.toLocal(),
              x['html_url'] as String?));
        } catch (_) {
          failedCalls++;
        }
      }
      _unreachable = failedCalls == _jobs.length;
      if (!_unreachable) {
        _cache = out;
        _cachedAt = DateTime.now();
      }
      _runs = out;
    }
    final g = await _supabase.googleBudget();
    if (mounted) setState(() => _google = g);
  }

  Color get _dot {
    final runs = _runs;
    if (runs == null || _unreachable) return Brand.inkFaint;
    if (runs.any((r) => r.failed)) return Brand.accent;
    final g = _google;
    if (g != null && g['over'] == true) return Brand.accent;
    if (runs.any((r) => r.isLate)) return Brand.gold;
    return Brand.success;
  }

  String _when(DateTime? t) {
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return 'today ${DateFormat('HH:mm').format(t)}';
    if (d.inHours < 48) return 'yesterday ${DateFormat('HH:mm').format(t)}';
    return DateFormat('d MMM HH:mm').format(t);
  }

  void _open() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Brand.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Health check',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                const SizedBox(height: 4),
                const Text(
                    'The last run of each automatic job, and today\'s Google '
                    'spend. Red means it failed: open it for the reason.',
                    style: TextStyle(
                        fontSize: 12.5, color: Brand.inkSecondary)),
                const SizedBox(height: 12),
                if (_unreachable)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                        'GitHub did not answer just now. Try again in a few '
                        'minutes.',
                        style: TextStyle(color: Brand.inkMuted)),
                  ),
                for (final j in _jobs) _jobRow(j),
                const Divider(height: 22, color: Brand.hairline),
                _googleRow(),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _load(force: true);
                      },
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Check again')),
                ),
              ]),
        ),
      ),
    );
  }

  Widget _jobRow(_Job j) {
    final r = _runs?.where((x) => x.job.file == j.file).firstOrNull;
    final (IconData icon, Color color, String text) = r == null
        ? (Icons.help_outline, Brand.inkMuted, 'No run found')
        : r.running
            ? (Icons.autorenew, Brand.inkSecondary, 'Running now')
            : r.failed
                ? (Icons.cancel, Brand.accent,
                    'Failed ${_when(r.at)}')
                : r.isLate
                    ? (Icons.schedule, Brand.goldTextDark,
                        'Last ran ${_when(r.at)}, later than expected')
                    : (Icons.check_circle, Brand.success,
                        'Ran fine ${_when(r.at)}');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        SizedBox(
          width: 110,
          child: Text(j.label,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
        ),
        Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, color: color))),
        if (r?.url != null)
          IconButton(
              tooltip: 'Open on GitHub',
              visualDensity: VisualDensity.compact,
              onPressed: () => launchUrl(Uri.parse(r!.url!),
                  mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_new, size: 16)),
      ]),
    );
  }

  Widget _googleRow() {
    final g = _google;
    final spent = (g?['spent_gbp'] as num?)?.toDouble();
    final limit = (g?['limit_gbp'] as num?)?.toDouble();
    final over = g?['over'] == true;
    return Row(children: [
      Icon(Icons.payments_outlined,
          size: 18, color: over ? Brand.accent : Brand.inkSecondary),
      const SizedBox(width: 10),
      const SizedBox(
        width: 110,
        child: Text('Google today',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
      ),
      Expanded(
        child: Text(
            spent == null
                ? 'Not available'
                : 'About £${spent.toStringAsFixed(2)}'
                    '${limit == null ? '' : ' of the £${limit.toStringAsFixed(0)} daily limit'}'
                    '${over ? ': limit reached' : ''}',
            style: TextStyle(
                fontSize: 13,
                color: over ? Brand.accent : Brand.inkSecondary)),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Health check',
        onPressed: _runs == null ? null : _open,
        icon: Stack(clipBehavior: Clip.none, children: [
          const Icon(Icons.monitor_heart_outlined),
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: _dot,
                shape: BoxShape.circle,
                border: Border.all(color: Brand.surface, width: 1.5),
              ),
            ),
          ),
        ]),
      );
}

// -------------------------------------------------------------- money

/// The money line at the top of Owners: how many pay, what renews in
/// the next 30 days, and who switched to Free lately and why.
class MoneyCard extends StatefulWidget {
  /// The Verified listings the control centre already loaded.
  final List<Map<String, dynamic>> verified;
  const MoneyCard({super.key, required this.verified});

  @override
  State<MoneyCard> createState() => _MoneyCardState();
}

class _MoneyCardState extends State<MoneyCard> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>> _switches = [];

  @override
  void initState() {
    super.initState();
    _supabase.billingSwitches().then((r) {
      if (mounted) setState(() => _switches = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final v = widget.verified
        .where((x) => (x['listing_tier'] ?? 'free') != 'free')
        .toList();
    final paying = v.where((x) => x['listing_paid_at'] != null).length;
    final renewing = v.where((x) {
      final t = DateTime.tryParse('${x['listing_renews_at']}');
      return t != null &&
          !t.isBefore(DateTime(now.year, now.month, now.day)) &&
          t.isBefore(now.add(const Duration(days: 30)));
    }).toList()
      ..sort((a, b) => '${a['listing_renews_at']}'
          .compareTo('${b['listing_renews_at']}'));
    final cancels = _switches.where((s) => s['action'] == 'cancel').toList();

    Widget stat(String n, String label) => SizedBox(
          width: 150,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            Text(label,
                style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
          ]),
        );

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Money',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        const SizedBox(height: 10),
        Wrap(spacing: 12, runSpacing: 10, children: [
          stat('${v.length}', 'Verified'),
          stat('$paying', 'paying through Stripe'),
          stat('${renewing.length}', 'renew in the next 30 days'),
          stat('${cancels.length}', 'switched to Free, last 90 days'),
        ]),
        if (renewing.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
              'Renewing: ${renewing.take(5).map((x) => '${x['name']} '
                  '(${DateFormat('d MMM').format(DateTime.parse('${x['listing_renews_at']}'))})').join(', ')}'
              '${renewing.length > 5 ? ' and ${renewing.length - 5} more' : ''}',
              style:
                  const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        ],
        if (cancels.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final c in cancels.take(5))
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                  '${(c['venue'] is Map ? c['venue']['name'] : null) ?? 'A space'}'
                  ' switched to Free on '
                  '${DateFormat('d MMM').format(DateTime.parse('${c['created_at']}').toLocal())}'
                  '${(c['reason'] ?? '').toString().isNotEmpty ? ': "${c['reason']}"' : ', no reason given'}',
                  style: const TextStyle(
                      fontSize: 12.5, color: Brand.inkSecondary)),
            ),
        ],
      ]),
    );
  }
}
