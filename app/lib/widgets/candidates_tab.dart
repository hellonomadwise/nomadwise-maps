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

  const CandidatesTab({
    super.key,
    required this.supabase,
    required this.places,
    required this.regionForCity,
    required this.dismissReasons,
    required this.onQueued,
    required this.onCount,
  });

  @override
  State<CandidatesTab> createState() => _CandidatesTabState();
}

class _CandidatesTabState extends State<CandidatesTab> {
  static const _pageSize = 60;

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
      _apply(r, append: false);
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
    try {
      final r = await widget.supabase.adminCandidates(
          area: area, limit: _pageSize, offset: _rows.length, sort: sort);
      if (!mounted || area != _area || sort != _sort) return;
      _apply(r, append: true);
    } catch (e) {
      if (!mounted) return;
      _snack('More could not be loaded: $e', bad: true);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
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
    });
    widget.onCount(_total);
    // The page ran dry but more wait behind it: fetch the next ones.
    if (_rows.length < 10 && _rows.length < _shownTotal) _loadMore();
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
      onNotification: (_) => true,
      child: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 30),
            children: [
              _intro(),
              if (_areas.length > 1) _areaRow(),
              if (_total > 0) _orderRow(),
              if (_loading && _rows.isEmpty)
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
            '(about 250 a night)',
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(
            'Found by the nightly job, not on the site yet. Queue the ones '
            'worth a page. Nothing reaches Webflow until you approve its '
            'proposal.',
            style: TextStyle(fontSize: 12, color: Brand.inkMuted, height: 1.4)),
        const SizedBox(height: 8),
        Wrap(
            spacing: 8,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(facts.join('  ·  '),
                  style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Brand.inkSecondary)),
              if (_dismissed > 0)
                TextButton(
                    onPressed: _openDismissed,
                    style: TextButton.styleFrom(
                        foregroundColor: Brand.inkSecondary,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(
                            fontFamily: 'Roboto',
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600)),
                    child: Text('$_dismissed turned down')),
            ]),
        if (_sweepLine != null) ...[
          const SizedBox(height: 4),
          Text(_sweepLine!,
              style: const TextStyle(
                  fontSize: 12, color: Brand.inkMuted, height: 1.4)),
        ],
        if (searchLine != null) ...[
          const SizedBox(height: 4),
          Text(searchLine,
              style: const TextStyle(
                  fontSize: 12, color: Brand.inkMuted, height: 1.4)),
        ],
      ]),
    );
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
            'the reviews make us that people work there. Google shows '
            'five reviews a place, so look at a thin one before you '
            'queue it.',
            style:
                TextStyle(fontSize: 12, color: Brand.inkMuted, height: 1.4)),
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

  Widget _card(Candidate c) {
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
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (rating != null)
              StatusChip('★ $rating', dotColor: Brand.gold),
            // A cafe: how sure the reviews make us it is a place to
            // open a laptop.
            if (evidence != null)
              _why(
                  evidence,
                  switch (c.workEvidence) {
                    'strong' => Brand.success,
                    'some' => Brand.gold,
                    _ => Brand.inkMuted,
                  }),
            // What the search numbers say, then what the reviews say.
            for (final (text, good) in c.searchReasons)
              _why(text, good ? Brand.success : Brand.inkMuted),
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
                PopupMenuButton<String>(
                  enabled: !busy,
                  tooltip: 'Why it is not for the site',
                  onSelected: (reason) => _dismiss(c, reason),
                  itemBuilder: (_) => [
                    for (final r in widget.dismissReasons)
                      PopupMenuItem<String>(value: r, child: Text(r)),
                  ],
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Text('Not for the site',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color:
                                busy ? Brand.inkFaint : Brand.inkSecondary)),
                  ),
                ),
                ElevatedButton.icon(
                    onPressed: busy ? null : () => _queue(c),
                    icon: const Icon(Icons.add_to_queue_outlined, size: 18),
                    label: Text(busy ? 'Saving…' : 'Queue for the site')),
              ]),
        ]),
      ),
    );
  }
}
