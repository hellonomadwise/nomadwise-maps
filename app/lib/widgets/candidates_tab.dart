import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/candidate.dart';
import '../services/places_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import 'arrow_scroll_row.dart';
import 'ui.dart';

/// The control centre's Candidates list (migration 129): places the
/// nightly job found that look worth a page on nomadwise.io, waiting
/// for a founder to say yes or no.
///
/// A candidate is not a space yet. "Queue for the site" makes it one,
/// already queued, so it carries on through Queued, Ready to approve
/// and In Webflow like any other space; nothing reaches Webflow without
/// the Approve that was always needed. "Not for the site" takes it off
/// the list and keeps the reason, with a way back.
///
/// The list is worked through city by city: the chips on top are the
/// site's city pages with candidates near them, busiest first.
///
/// Each card says why it is worth a look (migration 137): how often
/// its name is searched on Google, whether its city is one where
/// people search for coworking and the site lists few, and what the
/// reviews say about working there. The list is ordered on all of it,
/// or by searches alone.
class CandidatesTab extends StatefulWidget {
  final SupabaseService supabase;
  final PlacesService places;

  /// The site's Region (city page) for a city name as Google spells it,
  /// or null when the site has none. The control centre's own matcher.
  final Map<String, dynamic>? Function(String? city) regionForCity;

  /// The reasons offered for "Not for the site" (the control centre's
  /// own list, so both places speak the same words).
  final List<String> dismissReasons;

  /// Called after a candidate was queued, so the control centre reloads
  /// and the new space shows under Queued.
  final Future<void> Function() onQueued;

  /// Reports how many candidates wait, for the number on the tab.
  final void Function(int total) onCount;

  /// Opens on the full list with its details showing, as the tab
  /// always did, instead of the best bets one at a time.
  final bool startFull;

  /// Told of every scroll of the list, so the page around it can make
  /// room on a phone. (The list keeps its scroll notifications to
  /// itself otherwise, so its pull-to-refresh stays its own.)
  final bool Function(ScrollNotification n)? onScroll;

  const CandidatesTab({
    super.key,
    required this.supabase,
    required this.places,
    required this.regionForCity,
    required this.dismissReasons,
    required this.onQueued,
    required this.onCount,
    this.startFull = false,
    this.onScroll,
  });

  @override
  State<CandidatesTab> createState() => _CandidatesTabState();
}

class _CandidatesTabState extends State<CandidatesTab> {
  /// How many places one request brings: a screenful for the full
  /// list; for the short list as many as the database gives at once,
  /// since the strong ones are picked out of them here.
  int get _pageSize => _full ? 60 : 200;

  /// The short list, one place at a time (the way it opens), or the
  /// full list as it always was.
  late bool _full = widget.startFull;

  /// The lines about where the list comes from, folded away unless
  /// asked for.
  late bool _details = widget.startFull;

  /// How many strong candidates the short list likes to have in hand.
  static const _shortSize = 20;

  /// Places put off with "Later", for this sitting only.
  final List<String> _later = [];

  /// Decided since the tab was opened.
  int _decided = 0;

  /// The last request for more failed, or brought nothing new: not
  /// asked again until the list is reloaded.
  bool _moreFailed = false;

  /// Counts the reloads, so a page asked for before a reload is not
  /// added to the list that came after it.
  int _listVersion = 0;

  /// The place in front in the one-at-a-time view. It stays in front
  /// while more of the list arrives, so the card never changes under a
  /// finger on its way to Yes.
  String? _front;

  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  List<Candidate> _rows = [];
  List<CandidateArea> _areas = [];
  int _total = 0;
  int _shownTotal = 0;
  int _waitingScan = 0;
  int _dismissed = 0;

  /// The area being worked through; null shows every area together.
  String? _area;

  /// The order of the list: 'best' (searches for the name, city gaps
  /// and reviews together) or 'searches' (most searched name first).
  String _sort = 'best';

  /// The day the search numbers were looked up, and how many places
  /// on the list were found after that and have none yet.
  DateTime? _searchMeasured;
  int _withoutSearch = 0;

  /// What other sites name in the chosen city (or everywhere), and
  /// where each named place stands (migration 140).
  Map<String, dynamic> _mentionSummary = const {};

  /// What may be asked of Google for this evidence, and what has been
  /// this month (public.evidence_plan(), migration 140).
  Map<String, dynamic> _evidencePlan = const {};

  /// Places with a decision on its way to the database.
  final Set<String> _busy = {};

  /// Review quotes fetched on request, by place.
  final Map<String, List<String>> _quotes = {};
  final Set<String> _quotesLoading = {};

  /// One line on where candidates come from: the nightly city sweep.
  String? _sweepLine;

  @override
  void initState() {
    super.initState();
    _reload();
    _loadSweepLine();
  }

  Future<void> _reload() async {
    // An answer that arrives after the city or the order was changed
    // again is dropped; the later request brings the right list.
    final area = _area;
    final sort = _sort;
    try {
      final r = await widget.supabase.adminCandidates(
          area: area, limit: _pageSize, offset: 0, sort: sort);
      if (!mounted || area != _area || sort != _sort) return;
      _moreFailed = false;
      _listVersion++;
      _apply(r, append: false);
      _topUp();
    } catch (e) {
      if (!mounted || area != _area || sort != _sort) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    final area = _area;
    final sort = _sort;
    final version = _listVersion;
    try {
      final r = await widget.supabase.adminCandidates(
          area: area, limit: _pageSize, offset: _rows.length, sort: sort);
      if (!mounted ||
          area != _area ||
          sort != _sort ||
          version != _listVersion) {
        return;
      }
      final had = {for (final c in _rows) c.placeId};
      _apply(r, append: true);
      // Nothing new although more were promised (the list moved under
      // us): stop here, or the short list would ask for ever.
      if (!_rows.any((c) => !had.contains(c.placeId))) _moreFailed = true;
    } catch (e) {
      if (!mounted) return;
      _moreFailed = true;
      _snack('More could not be loaded: $e', bad: true);
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
        _topUp();
      }
    }
  }

  void _apply(Map<String, dynamic> r, {required bool append}) {
    final rows = <Candidate>[
      for (final x in (r['rows'] as List? ?? const []))
        if (x is Map) Candidate.fromJson(Map<String, dynamic>.from(x)),
    ];
    final areas = <CandidateArea>[
      for (final x in (r['areas'] as List? ?? const []))
        if (x is Map) CandidateArea.fromJson(Map<String, dynamic>.from(x)),
    ];
    final total = (r['total'] as num?)?.toInt() ?? 0;
    setState(() {
      if (append) {
        final have = {for (final c in _rows) c.placeId};
        _rows = [..._rows, ...rows.where((c) => !have.contains(c.placeId))];
      } else {
        _rows = rows;
      }
      _areas = areas;
      _total = total;
      _shownTotal = (r['shown_total'] as num?)?.toInt() ?? rows.length;
      _waitingScan = (r['waiting_scan'] as num?)?.toInt() ?? 0;
      _dismissed = (r['dismissed'] as num?)?.toInt() ?? 0;
      _searchMeasured =
          DateTime.tryParse((r['search_measured'] ?? '').toString());
      _withoutSearch = (r['without_search'] as num?)?.toInt() ?? 0;
      _mentionSummary = r['mention_summary'] is Map
          ? Map<String, dynamic>.from(r['mention_summary'] as Map)
          : const {};
      _evidencePlan = r['evidence_plan'] is Map
          ? Map<String, dynamic>.from(r['evidence_plan'] as Map)
          : const {};
      _loading = false;
      _error = null;
    });
    widget.onCount(total);
  }

  Future<void> _loadSweepLine() async {
    final queued = await widget.supabase.sweepQueue();
    final swept = await widget.supabase.citySweeps();
    if (!mounted) return;
    final done = {
      for (final s in swept) (s['city'] ?? '').toString().toLowerCase()
    };
    final pending = [
      for (final q in queued)
        if (!done.contains(q.toLowerCase())) q,
    ];
    final parts = <String>[];
    if (pending.isNotEmpty) {
      parts.add('Queued for the nightly sweep: ${pending.join(', ')} '
          '(one city a night).');
    }
    if (swept.isNotEmpty) {
      final last = swept.first;
      final at = DateTime.tryParse('${last['swept_at']}')?.toLocal();
      parts.add('Last swept: ${last['city']}'
          '${last['places_found'] != null ? ' (${last['places_found']} places)' : ''}'
          '${at != null ? ', ${DateFormat('d MMM').format(at)}' : ''}.');
    }
    if (parts.isEmpty) {
      parts.add('No city has been swept yet.');
    }
    parts.add("Sweep a city from the map's menu to add its places here.");
    setState(() => _sweepLine = parts.join(' '));
  }

  void _snack(String text, {bool bad = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text),
        duration: Duration(seconds: bad ? 5 : 3),
        backgroundColor: bad ? Brand.red : null));
  }

  void _pickArea(String? area) {
    if (area == _area) return;
    setState(() {
      _area = area;
      _front = null;
      _loading = true;
      _rows = [];
    });
    _reload();
  }

  void _pickSort(String sort) {
    if (sort == _sort) return;
    setState(() {
      _sort = sort;
      _loading = true;
      _rows = [];
    });
    _reload();
  }

  /// A decided card leaves the list at once; the numbers follow.
  void _removeLocally(Candidate c) {
    setState(() {
      _rows = _rows.where((x) => x.placeId != c.placeId).toList();
      _total = _total > 0 ? _total - 1 : 0;
      _shownTotal = _shownTotal > 0 ? _shownTotal - 1 : 0;
      _areas = [
        for (final a in _areas)
          if (a.area != c.area)
            a
          else if (a.count > 1)
            a.withCount(a.count - 1),
      ];
      _quotes.remove(c.placeId);
      _later.remove(c.placeId);
      if (_front == c.placeId) _front = null;
      _decided++;
    });
    widget.onCount(_total);
    // The page ran dry but more wait behind it: fetch the next ones.
    if (_full && _rows.length < 10 && _rows.length < _shownTotal) _loadMore();
    _topUp();
    // The area emptied: go back to everything.
    if (_area != null && _shownTotal == 0) _pickArea(null);
  }

  // ------------------------------------------------------------ decisions

  /// The place becomes a space, already queued for the site. Google is
  /// asked once for the city and country, so the space is filed under
  /// the right city page from the start.
  Future<void> _queue(Candidate c) async {
    if (_busy.contains(c.placeId)) return;
    setState(() => _busy.add(c.placeId));
    try {
      final live = await widget.places.details(c.placeId);
      final region = widget.regionForCity(live?.city);
      final res = await widget.supabase.candidateQueue(c.placeId, {
        // The city as the site spells it (Lisbon, not Lisboa) when the
        // site has a page for it, else Google's spelling.
        'city': region?['name'] ?? live?.city,
        'country': region?['country'] ?? live?.country,
        'website': live?.website,
      });
      if (!mounted) return;
      _removeLocally(c);
      if (res['existed'] == true) {
        _snack('${c.name} is already a space. Nothing changed.');
      } else if (region == null && !c.hasCityPage) {
        _snack('${c.name} queued. Its city has no page yet, so it waits '
            'under Blocked until you pick or create one.');
      } else {
        _snack('${c.name} queued. The full proposal is ready in a few '
            'minutes.');
      }
      await widget.onQueued();
    } catch (e) {
      if (!mounted) return;
      _snack('That did not save: $e', bad: true);
    } finally {
      if (mounted) setState(() => _busy.remove(c.placeId));
    }
  }

  /// "Other" says nothing by itself: the reason is asked for and kept
  /// with it. Null when the question was closed without an answer.
  Future<String?> _askOtherReason(Candidate c) async {
    final text = TextEditingController();
    final said = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
              builder: (ctx, setLocal) => AlertDialog(
                title: Text('Why not ${c.name}?'),
                content: TextField(
                    controller: text,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 3,
                    maxLength: 200,
                    onChanged: (_) => setLocal(() {}),
                    decoration: const InputDecoration(
                        labelText: 'The reason',
                        hintText: 'In a few words, for later')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel')),
                  ElevatedButton(
                      onPressed: text.text.trim().isEmpty
                          ? null
                          : () => Navigator.pop(ctx, text.text.trim()),
                      child: const Text('Not for the site')),
                ],
              ),
            ));
    return (said ?? '').trim().isEmpty ? null : said!.trim();
  }

  Future<void> _dismiss(Candidate c, String reason) async {
    if (_busy.contains(c.placeId)) return;
    String? note;
    if (reason == 'Other') {
      note = await _askOtherReason(c);
      if (note == null || !mounted) return;
      if (_busy.contains(c.placeId)) return;
    }
    setState(() => _busy.add(c.placeId));
    try {
      await widget.supabase.candidateDismiss(c.placeId, reason, note: note);
      if (!mounted) return;
      _removeLocally(c);
      setState(() => _dismissed = _dismissed + 1);
      _snack('${c.name} is off the list: '
          '${note ?? reason.toLowerCase()}.');
    } catch (e) {
      if (!mounted) return;
      _snack('That did not save: $e', bad: true);
    } finally {
      if (mounted) setState(() => _busy.remove(c.placeId));
    }
  }

  /// What Google's reviewers say about working there, in their words.
  /// Asked for one place at a time, on request: each look costs a
  /// Google call.
  Future<void> _showQuotes(Candidate c) async {
    if (_quotes.containsKey(c.placeId) ||
        _quotesLoading.contains(c.placeId)) {
      return;
    }
    setState(() => _quotesLoading.add(c.placeId));
    final found = await widget.places.keywordExcerpts(c.placeId, limit: 3);
    if (!mounted) return;
    setState(() {
      _quotesLoading.remove(c.placeId);
      _quotes[c.placeId] = found;
    });
  }

  Future<void> _open(String url) => launchUrl(Uri.parse(url),
      mode: LaunchMode.platformDefault, webOnlyWindowName: '_blank');

  /// The candidates turned down, each with its reason and a way back.
  Future<void> _openDismissed() async {
    final rows = await widget.supabase.candidatesDismissed();
    if (!mounted) return;
    var changed = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Brand.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * .75),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Turned down',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      'Candidates marked not for the site, newest first. '
                      'They stay on Nomad Maps as before.',
                      style: TextStyle(
                          fontSize: 12.5, color: Brand.inkSecondary)),
                ),
              ),
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 12, 20, 28),
                  child: Text('Nothing has been turned down.',
                      style: TextStyle(color: Brand.inkMuted)),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    children: [
                      for (final r in rows)
                        ListTile(
                          dense: true,
                          title: Text((r['name'] ?? 'Unnamed').toString(),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                          subtitle: Text(
                              [
                                (r['reason'] ?? 'No reason recorded')
                                    .toString(),
                                if (r['note'] != null) '${r['note']}',
                              ].join('  ·  '),
                              style: const TextStyle(fontSize: 12)),
                          trailing: TextButton(
                              onPressed: () async {
                                final id = '${r['google_place_id']}';
                                try {
                                  await widget.supabase.candidateRestore(id);
                                  changed = true;
                                  if (!ctx.mounted) return;
                                  setSheet(() {
                                    rows.remove(r);
                                  });
                                } catch (e) {
                                  if (!mounted) return;
                                  _snack('That did not save: $e', bad: true);
                                }
                              },
                              child: const Text('Bring back')),
                        ),
                    ],
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
    if (changed && mounted) {
      setState(() => _loading = true);
      await _reload();
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    // First load: nothing to show yet. A change of city keeps the
    // header and the city chips in place and loads beneath them.
    if (_loading && _rows.isEmpty && _areas.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: Brand.red));
    }
    if (_error != null) return _errorView();
    // Its own pull-to-refresh: the swipe reloads this list, and stops
    // there so the control centre around it does not reload as well.
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        widget.onScroll?.call(n);
        return true;
      },
      child: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 30),
            children: [
              _intro(),
              if (_areas.length > 1) _areaRow(),
              if (_total > 0) _modeRow(),
              if (!_full)
                ..._oneAtATime()
              else if (_total > 0)
                _orderRow(),
              if (!_full)
                const SizedBox.shrink()
              else if (_loading && _rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: Center(
                      child: CircularProgressIndicator(color: Brand.red)),
                )
              else if (_rows.isEmpty)
                _emptyView()
              else ...[
                for (final c in _rows) _card(c),
                if (_rows.length < _shownTotal)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Center(
                      child: OutlinedButton(
                          onPressed: _loadingMore ? null : _loadMore,
                          child: Text(_loadingMore
                              ? 'Loading…'
                              : 'Show more (${_shownTotal - _rows.length} left)')),
                    ),
                  ),
              ],
            ]),
      ),
    );
  }

  Widget _errorView() => ListView(padding: const EdgeInsets.all(24), children: [
        const SizedBox(height: 30),
        const Icon(Icons.cloud_off_outlined, size: 36, color: Brand.inkMuted),
        const SizedBox(height: 12),
        const Text('The candidates could not be read',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text('$_error',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
        const SizedBox(height: 14),
        Center(
          child: OutlinedButton(
              onPressed: () {
                setState(() {
                  _loading = true;
                  _error = null;
                });
                _reload();
              },
              child: const Text('Try again')),
        ),
      ]);

  /// What this list is, how much waits, and where it comes from.
  Widget _intro() {
    String n(int x, String one, String many) => '$x ${x == 1 ? one : many}';
    final facts = <String>[
      n(_total, 'place waiting', 'places waiting'),
      if (_waitingScan > 0)
        '${n(_waitingScan, 'more', 'more')} found, reviews not read yet '
            '(about 10 a night, the ones other sites or Google point at first)',
    ];
    // Where the search numbers come from, and how fresh they are.
    String? searchLine;
    final measured = _searchMeasured;
    if (measured != null) {
      final day = DateFormat('d MMM yyyy').format(measured);
      searchLine = 'Search numbers: Ahrefs, worldwide, looked up $day.';
      if (_withoutSearch > 0) {
        final since = n(_withoutSearch, 'place', 'places');
        final verb = _withoutSearch == 1 ? 'has' : 'have';
        searchLine = '$searchLine $since found since then $verb none yet.';
      }
    }
    final small = TextButton.styleFrom(
        foregroundColor: Brand.inkSecondary,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(
            fontFamily: 'Roboto', fontSize: 12.5, fontWeight: FontWeight.w600));
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            spacing: 8,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(facts.first,
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Brand.inkSecondary)),
              if (_dismissed > 0)
                TextButton(
                    onPressed: _openDismissed,
                    style: small,
                    child: Text('$_dismissed turned down')),
              // Where the list comes from, on request: it used to fill
              // two screens before the first place.
              TextButton(
                  onPressed: () => setState(() => _details = !_details),
                  style: small,
                  child: Text(_details ? 'Hide details' : 'Details')),
            ]),
        if (_details) ...[
          const SizedBox(height: 6),
          const Text(
              'Found by the nightly job, not on the site yet. Queue the '
              'ones worth a page. Nothing reaches Webflow until you '
              'approve its proposal.',
              style:
                  TextStyle(fontSize: 12, color: Brand.inkMuted, height: 1.4)),
          const SizedBox(height: 4),
          const Text(
              'A strong candidate has a city page, is not a hotel or one '
              'of a chain, and shows signs people work there. A cafe '
              'needs two signs: reviews about working there, other sites '
              'listing it, or Google\'s own search returning it. A '
              'coworking space needs one review or one other site, or a '
              'good rating from enough people.',
              style:
                  TextStyle(fontSize: 12, color: Brand.inkMuted, height: 1.4)),
          if (facts.length > 1) ...[
            const SizedBox(height: 4),
            Text(facts.skip(1).join('  ·  '),
                style: const TextStyle(
                    fontSize: 12, color: Brand.inkMuted, height: 1.4)),
          ],
        ],
        if (_details && _sweepLine != null) ...[
          const SizedBox(height: 4),
          Text(_sweepLine!,
              style: const TextStyle(
                  fontSize: 12, color: Brand.inkMuted, height: 1.4)),
        ],
        if (_details && searchLine != null) ...[
          const SizedBox(height: 4),
          Text(searchLine,
              style: const TextStyle(
                  fontSize: 12, color: Brand.inkMuted, height: 1.4)),
        ],
        if (_details && _mentionLine() != null) ...[
          const SizedBox(height: 4),
          Text(_mentionLine()!,
              style: const TextStyle(
                  fontSize: 12, color: Brand.inkMuted, height: 1.4)),
        ],
        if (_details && _planLine() != null) ...[
          const SizedBox(height: 4),
          Text(_planLine()!,
              style: const TextStyle(
                  fontSize: 12, color: Brand.inkMuted, height: 1.4)),
        ],
      ]),
    );
  }

  /// How much Google is asked for this evidence, kept inside its free
  /// monthly amount: "Google lookups for this: 46 of 1,000 this month,
  /// at most 40 a day, London only. Google's free 5,000 a month for
  /// this kind of call: 310 used by everything, 1,500 kept back for
  /// the app." Null when the plan could not be read.
  String? _planLine() {
    final p = _evidencePlan;
    if (p['calls_per_month'] is! num) return null;
    int v(String k) => (p[k] as num?)?.toInt() ?? 0;
    String n(int x) => Candidate.thousands(x);
    // "london" as "London", "chiang mai" as "Chiang Mai"
    String cap(String s) => s
        .split(' ')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
    final cities = [
      for (final c in (p['cities'] is List ? p['cities'] as List : const []))
        if ('$c'.trim().isNotEmpty) cap('$c'.trim()),
    ];
    final where = cities.isEmpty
        ? 'no city chosen'
        : cities.length == 1
            ? '${cities.first} only'
            : cities.join(', ');
    final stopped = v('left_month') <= 0
        ? ' Nothing more is asked this month.'
        : '';
    return 'Google lookups for this: ${n(v('used_job'))} of '
        '${n(v('calls_per_month'))} this month, at most '
        '${n(v('calls_per_run'))} a day, $where. Google\'s free '
        '${n(v('free_per_month'))} a month for this kind of call: '
        '${n(v('used_all'))} used by everything, ${n(v('keep_back'))} kept '
        'back for the app.$stopped';
  }

  /// What the other sites and blogs name, and what became of each
  /// name: "Other sites: 38 sites name 845 places in London. 120 are
  /// on Nomad Maps already, 90 were found open and are candidates, 20
  /// have closed, 150 still to check, 586 named by one ordinary site
  /// are not checked for now.". Null when none were read for this
  /// city.
  String? _mentionLine() {
    int v(String k) => (_mentionSummary[k] as num?)?.toInt() ?? 0;
    final places = v('places');
    if (places == 0) return null;
    final sources = v('sources');
    final where = _area == null ? '' : ' in $_area';
    final listed = v('listed');
    final onSite = v('on_site');
    final parts = <String>[
      if (listed > 0)
        '$listed ${listed == 1 ? 'is' : 'are'} on Nomad Maps already'
            '${onSite > 0 && onSite < listed ? ' ($onSite on the site)' : ''}',
      if (v('matched') > 0)
        '${v('matched')} ${v('matched') == 1 ? 'was' : 'were'} found open '
            'and ${v('matched') == 1 ? 'is a candidate' : 'are candidates'}',
      if (v('closed') > 0)
        '${v('closed')} ${v('closed') == 1 ? 'has' : 'have'} closed',
      if (v('not_found') > 0) '${v('not_found')} not found on Google',
      if (v('several') > 0)
        '${v('several')} ${v('several') == 1 ? 'is a brand' : 'are brands'} '
            'with several places',
      if (v('waiting') > 0) '${v('waiting')} still to check',
      // named by too little to be worth a lookup for now
      if (v('parked') > 0)
        '${v('parked')} named by one ordinary site ${v('parked') == 1 ? 'is' : 'are'} '
            'not checked for now',
    ];
    return 'Other sites: $sources ${sources == 1 ? 'site names' : 'sites name'} '
        '$places ${places == 1 ? 'place' : 'places'}$where. '
        '${parts.join(', ')}.';
  }

  /// What the numbers say about the chosen city, and the order of the
  /// list: best bets first, or most searched first.
  Widget _orderRow() {
    String? cityLine;
    for (final a in _areas) {
      if (a.area == _area) cityLine = a.searchLine;
    }
    Widget pick(String key, String label) {
      final on = _sort == key;
      return ChoiceChip(
        selected: on,
        showCheckmark: false,
        onSelected: (_) => _pickSort(key),
        selectedColor: Brand.ink,
        backgroundColor: Brand.surface,
        side: BorderSide(color: on ? Brand.ink : Brand.border),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        labelStyle: TextStyle(
            fontFamily: 'Roboto',
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: on ? Colors.white : Brand.inkSecondary),
        label: Text(label),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (cityLine != null) ...[
          Text(cityLine,
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Brand.inkSecondary,
                  height: 1.4)),
          const SizedBox(height: 8),
        ],
        Wrap(spacing: 6, runSpacing: 6, children: [
          pick('best', 'Best bets first'),
          pick('searches', 'Most searched first'),
        ]),
        if (_details) ...[
        const SizedBox(height: 6),
        Text(
            _sort == 'best'
                ? 'Weighs searches for the name, coworking spaces in '
                    'cities where we list few, and what the reviews say.'
                : 'By Google searches a month for the name. The most '
                    'searched are often hotels and chains, so read the '
                    'reason on each card. A brand with several places '
                    'here counts its share of the searches.',
            style: const TextStyle(
                fontSize: 12, color: Brand.inkMuted, height: 1.4)),
        const SizedBox(height: 4),
        const Text(
            'On a cafe, "strong", "some" or "thin" signs says how sure '
            'we are that people work there: what its reviews say '
            '(Google shows five a place), whether other sites name it, '
            'and whether Google\'s own search returns it for a place '
            'to work. Look at a thin one before you queue it.',
            style:
                TextStyle(fontSize: 12, color: Brand.inkMuted, height: 1.4)),
        ],
      ]),
    );
  }

  /// One reason on a card, in words. Long ones wrap inside the card
  /// instead of running off it.
  Widget _why(String text, Color dot) => Container(
        constraints: const BoxConstraints(minHeight: 26),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: Brand.field, borderRadius: BorderRadius.circular(13)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Brand.inkSecondary)),
          ),
        ]),
      );

  /// City by city: the areas with candidates, busiest first.
  Widget _areaRow() {
    Widget chip(String label, int count, bool on, VoidCallback onTap,
            {bool muted = false}) =>
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(
            selected: on,
            showCheckmark: false,
            onSelected: (_) => onTap(),
            selectedColor: Brand.violet,
            backgroundColor: Brand.surface,
            side: BorderSide(color: on ? Brand.violet : Brand.border),
            labelStyle: TextStyle(
                fontFamily: 'Roboto',
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: on
                    ? Colors.white
                    : muted
                        ? Brand.inkMuted
                        : Brand.inkSecondary),
            label: Text('$label  $count'),
          ),
        );
    // Arrows at either end on a laptop, where a mouse cannot swipe
    // (Jonathan, 5 Oct 2026).
    return ArrowScrollRow(
        height: 44,
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          chip('Everywhere', _total, _area == null, () => _pickArea(null)),
          for (final a in _areas)
            chip(a.area, a.count, _area == a.area, () => _pickArea(a.area),
                muted: !a.hasPage),
        ]);
  }

  Widget _emptyView() => Padding(
        padding: const EdgeInsets.fromLTRB(24, 36, 24, 0),
        child: Column(children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
                color: Brand.violet.withValues(alpha: .10),
                shape: BoxShape.circle),
            child: const Icon(Icons.travel_explore_outlined,
                size: 32, color: Brand.violet),
          ),
          const SizedBox(height: 14),
          const Text('No candidates waiting',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text(
              "Sweep a city from the map's menu. Overnight the job "
              'finds its cafes and coworking spaces and reads their '
              'reviews, and the ones worth a look land here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, color: Brand.inkMuted, height: 1.5)),
        ]),
      );

  // ------------------------------------------------- one at a time
  // (Jonathan, 6 Oct 2026) "If I can be given one really strong
  // potential, based off the key bits of information, so I can assess
  // whether to say yes to it or no." The key bits: other sites list
  // it, its reviews mention working there from a laptop, coworking.

  /// The strong candidates among those loaded, strongest first. The
  /// ones put off with "Later" go to the back, in the order they were
  /// put off.
  List<Candidate> get _short {
    final strong = [
      for (final c in _rows)
        if (c.shortlisted) c,
    ];
    final at = {
      for (var i = 0; i < strong.length; i++) strong[i].placeId: i,
    };
    strong.sort((a, b) {
      final la = _later.indexOf(a.placeId);
      final lb = _later.indexOf(b.placeId);
      if (la != lb) {
        if (la < 0) return -1;
        if (lb < 0) return 1;
        return la - lb;
      }
      final s = b.strength - a.strength;
      return s != 0 ? s : at[a.placeId]! - at[b.placeId]!;
    });
    // The one being looked at keeps its place at the front.
    final i = strong.indexWhere((c) => c.placeId == _front);
    if (i > 0) strong.insert(0, strong.removeAt(i));
    return strong;
  }

  /// The short list wants a few strong candidates in hand: while
  /// fewer are loaded and more places wait, the next page is read.
  void _topUp() {
    if (_full || _loading || _loadingMore || _moreFailed) return;
    if (_rows.length >= _shownTotal) return;
    if (_rows.where((c) => c.shortlisted).length >= _shortSize) return;
    _loadMore();
  }

  void _setFull(bool full) {
    if (full == _full) return;
    setState(() => _full = full);
    _topUp();
  }

  void _sayLater(Candidate c) => setState(() {
        _later.remove(c.placeId);
        _later.add(c.placeId);
        _front = null;
      });

  /// The two ways to work the list.
  Widget _modeRow() {
    Widget pick(bool full, String label) {
      final on = _full == full;
      return ChoiceChip(
        selected: on,
        showCheckmark: false,
        onSelected: (_) => _setFull(full),
        selectedColor: Brand.ink,
        backgroundColor: Brand.surface,
        side: BorderSide(color: on ? Brand.ink : Brand.border),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        labelStyle: TextStyle(
            fontFamily: 'Roboto',
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: on ? Colors.white : Brand.inkSecondary),
        label: Text(label),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        pick(false, 'Strongest, one at a time'),
        pick(true, 'The full list'),
      ]),
    );
  }

  /// One of the key facts on the one-at-a-time card: true speaks for
  /// the place, false against, null is neither (not known yet).
  Widget _fact(bool? good, String text, {IconData? icon}) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
                icon ??
                    (good == true
                        ? Icons.check_circle
                        : good == false
                            ? Icons.remove_circle_outline
                            : Icons.help_outline),
                size: 18,
                color: good == true ? Brand.success : Brand.inkMuted),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 13.5,
                    height: 1.35,
                    fontWeight:
                        good == true ? FontWeight.w600 : FontWeight.w400,
                    color: good == true ? Brand.ink : Brand.inkSecondary)),
          ),
        ]),
      );

  /// True when other sites were read for the candidate's city, so
  /// "no other site names it" means something.
  bool _sitesReadFor(Candidate c) {
    final cities = _evidencePlan['cities'];
    if (cities is! List) return false;
    final area = c.area.trim().toLowerCase();
    return cities.any((x) => '$x'.trim().toLowerCase() == area);
  }

  /// The key bits of information, the same three on every card and in
  /// the same order.
  List<Widget> _keyFacts(Candidate c) {
    final names = c.mentionSources.take(3).join(', ');
    final more = c.mentions - c.mentionSources.take(3).length;
    final extras = <String>[
      if (c.power > 0)
        '${c.power} ${c.power == 1 ? 'mentions' : 'mention'} plugs',
      if (c.wifi > 0) '${c.wifi} ${c.wifi == 1 ? 'mentions' : 'mention'} WiFi',
    ];
    final also = extras.isEmpty ? '' : ' (${extras.join(', ')})';
    return [
      _fact(
          c.coworking ? true : null,
          c.coworking
              ? 'A coworking space'
              : 'A cafe, not a coworking space',
          icon: c.coworking ? null : Icons.local_cafe_outlined),
      if (c.mentions > 0)
        _fact(
            true,
            'Listed by ${c.mentions} other ${c.mentions == 1 ? 'site' : 'sites'}'
            '${names.isEmpty ? '' : ': $names'}'
            '${more > 0 ? ' and $more more' : ''}')
      else if (_sitesReadFor(c))
        // Not "no site lists it": a place named by one ordinary site
        // is not matched yet.
        _fact(false, "Not found on the other sites' lists so far")
      else
        _fact(null, 'Other sites have not been read for ${c.area} yet'),
      if (!c.reviewsRead)
        _fact(null, 'Its reviews have not been read yet')
      else if (c.laptop > 0)
        _fact(
            true,
            "${c.laptop} of Google's five reviews "
            '${c.laptop == 1 ? 'mentions' : 'mention'} working there$also')
      else
        _fact(
            false,
            "None of Google's five reviews mention working there$also"),
      if (c.workPhrases.isNotEmpty)
        _fact(
            true,
            "Google's own search returns it for "
            '${c.workPhrases.map((p) => '"$p"').join(' and ')}'),
    ];
  }

  /// The short list as one place in front of you: the strongest left,
  /// its key facts, and Yes, No or Later.
  List<Widget> _oneAtATime() {
    Widget waiting() => const Padding(
          padding: EdgeInsets.only(top: 40),
          child: Center(child: CircularProgressIndicator(color: Brand.red)),
        );
    if (_loading && _rows.isEmpty) return [waiting()];
    if (_total == 0) return [_emptyView()];
    final short = _short;
    final moreToRead = _rows.length < _shownTotal && !_moreFailed;
    if (short.isEmpty) {
      if (_loadingMore || moreToRead) return [waiting()];
      if (_moreFailed && _rows.length < _shownTotal) {
        return [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 30, 16, 0),
            child: Column(children: [
              const Text('The rest of the list could not be read',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _loading = true;
                      _rows = [];
                    });
                    _reload();
                  },
                  child: const Text('Try again')),
            ]),
          ),
        ];
      }
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 30, 16, 0),
          child: Column(children: [
            const Icon(Icons.task_alt_rounded, size: 34, color: Brand.success),
            const SizedBox(height: 12),
            Text(
                'No strong candidates left'
                '${_area == null ? '' : ' in $_area'}',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            if (_shownTotal > 0) ...[
              const SizedBox(height: 6),
              Text(
                  'The full list has $_shownTotal '
                  '${_shownTotal == 1 ? 'place' : 'places'} with thinner '
                  'signs.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, color: Brand.inkMuted, height: 1.5)),
              const SizedBox(height: 12),
              OutlinedButton(
                  onPressed: () => _setFull(true),
                  child: const Text('Open the full list')),
            ],
          ]),
        ),
      ];
    }
    final c = short.first;
    _front = c.placeId;
    final count = moreToRead
        ? '${short.length} or more strong candidates'
        : '${short.length} strong ${short.length == 1 ? 'candidate' : 'candidates'}';
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
        child: Text(
            '$count${_area == null ? '' : ' in $_area'}'
            '${_decided > 0 ? '  ·  $_decided decided so far' : ''}',
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Brand.inkSecondary)),
      ),
      _card(c, one: true),
      if (short.length > 1)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
          child: Text(
              'Next: ${short[1].name}'
              '${short.length > 2 ? ', then ${short[2].name}' : ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
        ),
    ];
  }

  /// A candidate's card. [one]: the card of the one-at-a-time view,
  /// which leads with the key facts and ends in Yes, No or Later.
  Widget _card(Candidate c, {bool one = false}) {
    final busy = _busy.contains(c.placeId);
    final rating = c.ratingLabel;
    final quotes = _quotes[c.placeId];
    final where = [
      c.area,
      if (c.hasCityPage && (c.regionCountry ?? '').isNotEmpty) c.regionCountry,
    ].join(', ');
    final evidence = c.workEvidenceLabel;
    return Card(
      key: ValueKey('candidate-${c.placeId}'),
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                  color: Brand.violet,
                  borderRadius: BorderRadius.circular(10)),
              child: Text(c.coworking ? 'COWORKING' : 'CAFE',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    Text(where,
                        style: const TextStyle(
                            fontSize: 12, color: Brand.inkMuted)),
                    // which one of several with the same name
                    if (c.address != null)
                      Text(c.address!,
                          style: const TextStyle(
                              fontSize: 12, color: Brand.inkSecondary)),
                  ]),
            ),
          ]),
          if (one) ...[
            const SizedBox(height: 12),
            ..._keyFacts(c),
          ],
          SizedBox(height: one ? 3 : 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (rating != null)
              StatusChip('★ $rating', dotColor: Brand.gold),
            // A cafe: how sure the reviews make us it is a place to
            // open a laptop.
            if (evidence != null && !one)
              _why(
                  evidence,
                  switch (c.workEvidence) {
                    'strong' => Brand.success,
                    'some' => Brand.gold,
                    _ => Brand.inkMuted,
                  }),
            // Who else names it, and what Google's search says (the
            // one-at-a-time card says both among its key facts).
            if (!one)
              for (final r in c.outsideReasons) _why(r, Brand.success),
            // What the search numbers say, then what the reviews say.
            for (final (text, good) in c.searchReasons)
              _why(text, good ? Brand.success : Brand.inkMuted),
            if (!one)
              for (final r in c.reasons)
                StatusChip(r,
                    dotColor: r == 'Reviews not read yet'
                        ? Brand.inkMuted
                        : Brand.violet),
            if (!c.hasCityPage)
              const StatusChip('No city page yet', dotColor: Brand.red),
          ]),
          if (quotes != null) ...[
            const SizedBox(height: 10),
            if (quotes.isEmpty)
              const Text(
                  "Google's five reviews have no line worth quoting. "
                  'Open the map for the full listing.',
                  style: TextStyle(fontSize: 12.5, color: Brand.inkMuted))
            else
              for (final q in quotes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                    decoration: BoxDecoration(
                        color: Brand.field,
                        borderRadius: BorderRadius.circular(10)),
                    child: Text('“$q”',
                        style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            color: Brand.inkSecondary)),
                  ),
                ),
          ],
          const SizedBox(height: 8),
          Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                    onPressed: () => _open(c.googleUrl),
                    style: TextButton.styleFrom(
                        foregroundColor: Brand.inkSecondary),
                    icon: const Icon(Icons.search, size: 16),
                    label: const Text('Google')),
                TextButton.icon(
                    onPressed: () => _open(c.mapsUrl),
                    style: TextButton.styleFrom(
                        foregroundColor: Brand.inkSecondary),
                    icon: const Icon(Icons.map_outlined, size: 16),
                    label: const Text('Map')),
                if (quotes == null && c.reviewsRead)
                  TextButton.icon(
                      onPressed: _quotesLoading.contains(c.placeId)
                          ? null
                          : () => _showQuotes(c),
                      style: TextButton.styleFrom(
                          foregroundColor: Brand.inkSecondary),
                      icon: const Icon(Icons.format_quote_outlined, size: 16),
                      label: Text(_quotesLoading.contains(c.placeId)
                          ? 'Reading…'
                          : 'What reviews say')),
                if (!one) ...[
                  PopupMenuButton<String>(
                    enabled: !busy,
                    tooltip: 'Why it is not for the site',
                    onSelected: (reason) => _dismiss(c, reason),
                    itemBuilder: (_) => [
                      for (final r in widget.dismissReasons)
                        PopupMenuItem<String>(value: r, child: Text(r)),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Text('Not for the site',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: busy
                                  ? Brand.inkFaint
                                  : Brand.inkSecondary)),
                    ),
                  ),
                  ElevatedButton.icon(
                      onPressed: busy ? null : () => _queue(c),
                      icon: const Icon(Icons.add_to_queue_outlined, size: 18),
                      label: Text(busy ? 'Saving…' : 'Queue for the site')),
                ],
              ]),
          // One at a time: the decision, large, under everything else.
          if (one) ...[
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: PopupMenuButton<String>(
                  enabled: !busy,
                  tooltip: 'No: why it is not for the site',
                  onSelected: (reason) => _dismiss(c, reason),
                  itemBuilder: (_) => [
                    for (final r in widget.dismissReasons)
                      PopupMenuItem<String>(value: r, child: Text(r)),
                  ],
                  child: Container(
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        border: Border.all(color: Brand.border),
                        borderRadius: BorderRadius.circular(12)),
                    child: Text('No',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: busy ? Brand.inkFaint : Brand.ink)),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              TextButton(
                  onPressed:
                      busy || _short.length < 2 ? null : () => _sayLater(c),
                  style: TextButton.styleFrom(
                      foregroundColor: Brand.inkSecondary,
                      minimumSize: const Size(0, 46)),
                  child: const Text('Later')),
              const SizedBox(width: 6),
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: ElevatedButton(
                      onPressed: busy ? null : () => _queue(c),
                      style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8)),
                      child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(busy ? 'Saving…' : 'Yes, queue it',
                              maxLines: 1, softWrap: false))),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}
