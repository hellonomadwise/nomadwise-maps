import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Admin only: what Google costs and exactly why. Every Google Places
/// call we make is counted by the job that made it and the line it
/// appears under on the Google bill (migration 89). This page turns
/// that into money, job by job, for today and any day before, says in
/// plain words what each job does, and lets a founder change the daily
/// limit or pause a job (migration 111).
class GoogleUsageScreen extends StatefulWidget {
  const GoogleUsageScreen({super.key});
  @override
  State<GoogleUsageScreen> createState() => _GoogleUsageScreenState();
}

/// What each job is, why it calls Google, and what keeps it in check.
class _JobInfo {
  final String name;
  final String what;
  final bool pausable;
  const _JobInfo(this.name, this.what, {this.pausable = true});
}

const _jobs = <String, _JobInfo>{
  'nightly refresh': _JobInfo(
      'Nightly refresh',
      'Every night, re-checks the Google details of spaces last checked '
          'more than 21 days ago: rating, opening hours, open or closed, '
          'and the photo list. Needed because Google photo links stop '
          'working after about four weeks. At most 300 spaces a run; it '
          'also runs when its files change on GitHub.'),
  'website sync': _JobInfo(
      'Nightly website sync',
      'Every night, fills in opening hours and ratings for nomadwise.io '
          'pages that have none yet, at most 40 a night.'),
  'website push': _JobInfo(
      'Website push',
      'Every 10 minutes: when a page is about to be created for a new '
          'space, fetches its hours and rating once.'),
  'photo suggestions': _JobInfo(
      'Photo suggestions',
      'Picks the best photos for new pages by looking at the photo files.'),
  'photo check': _JobInfo(
      'Nightly photo check',
      'Every night, marks food and drink close-ups so they are not used '
          'as a space\'s main photo.'),
  'candidate evidence': _JobInfo(
      'Candidate evidence',
      'Every night, for the Candidates list: asks Google\'s search for '
          'places to work in the cities being worked on, and looks up the '
          'places other sites name to see they are still open. Kept inside '
          'Google\'s free monthly amount for this kind of call (Text '
          'Search Pro), with part of it left for the app: the Candidates '
          'list says how much is used.'),
  'app': _JobInfo(
      'Visitors in the app',
      'People using the map: opening a space (live hours and rating), '
          'seeing a photo for the first time (then saved for everyone), '
          'and searching for places. Paused, the app shows the saved '
          'details instead.'),
  'webflow import': _JobInfo('Webflow import',
      'A one-off import of pages from Webflow.', pausable: false),
};

/// Google's list price per 1,000 calls in US dollars, the same list as
/// the database (migration 90). Lines not listed are free.
const _priceUsd = <String, double>{
  'Place Details Essentials': 5,
  'Place Details Pro': 17,
  'Place Details Enterprise': 20,
  'Place Details Enterprise + Atmosphere': 25,
  'Place Details Photos': 7,
  'Text Search Pro': 32,
  'Text Search Enterprise': 35,
  'Text Search Enterprise + Atmosphere': 40,
  'Nearby Search Pro': 32,
  'Nearby Search Enterprise': 35,
  'Nearby Search Enterprise + Atmosphere': 40,
  'Autocomplete Requests': 2.83,
};

/// Google's free calls each month, per bill line, for every billing
/// account (Google Maps Platform pricing, March 2025 onwards: 10,000
/// for Essentials lines, 5,000 for Pro, 1,000 for Enterprise and
/// photos; IDs-only calls are always free). Calls within these cost
/// nothing; only calls beyond them are billed. The allowance resets on
/// the 1st of each month.
const _freePerMonth = <String, int>{
  'Place Details Essentials': 10000,
  'Place Details Pro': 5000,
  'Place Details Enterprise': 1000,
  'Place Details Enterprise + Atmosphere': 1000,
  'Place Details Photos': 1000,
  'Text Search Pro': 5000,
  'Text Search Enterprise': 1000,
  'Text Search Enterprise + Atmosphere': 1000,
  'Nearby Search Pro': 5000,
  'Nearby Search Enterprise': 1000,
  'Nearby Search Enterprise + Atmosphere': 1000,
  'Autocomplete Requests': 10000,
  'Dynamic Maps': 10000,
};

/// What each bill line means, in plain words.
const _lineWords = <String, String>{
  'Place Details Essentials': 'address and location',
  'Place Details Essentials (IDs Only)': 'photo list only (free)',
  'Place Details Pro': 'name, type, open or closed, photo list',
  'Place Details Enterprise': 'opening hours and rating',
  'Place Details Enterprise + Atmosphere': 'reviews and extras',
  'Place Details Photos': 'a photo file',
  'Text Search Pro': 'a place search by name',
  'Autocomplete Requests': 'search suggestions while typing',
  'Dynamic Maps': 'the map drawn on screen',
};

class _GoogleUsageScreenState extends State<GoogleUsageScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _rows;
  Map<String, dynamic>? _budget;
  String? _error;
  final Set<String> _busy = {};

  double get _fx => (_budget?['fx'] as num?)?.toDouble() ?? 0.75;
  Set<String> get _paused => {
        for (final x in (_budget?['paused'] as List? ?? const [])) '$x',
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _supabase.googleBudget().then((b) {
      if (mounted) setState(() => _budget = b);
    });
    try {
      final rows = await _supabase.apiUsage(days: 35);
      _computePaid(rows);
      if (mounted) {
        setState(() {
          _rows = rows;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _rows = [];
          _error = '$e';
        });
      }
    }
  }

  int _n(dynamic v) => (v as num?)?.toInt() ?? 0;

  /// For each day and bill line, the share of that day's calls that
  /// fall beyond the month's free allowance (0 = all free, 1 = all
  /// billed). The allowance is used up in date order within each
  /// calendar month, the way Google applies it.
  Map<String, Map<String, double>> _paid = {};

  void _computePaid(List<Map<String, dynamic>> rows) {
    // month -> line -> day -> calls
    final m = <String, Map<String, Map<String, int>>>{};
    for (final r in rows) {
      final day = '${r['day']}';
      if (day.length < 7) continue;
      final mon = day.substring(0, 7);
      final sku = '${r['sku']}';
      final d = ((m[mon] ??= {})[sku] ??= {});
      d[day] = (d[day] ?? 0) + _n(r['calls']);
    }
    final out = <String, Map<String, double>>{};
    m.forEach((mon, lines) {
      lines.forEach((sku, days) {
        final free = _freePerMonth[sku] ?? 0;
        var used = 0;
        for (final day in days.keys.toList()..sort()) {
          final c = days[day]!;
          final before = used;
          used += c;
          final billed = (used - free).clamp(0, used) -
              (before - free).clamp(0, before);
          (out[day] ??= {})[sku] = c == 0 ? 0.0 : billed / c;
        }
      });
    });
    _paid = out;
  }

  /// What a day's calls on one line really cost after the allowance.
  double _real(String day, String sku, int calls) =>
      _gbp(sku, calls) * (_paid[day]?[sku] ?? 1);

  /// This month's calls per line, for the allowance card.
  Map<String, int> _monthUsed(List<Map<String, dynamic>> rows) {
    final mon = DateFormat('yyyy-MM').format(DateTime.now().toUtc());
    final out = <String, int>{};
    for (final r in rows.where((r) => '${r['day']}'.startsWith(mon))) {
      out['${r['sku']}'] = (out['${r['sku']}'] ?? 0) + _n(r['calls']);
    }
    return out;
  }

  double _gbp(String sku, int calls) =>
      calls * (_priceUsd[sku] ?? 0) / 1000 * _fx;

  String _money(double v) => v < 0.005 && v > 0
      ? 'under 1p'
      : '£${v.toStringAsFixed(2)}';

  String get _todayUtc =>
      DateFormat('yyyy-MM-dd').format(DateTime.now().toUtc());

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: const Text('Google calls')),
      body: rows == null
          ? const Center(child: CircularProgressIndicator(color: Brand.accent))
          : RefreshIndicator(
              onRefresh: _load,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
                    children: [
                      const Text(
                          'What Google costs and exactly why: every call, by '
                          'the job that made it and the line it appears under '
                          'on the Google bill. Each line shows its list price '
                          'and what it really costs once Google\'s free calls '
                          'for the month are taken off. Days are UTC. '
                          'Counting started 28 September 2026.',
                          style: TextStyle(
                              fontSize: 12.5, color: Brand.inkSecondary)),
                      const SizedBox(height: 12),
                      if (_error != null)
                        _note(_error!.contains('api_usage')
                            ? 'Not installed yet: migration 89 has not run. '
                                'Check the last build on GitHub.'
                            : 'Could not load: $_error'),
                      if (_budget != null) ...[
                        _limitCard(_budget!),
                        const SizedBox(height: 14),
                      ],
                      _allowanceCard(rows),
                      const SizedBox(height: 14),
                      _dayExplained(rows, _todayUtc, today: true),
                      const SizedBox(height: 14),
                      if (rows.isNotEmpty) ...[
                        _monthCard(rows),
                        const SizedBox(height: 14),
                        ..._days(rows),
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _note(String t) => Container(
        padding: const EdgeInsets.all(14),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
            color: Brand.goldTint, borderRadius: BorderRadius.circular(8)),
        child: Text(t,
            style: const TextStyle(fontSize: 13, color: Brand.goldTextDark)),
      );

  /// Today against the daily limit, with the limit changeable here.
  Widget _limitCard(Map<String, dynamic> b) {
    final spent = (b['spent_gbp'] as num?)?.toDouble() ?? 0;
    final lim = (b['limit_gbp'] as num?)?.toDouble() ?? 10;
    final loads = _n(b['map_loads']);
    final cap = _n(b['map_cap']);
    final over = b['over'] == true;
    final paused = _paused;
    return _box([
      Row(children: [
        const Expanded(
          child: Text('Daily limit',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        ),
        TextButton(
            onPressed: () => _changeLimit(lim),
            child: const Text('Change')),
      ]),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: lim == 0 ? 0 : (spent / lim).clamp(0.0, 1.0),
          minHeight: 8,
          backgroundColor: Brand.field,
          color: over ? Brand.accent : Brand.success,
        ),
      ),
      const SizedBox(height: 8),
      Text(
          over
              ? 'Lookups paused: about £${spent.toStringAsFixed(2)} of the '
                  '£${lim.toStringAsFixed(0)} limit used today. Google is not '
                  'asked again until midnight UTC.'
              : 'About £${spent.toStringAsFixed(2)} of the '
                  '£${lim.toStringAsFixed(0)} a day limit used today. At the '
                  'limit, every job and the app stop asking Google until '
                  'midnight UTC.',
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: over ? Brand.accent : Brand.ink)),
      const SizedBox(height: 4),
      Text('Map loads: $loads of the $cap a day cap (set in Google Cloud).',
          style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
      if (paused.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(
            'Paused: ${paused.map((k) => _jobs[k]?.name ?? k).join(', ')}.',
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Brand.goldTextDark)),
      ],
    ]);
  }

  Future<void> _changeLimit(double now) async {
    final ctl = TextEditingController(text: now.toStringAsFixed(0));
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Daily Google limit'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
              'Once today\'s lookups reach this, every job and the app stop '
              'asking Google until midnight UTC. Between £1 and £500.',
              style: TextStyle(fontSize: 13.5, height: 1.45)),
          const SizedBox(height: 12),
          TextField(
            controller: ctl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Limit a day', prefixText: '£'),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(
                  ctx, double.tryParse(ctl.text.trim().replaceAll(',', '.'))),
              child: const Text('Save')),
        ],
      ),
    );
    if (v == null) return;
    await _set('places_gbp_per_day', v,
        done: 'Daily limit set to £${v.toStringAsFixed(0)}.');
  }

  Future<void> _set(String key, num value, {required String done}) async {
    setState(() => _busy.add(key));
    try {
      final b = await _supabase.setGoogleControl(key, value);
      if (!mounted) return;
      setState(() => _budget = b ?? _budget);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      if (!mounted) return;
      final msg = '$e'.contains('between')
          ? 'The daily limit must be between £1 and £500.'
          : 'That did not save. If the app was just updated, try again in a '
              'few minutes.';
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Brand.accent));
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  /// One day's spend, job by job: what each job costs, the bill lines
  /// behind it with their calls and price, what the job is for, and
  /// (for today) a switch to pause it.
  Widget _dayExplained(List<Map<String, dynamic>> rows, String day,
      {bool today = false}) {
    final dayRows = rows.where((r) => '${r['day']}' == day).toList();
    // job -> sku -> calls / refused
    final calls = <String, Map<String, int>>{};
    final refused = <String, int>{};
    for (final r in dayRows) {
      final job = '${r['source']}';
      final sku = '${r['sku']}';
      (calls[job] ??= {})[sku] = (calls[job]![sku] ?? 0) + _n(r['calls']);
      refused[job] = (refused[job] ?? 0) + _n(r['errors']);
    }
    double jobGbp(String job) => calls[job]!
        .entries
        .fold(0.0, (a, e) => a + _gbp(e.key, e.value));
    final jobs = calls.keys.toList()
      ..sort((a, b) => jobGbp(b).compareTo(jobGbp(a)));
    final total = jobs.fold(0.0, (a, j) => a + jobGbp(j));
    double jobReal(String job) => calls[job]!
        .entries
        .fold(0.0, (a, e) => a + _real(day, e.key, e.value));
    final real = jobs.fold(0.0, (a, j) => a + jobReal(j));
    final when = DateTime.tryParse(day);
    final paused = _paused;
    // Jobs with nothing today still get their switch, so a pause can be
    // undone from here.
    final quiet = today
        ? _jobs.entries
            .where((e) => e.value.pausable && !calls.containsKey(e.key))
            .map((e) => e.key)
            .toList()
        : const <String>[];

    return _box([
      Text(
          today
              ? 'Today, explained'
              : (when == null ? day : DateFormat('EEEE d MMMM').format(when)),
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      const SizedBox(height: 2),
      if (jobs.isEmpty)
        Text('No Google calls yet${today ? ' today' : ''}.',
            style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary))
      else ...[
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(real < 0.005 ? '£0' : _money(real),
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: real < 0.005 ? Brand.success : Brand.ink)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                real < 0.005
                    ? 'real cost: all within Google\'s free calls this month '
                        '(${_money(total)} at list price)'
                    : 'real cost after Google\'s free calls '
                        '(${_money(total)} at list price)',
                style: const TextStyle(
                    fontSize: 12.5, color: Brand.inkSecondary)),
          ),
        ]),
        const SizedBox(height: 2),
        const Text('Biggest first.',
            style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
      ],
      for (final job in jobs) ...[
        const Divider(height: 22, color: Brand.hairline),
        _jobBlock(job, calls[job]!, refused[job] ?? 0, jobGbp(job), total,
            today: today, isPaused: paused.contains(job),
            day: day, real: jobReal(job)),
      ],
      if (quiet.isNotEmpty) ...[
        const Divider(height: 22, color: Brand.hairline),
        const Text('No calls today',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Brand.inkMuted)),
        for (final job in quiet)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Expanded(
                child: Text(_jobs[job]!.name,
                    style: const TextStyle(fontSize: 13)),
              ),
              _pauseSwitch(job, paused.contains(job)),
            ]),
          ),
      ],
    ]);
  }

  Widget _jobBlock(String job, Map<String, int> lines, int refused,
      double gbp, double total,
      {required bool today,
      required bool isPaused,
      required String day,
      required double real}) {
    final info = _jobs[job];
    final share = total <= 0 ? 0 : (gbp / total * 100).round();
    final sorted = lines.entries.toList()
      ..sort((a, b) => _gbp(b.key, b.value).compareTo(_gbp(a.key, a.value)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Text(info?.name ?? job,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(real < 0.005 ? 'Free' : _money(real),
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: real < 0.005 ? Brand.success : Brand.ink)),
          Text('${_money(gbp)} list',
              style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
        ]),
        if (total > 0) ...[
          const SizedBox(width: 6),
          SizedBox(
            width: 40,
            child: Text('$share%',
                textAlign: TextAlign.right,
                style:
                    const TextStyle(fontSize: 12, color: Brand.inkSecondary)),
          ),
        ],
      ]),
      if (info != null) ...[
        const SizedBox(height: 3),
        Text(info.what,
            style: const TextStyle(
                fontSize: 12.5, height: 1.45, color: Brand.inkSecondary)),
      ],
      const SizedBox(height: 8),
      for (final e in sorted)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Row(children: [
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: '${NumberFormat.decimalPattern().format(e.value)} × '
                          '${_lineWords[e.key] ?? e.key}'),
                  TextSpan(
                      text: '  ${e.key}',
                      style: const TextStyle(color: Brand.inkMuted)),
                ]),
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
            Builder(builder: (_) {
              final list = _gbp(e.key, e.value);
              final realLine = _real(day, e.key, e.value);
              if (list == 0) {
                return const Text('free',
                    style: TextStyle(fontSize: 12.5, color: Brand.success));
              }
              return Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: '${_money(list)} list  ',
                        style: const TextStyle(color: Brand.inkMuted)),
                    TextSpan(
                        text: realLine < 0.005 ? 'free' : _money(realLine),
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: realLine < 0.005
                                ? Brand.success
                                : Brand.ink)),
                  ]),
                  style: const TextStyle(fontSize: 12.5));
            }),
          ]),
        ),
      if (refused > 0)
        Text('$refused refused or not made (not charged)',
            style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
      if (today && (info?.pausable ?? false)) ...[
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: Text(
                isPaused
                    ? 'Paused: asks Google nothing until switched back on.'
                    : 'Running.',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: isPaused ? Brand.goldTextDark : Brand.success)),
          ),
          _pauseSwitch(job, isPaused),
        ]),
      ],
    ]);
  }

  Widget _pauseSwitch(String job, bool isPaused) {
    final key = 'pause:$job';
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(isPaused ? 'Paused' : 'On',
          style: const TextStyle(fontSize: 12, color: Brand.inkSecondary)),
      Switch(
        value: !isPaused,
        activeColor: Brand.success,
        onChanged: _busy.contains(key)
            ? null
            : (on) async {
                if (!on) {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text('Pause ${_jobs[job]?.name ?? job}?'),
                      content: Text(
                          '${_jobs[job]?.what ?? ''}\n\nWhile paused it asks '
                          'Google nothing, so whatever it keeps up to date '
                          'will slowly get older. Switch it back on here any '
                          'time.'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Keep it on')),
                        FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Pause')),
                      ],
                    ),
                  );
                  if (ok != true) return;
                }
                await _set(key, on ? 0 : 1,
                    done: on
                        ? '${_jobs[job]?.name ?? job} is back on.'
                        : '${_jobs[job]?.name ?? job} is paused.');
              },
      ),
    ]);
  }

  /// Google's free calls this month, line by line: how much of each
  /// allowance is used, and what is billed beyond it.
  Widget _allowanceCard(List<Map<String, dynamic>> rows) {
    final used = _monthUsed(rows);
    final now = DateTime.now().toUtc();
    final next = DateTime.utc(now.year, now.month + 1, 1);
    final lines = used.entries
        .where((e) => (_priceUsd[e.key] ?? (e.key == 'Dynamic Maps' ? 7 : 0)) > 0)
        .toList()
      ..sort((a, b) {
        double pct(MapEntry<String, int> e) =>
            e.value / (_freePerMonth[e.key] ?? 1);
        return pct(b).compareTo(pct(a));
      });
    return _box([
      Text(
          'Google\'s free calls in ${DateFormat('MMMM').format(now)}',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      const SizedBox(height: 2),
      Text(
          'Every month Google gives a set number of free calls on each line '
          'of the bill. Up to that number a call costs nothing; only calls '
          'beyond it are charged. Resets on ${DateFormat('d MMMM').format(next)}.',
          style: const TextStyle(
              fontSize: 12.5, height: 1.45, color: Brand.inkSecondary)),
      const SizedBox(height: 10),
      if (lines.isEmpty)
        const Text('No charged lines used yet this month.',
            style: TextStyle(fontSize: 13, color: Brand.inkMuted)),
      for (final e in lines) ...[
        Builder(builder: (_) {
          final free = _freePerMonth[e.key] ?? 0;
          final over = e.value - free;
          final pct =
              free == 0 ? 1.0 : (e.value / free).clamp(0.0, 1.0).toDouble();
          final usd = _priceUsd[e.key] ?? (e.key == 'Dynamic Maps' ? 7 : 0);
          final overGbp = over > 0 ? over * usd / 1000 * _fx : 0.0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(e.key,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                    Text(
                        over > 0
                            ? '${_money(overGbp)} beyond the free calls'
                            : 'free so far',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: over > 0 ? Brand.accent : Brand.success)),
                  ]),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: pct,
                      minHeight: 6,
                      backgroundColor: Brand.field,
                      color: pct >= 1
                          ? Brand.accent
                          : pct >= .8
                              ? Brand.gold
                              : Brand.success,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                      '${NumberFormat.decimalPattern().format(e.value)} of '
                      '${NumberFormat.decimalPattern().format(free)} free calls '
                      'used (${_lineWords[e.key] ?? e.key})',
                      style: const TextStyle(
                          fontSize: 11.5, color: Brand.inkMuted)),
                ]),
          );
        }),
      ],
      const Text(
          'The free calls belong to the whole Google billing account, so '
          'anything else on the same account (for example a map on another '
          'website) uses them too, and calls before 28 September 2026 were '
          'not counted here. Google\'s own billing page has the final word.',
          style: TextStyle(fontSize: 11.5, height: 1.4, color: Brand.inkFaint)),
    ]);
  }

  /// This month so far, per job, in money.
  Widget _monthCard(List<Map<String, dynamic>> rows) {
    final month = DateFormat('yyyy-MM').format(DateTime.now().toUtc());
    final byJob = <String, double>{};
    var maps = 0;
    var real = 0.0;
    for (final r in rows.where((r) => '${r['day']}'.startsWith(month))) {
      final sku = '${r['sku']}';
      if (sku == 'Dynamic Maps') maps += _n(r['calls']);
      byJob['${r['source']}'] =
          (byJob['${r['source']}'] ?? 0) + _gbp(sku, _n(r['calls']));
      real += _real('${r['day']}', sku, _n(r['calls']));
    }
    final jobs = byJob.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = jobs.fold(0.0, (a, e) => a + e.value);
    return _box([
      Text(
          'This month so far (${DateFormat('MMMM').format(DateTime.now())})',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
      const SizedBox(height: 4),
      Text(
          real < 0.005
              ? 'Real cost £0: everything is within Google\'s free calls. '
                  'At list price it would be ${_money(total)}.'
              : 'Real cost about ${_money(real)} after Google\'s free calls '
                  '(${_money(total)} at list price).',
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: real < 0.005 ? Brand.success : Brand.ink)),
      const SizedBox(height: 6),
      const Text('At list price, by job:',
          style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
      const SizedBox(height: 8),
      for (final e in jobs)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            Expanded(
                child: Text(_jobs[e.key]?.name ?? e.key,
                    style: const TextStyle(fontSize: 13))),
            Text(_money(e.value),
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13)),
          ]),
        ),
      if (maps > 0)
        Text('Plus $maps map loads, within their own 10,000 free a month.',
            style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
    ]);
  }

  /// One line per day with its cost; tap for the full explanation.
  List<Widget> _days(List<Map<String, dynamic>> rows) {
    final byDay = <String, double>{};
    final realDay = <String, double>{};
    final callsDay = <String, int>{};
    for (final r in rows) {
      final d = '${r['day']}';
      byDay[d] = (byDay[d] ?? 0) + _gbp('${r['sku']}', _n(r['calls']));
      realDay[d] = (realDay[d] ?? 0) + _real(d, '${r['sku']}', _n(r['calls']));
      callsDay[d] = (callsDay[d] ?? 0) + _n(r['calls']);
    }
    final days = byDay.keys.where((d) => d != _todayUtc).toList()
      ..sort((a, b) => b.compareTo(a));
    return [
      const Text('Earlier days',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
      const SizedBox(height: 6),
      for (final d in days)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: Brand.surface,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _openDay(rows, d),
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Brand.border),
                ),
                child: Row(children: [
                  Expanded(
                    child: Text(
                        DateTime.tryParse(d) == null
                            ? d
                            : DateFormat('EEE d MMM')
                                .format(DateTime.parse(d)),
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                  Text('${callsDay[d]} calls · ${_money(byDay[d]!)} list · ',
                      style: const TextStyle(
                          fontSize: 12.5, color: Brand.inkSecondary)),
                  Text(
                      (realDay[d] ?? 0) < 0.005
                          ? 'free'
                          : _money(realDay[d]!),
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: (realDay[d] ?? 0) < 0.005
                              ? Brand.success
                              : Brand.ink)),
                  const Icon(Icons.chevron_right,
                      size: 18, color: Brand.inkFaint),
                ]),
              ),
            ),
          ),
        ),
    ];
  }

  void _openDay(List<Map<String, dynamic>> rows, String day) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Brand.bg,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .75,
        maxChildSize: .95,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 30),
          children: [_dayExplained(rows, day)],
        ),
      ),
    );
  }

  Widget _box(List<Widget> children) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Brand.border),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}
