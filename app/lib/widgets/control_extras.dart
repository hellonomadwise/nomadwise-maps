import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/google_usage_screen.dart';
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
  // GitHub runs scheduled jobs on a best-effort basis and often starts
  // the frequent ones late, so these only turn amber after a real gap.
  _Job('Website push', 'webflow_push.yml', Duration(hours: 3)),
  _Job('Stripe plans', 'stripe_sync.yml', Duration(hours: 8)),
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => const GoogleUsageScreen()));
                      },
                      icon: const Icon(Icons.receipt_long_outlined, size: 16),
                      label: const Text(
                          'What it was spent on, and pause or limit it')),
                ),
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
                        'Last ran ${_when(r.at)}. GitHub sometimes starts '
                            'scheduled jobs late; worth a look if it stays '
                            'like this')
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
                : 'About £${spent.toStringAsFixed(2)} at list price'
                    '${limit == null ? '' : ' (limit £${limit.toStringAsFixed(0)} a day)'}'
                    '${over ? ': limit reached' : '. Google\'s free calls for the month may cover it: tap below'}',
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

/// The money line at the top of Owners, read left to right as a
/// funnel (Jonathan, 5 Oct 2026; migration 138): pages claimed,
/// Verified, really paying through Stripe, the monthly income in
/// euros and the total collected. Then what renews in the next 30
/// days and who switched to Free lately and why.
///
/// "Paying" counts a running Stripe subscription whose last payment
/// was above zero. A listing made Verified by hand does not count.
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

  /// The numbers last read, kept while the app is open: coming back
  /// to the tab shows them at once while they are read again.
  static Map<String, dynamic>? _last;

  /// The funnel's numbers; null until read, or when they cannot be.
  Map<String, dynamic>? _money = _last;
  bool _moneyLoaded = _last != null;

  @override
  void initState() {
    super.initState();
    _loadMoney();
    _supabase.billingSwitches().then((r) {
      if (mounted) setState(() => _switches = r);
    });
  }

  @override
  void didUpdateWidget(covariant MoneyCard old) {
    super.didUpdateWidget(old);
    // The control centre reloaded (a plan was changed, say): read the
    // numbers again.
    if (!identical(old.verified, widget.verified)) _loadMoney();
  }

  void _loadMoney() {
    _supabase.adminMoney().then((r) {
      if (!mounted) return;
      setState(() {
        // A failed re-read keeps the numbers already shown.
        if (r != null || !_moneyLoaded) _money = r;
        if (r != null) _last = r;
        _moneyLoaded = true;
      });
    });
  }

  static int _n(dynamic x) => x is num ? x.toInt() : 0;
  static num _amount(dynamic x) => x is num ? x : 0;

  static const _symbols = {'EUR': '€', 'GBP': '£', 'USD': r'$', 'AUD': r'A$'};

  /// "€1,234.50", "£13", "120 THB": cents only when there are any.
  static String _cash(num v, String currency) {
    final whole = v == v.roundToDouble();
    final text = NumberFormat(whole ? '#,##0' : '#,##0.00', 'en_US').format(v);
    final code = currency.trim().toUpperCase();
    final symbol = _symbols[code];
    return symbol != null ? '$symbol$text' : '$text $code'.trim();
  }

  /// "33%" of a part in a whole; "" when there is no whole.
  static String _share(int part, int whole) {
    if (whole <= 0) return '';
    final pct = part * 100 / whole;
    if (pct > 0 && pct < 1) return 'under 1%';
    return '${pct.round()}%';
  }

  /// Money in other currencies that our price list cannot turn into
  /// euros: "£13, 120 THB".
  static String _others(dynamic rows) => [
        for (final r in (rows is List ? rows : const []))
          if (r is Map) _cash(_amount(r['amount']), '${r['currency'] ?? ''}'),
      ].join(', ');

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        // the room inside the card: 16 + 16 padding, 1 + 1 border
        final inner = box.maxWidth - 34;
        // two tiles side by side on a narrow phone
        return _card(box.maxWidth.isFinite && inner < 312
            ? ((inner - 12) / 2).floorToDouble().clamp(96.0, 150.0).toDouble()
            : 150.0);
      });

  Widget _card(double tileWidth) {
    final m = _money;
    final verifiedShown = widget.verified
        .where((x) => (x['listing_tier'] ?? 'free') != 'free')
        .length;
    final cancels = _switches.where((s) => s['action'] == 'cancel').toList();

    Widget stat(String n, String label, [String note = '']) => SizedBox(
          width: tileWidth,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            Text(label,
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Brand.inkSecondary)),
            if (note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(note,
                    style:
                        const TextStyle(fontSize: 11, color: Brand.inkMuted)),
              ),
          ]),
        );

    final tiles = <Widget>[];
    final lines = <String>[];
    if (m == null) {
      // Not read yet, or the database change is not in: what is known.
      tiles.add(stat('$verifiedShown', 'Verified'));
      lines.add(_moneyLoaded
          ? 'The payment numbers could not be read just now.'
          : 'Reading the payment numbers.');
    } else {
      final live = _n(m['live']);
      final claimed = _n(m['claimed']);
      final claimedLive =
          m['claimed_live'] is num ? _n(m['claimed_live']) : claimed;
      final verified = _n(m['verified']);
      final verifiedClaimed = _n(m['verified_claimed']);
      final paying = _n(m['paying']);
      final unmatched = _n(m['paying_unmatched']);
      final monthly = _n(m['paying_monthly']);
      final yearly = _n(m['paying_yearly']);
      final ending = _n(m['ending']);
      final retrying = _n(m['retrying']);
      final byUs = verified - paying;
      final exact = m['exact'] != false;
      final mrrOther = _others(m['mrr_other']);
      final collectedOther = _others(m['collected_other']);
      final renewing = [
        for (final r in (m['renewing'] is List ? m['renewing'] as List : const []))
          if (r is Map) r,
      ];

      tiles.addAll([
        stat(
            '$claimed',
            'pages claimed',
            live > 0
                ? '${claimedLive != claimed ? '$claimedLive of them live, ' : ''}'
                    '${_share(claimedLive, live)} of '
                    '${NumberFormat('#,##0', 'en_US').format(live)} live pages'
                : ''),
        stat(
            '$verified',
            'Verified',
            verified == 0
                ? ''
                : verifiedClaimed != verified
                    // some were made Verified on a page nobody claimed
                    ? '$verifiedClaimed of them on a claimed page'
                    : claimed > 0
                        ? '${_share(verified, claimed)} of the claimed pages'
                        : ''),
        stat(
            '$paying',
            'paying through Stripe',
            verified == 0
                ? ''
                : paying == 0
                    ? 'none of the Verified yet'
                    : '${_share(paying, verified)} of the Verified'),
        stat(
            _cash(_amount(m['mrr_eur']), 'EUR'),
            'a month (MRR)',
            [
              if (monthly + yearly > 0)
                '$monthly on the monthly plan, $yearly on the yearly',
              if (mrrOther.isNotEmpty) 'plus $mrrOther',
            ].join(', ')),
        stat(
            _cash(_amount(m['collected_eur']), 'EUR'),
            'collected so far',
            [
              if (collectedOther.isNotEmpty) 'plus $collectedOther',
              exact ? 'refunds taken off' : 'some first payments only',
            ].join(', ')),
      ]);

      if (byUs > 0) {
        lines.add(byUs == 1
            ? '1 Verified listing pays nothing (made Verified by us, or on '
                'a free code).'
            : '$byUs Verified listings pay nothing (made Verified by us, or '
                'on a free code).');
      }
      if (unmatched > 0) {
        lines.add(unmatched == 1
            ? '1 more subscription is paying but is not attached to a '
                'Verified listing (a claim waiting for your decision, a '
                'payment to match, or a listing set back to free by hand). '
                'Its money is counted.'
            : '$unmatched more subscriptions are paying but are not '
                'attached to a Verified listing (claims waiting for your '
                'decision, payments to match, or listings set back to free '
                'by hand). Their money is counted.');
      }
      if (retrying > 0) {
        lines.add(retrying == 1
            ? '1 paying subscription had its latest payment fail. Stripe is '
                'trying the card again, so it still counts for now.'
            : '$retrying paying subscriptions had their latest payment '
                'fail. Stripe is trying the cards again, so they still '
                'count for now.');
      }
      if (ending > 0) {
        lines.add(ending == 1
            ? '1 paying subscription ends when its period is up.'
            : '$ending paying subscriptions end when their period is up.');
      }
      if (renewing.isNotEmpty) {
        final names = [
          for (final r in renewing.take(5))
            '${r['name'] ?? 'A space'} '
                '(${_dayOf(r['renews_at'])})',
        ].join(', ');
        final more =
            renewing.length > 5 ? ' and ${renewing.length - 5} more' : '';
        lines.add('Renewing in the next 30 days: $names$more.');
      }
      if (!exact) {
        lines.add('For some subscriptions the total counts the first payment '
            'only, so renewals and refunds may be missing. If this stays, '
            'give the Stripe key the "Charges and Refunds: Read" '
            'permission.');
      }
      lines.add('Pounds and dollars are turned into euros using our own '
          'price list, not the day\'s exchange rate. Stripe\'s fees are '
          'not taken off.${_checked(m['checked_at'])}');
    }

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
        Wrap(spacing: 12, runSpacing: 12, children: tiles),
        if (lines.isNotEmpty) const SizedBox(height: 10),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(l,
                style:
                    const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
          ),
        if (cancels.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
              cancels.length == 1
                  ? '1 switched to Free in the last 90 days:'
                  : '${cancels.length} switched to Free in the last 90 days:',
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Brand.inkSecondary)),
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

  /// "22 Oct" for a date as the database sends it; "" when it is none.
  static String _dayOf(dynamic x) {
    final t = DateTime.tryParse('${x ?? ''}');
    return t == null ? '' : DateFormat('d MMM').format(t);
  }

  /// " Stripe last read 5 Oct, 14:17." for the last time the payments
  /// were read; "" when they have not been.
  static String _checked(dynamic x) {
    final t = DateTime.tryParse('${x ?? ''}')?.toLocal();
    return t == null
        ? ''
        : ' Stripe last read ${DateFormat('d MMM, HH:mm').format(t)}.';
  }
}
