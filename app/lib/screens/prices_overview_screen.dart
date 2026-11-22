import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';

/// Founders only: how far prices have got (Jonathan, 22 Nov 2026: "an
/// overview dashboard ... how many listings have prices on their
/// pages, and how many products in each ... over time, on a daily bar
/// chart cumulative ... for the coworking spaces, how many as % and by
/// area/region/location"). One read: admin_prices_dashboard
/// (migration 338). Opened from Price check.
class PricesOverviewScreen extends StatefulWidget {
  const PricesOverviewScreen({super.key});
  @override
  State<PricesOverviewScreen> createState() => _PricesOverviewScreenState();
}

int _n(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

Map<String, dynamic> _m(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> _l(dynamic v) => [
      for (final x in (v is List ? v : const []))
        if (x is Map) Map<String, dynamic>.from(x)
    ];

String _pct(int part, int whole) =>
    whole <= 0 ? '0%' : '${(part * 100 / whole).round()}%';

final _num = NumberFormat.decimalPattern();

/// One line of the "by place" list, summed from the database's rows.
class _Place {
  _Place(this.name, this.under);
  final String name;
  final String under;
  int pages = 0;
  int withPrices = 0;
  int showing = 0;
  int products = 0;
}

class _PricesOverviewScreenState extends State<PricesOverviewScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  String _chart = 'views_shown';
  String _level = 'country';
  int? _picked;
  bool _allPlaces = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Supabase.instance.client.rpc('admin_prices_dashboard');
      if (!mounted) return;
      setState(() {
        _data = _m(r);
        _error = null;
        _picked = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _error = e is PostgrestException ? e.message : 'Could not load: $e');
    }
  }

  Widget _card(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Brand.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Brand.border)),
        child: child,
      );

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
      );

  Widget _small(String t) => Text(t,
      style: const TextStyle(
          fontSize: 12.5, height: 1.4, color: Brand.inkSecondary));

  Widget _tile(String big, String label, String under) => _card(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Brand.inkSecondary)),
            const SizedBox(height: 4),
            Text(big,
                style: const TextStyle(
                    fontSize: 26, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            _small(under),
          ]));

  Widget _choice(String value, String label, String current,
          void Function(String) onPick) =>
      Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
            label: Text(label),
            selected: current == value,
            onSelected: (_) => onPick(value)),
      );

  /// A filled bar: [part] of [whole].
  Widget _meter(int part, int whole) => ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
            value: whole <= 0 ? 0 : (part / whole).clamp(0.0, 1.0).toDouble(),
            minHeight: 8,
            backgroundColor: Brand.field,
            valueColor: const AlwaysStoppedAnimation<Color>(Brand.accent)),
      );

  Widget _top(Map<String, dynamic> d) {
    final cw = _m(d['coworking']);
    final p = _m(d['products']);
    final pages = _n(cw['pages']);
    final withPrices = _n(cw['with_prices']);
    final showing = _n(cw['showing']);
    final all = _n(p['all']);
    final shownProducts = _n(cw['showing_products']);
    final m = _m(d['last30']);
    final viewsShown = _n(m['views_shown']);
    final viewsAll = viewsShown + _n(m['views_other']);
    final viewsWaiting = _n(m['views_with_prices']) - viewsShown;
    final tiles = <Widget>[
      _tile(_pct(viewsShown, viewsAll), 'Visitors who could see prices',
          '${_num.format(viewsShown)} of ${_num.format(viewsAll)} views of '
              'coworking pages in the last 30 days were of a page showing '
              'its prices'),
      _tile(_num.format(showing), 'Coworking pages showing prices',
          'of ${_num.format(pages)} live pages (${_pct(showing, pages)}), '
              'with ${_num.format(shownProducts)} products between them'),
      _tile(
          _num.format(withPrices - showing < 0 ? 0 : withPrices - showing),
          'Have prices, not showing yet',
          'These pages had '
              '${_num.format(viewsWaiting < 0 ? 0 : viewsWaiting)} views in '
              'the last 30 days. The morning check switches them on, most '
              'viewed first.'),
      _tile(
          _num.format(all),
          'Products stored',
          '${_num.format(_n(p['priced']))} with a price, '
              '${_num.format(_n(p['on_request']))} price on request'),
    ];
    return LayoutBuilder(builder: (context, c) {
      final two = c.maxWidth >= 520;
      if (!two) {
        return Column(children: [
          for (final t in tiles)
            Padding(padding: const EdgeInsets.only(bottom: 10), child: t),
        ]);
      }
      return Column(children: [
        for (var i = 0; i < tiles.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: IntrinsicHeight(
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: tiles[i]),
                    const SizedBox(width: 10),
                    Expanded(child: tiles[i + 1]),
                  ]),
            ),
          ),
      ]);
    });
  }

  String _per1000(int requests, int views) =>
      views <= 0 ? 'no views yet' : (requests * 1000 / views).toStringAsFixed(1);

  /// The question the screen is for: do pages that show prices get
  /// more requests for the same number of views?
  Widget _requests(Map<String, dynamic> d) {
    final m = _m(d['last30']);
    Widget row(String label, int views, int requests) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                    views < 200
                        ? 'Too early to tell'
                        : '${_per1000(requests, views)} requests per 1,000 views',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
                _small('${_num.format(requests)} '
                    '${requests == 1 ? 'request' : 'requests'} from '
                    '${_num.format(views)} views'
                    '${views < 200 ? '. A rate shows here from 200 views.' : ''}'),
              ]),
        );
    return _card(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title('Do prices bring requests?'),
          _small('Coworking pages, last 30 days. The same number of views '
              'should bring more requests where prices show. Compare the '
              'two rates as more pages are switched on.'),
          const SizedBox(height: 12),
          row('Pages showing prices', _n(m['views_shown']),
              _n(m['requests_shown'])),
          row('Pages not showing prices', _n(m['views_other']),
              _n(m['requests_other'])),
          const Text('Early sign: taps on a Request button',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(
              '${_num.format(_n(m['taps']))} '
              '${_n(m['taps']) == 1 ? 'visit' : 'visits'} tapped Request',
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          _small('Out of ${_num.format(_n(m['views_shown']))} views of pages '
              'showing prices. Counted from 22 Nov 2026. Taps come far more '
              'often than sent requests, so this moves first.'),
          const SizedBox(height: 12),
          _small('A view is one visitor opening one page, counted once per '
              'visit. Team devices (nomadwise.io/?team) are left out from '
              '22 Nov 2026.'),
        ]));
  }

  // The space's page on nomadwise.io, in a new tab (Jonathan, 22 Nov
  // 2026: "a link so I can easily click and open new tab").
  Widget _pageLink(String slug) => Tooltip(
        message: 'Opens nomadwise.io/coworking/$slug in a new tab',
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => launchUrl(
              Uri.parse('https://www.nomadwise.io/coworking/$slug'),
              webOnlyWindowName: '_blank'),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('Open page',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFE8464E))),
              SizedBox(width: 3),
              Icon(Icons.open_in_new, size: 13, color: Color(0xFFE8464E)),
            ]),
          ),
        ),
      );

  Widget _waiting(Map<String, dynamic> d) {
    final rows = _l(d['waiting']);
    // SelectionArea: the names can be highlighted and copied.
    return _card(SelectionArea(
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title('Most viewed pages not showing prices yet'),
          _small('They have prices stored that have not been checked '
              'against the space\'s own website. Switching these on reaches '
              'the most visitors.'),
          const SizedBox(height: 10),
          if (rows.isEmpty) _small('None: every page with prices shows them.'),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${r['name'] ?? ''}',
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700)),
                            _small([
                              for (final k in const ['area', 'city', 'country'])
                                if ('${r[k] ?? ''}'.trim().isNotEmpty)
                                  '${r[k]}'.trim()
                            ].toSet().join(', ') +
                                ' · ${_n(r['products'])} products'),
                          ]),
                    ),
                    const SizedBox(width: 8),
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('${_num.format(_n(r['views']))} views',
                              style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700)),
                          if ('${r['slug'] ?? ''}'.trim().isNotEmpty)
                            _pageLink('${r['slug']}'.trim()),
                        ]),
                  ]),
            ),
        ])));
  }

  Widget _kinds(Map<String, dynamic> d) {
    final p = _m(d['products']);
    final all = _n(p['all']);
    final rows = <(String, int)>[
      ('Coworking (desks, passes, memberships)', _n(p['coworking'])),
      ('Meeting rooms', _n(p['meeting_room'])),
      ('Private offices', _n(p['private_office'])),
      ('Other', _n(p['other'])),
    ];
    final sizes = _l(d['sizes']);
    final withPrices = _n(_m(d['coworking'])['with_prices']);
    return _card(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title('Products stored, by kind'),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                          child: Text(r.$1,
                              style: const TextStyle(fontSize: 13.5))),
                      Text('${_num.format(r.$2)}  ${_pct(r.$2, all)}',
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 4),
                    _meter(r.$2, all),
                  ]),
            ),
          const SizedBox(height: 6),
          _title('How many products a page has'),
          for (final s in sizes)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                          child: Text(
                              '${s['bucket']}' == '1'
                                  ? '1 product'
                                  : '${s['bucket']} products',
                              style: const TextStyle(fontSize: 13.5))),
                      Text(
                          '${_num.format(_n(s['listings']))} pages  '
                          '${_pct(_n(s['listings']), withPrices)}',
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 4),
                    _meter(_n(s['listings']), withPrices),
                  ]),
            ),
        ]));
  }

  Widget _overTime(Map<String, dynamic> d) {
    final days = _l(d['days']);
    final daily = _chart == 'views_shown' ||
        _chart == 'requests' ||
        _chart == 'taps';
    final key = const {
          'views_shown': 'views_shown',
          'requests': 'requests',
          'taps': 'taps',
          'products': 'products',
          'listings': 'listings',
        }[_chart] ??
        'showing';
    final word = const {
          'views_shown': 'views of pages showing prices',
          'requests': 'requests from coworking pages',
          'taps': 'visits that tapped a Request button',
          'products': 'products stored',
          'listings': 'pages with prices stored',
        }[_chart] ??
        'pages showing prices to visitors';
    // Views are drawn as all views of coworking pages (grey) with the
    // part that was of a page showing prices in red.
    final views = _chart == 'views_shown';
    var max = 1;
    for (final x in days) {
      final v = _n(x[views ? 'views_all' : key]);
      if (v > max) max = v;
    }
    String dayLabel(Map<String, dynamic> x) {
      final t = DateTime.tryParse('${x['d'] ?? ''}');
      return t == null ? '' : DateFormat('d MMM').format(t);
    }

    final at = days.isEmpty
        ? null
        : days[(_picked ?? days.length - 1).clamp(0, days.length - 1).toInt()];
    const h = 170.0;
    return _card(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title('Over time'),
          _small(views
              ? 'Each day on its own. Grey is every view of a coworking '
                  'page; red is the part that could see prices. Tap a bar '
                  'for that day.'
              : (daily
                  ? 'Each day on its own. Tap a bar for that day.'
                  : 'Running total, day by day. Tap a bar for that day.')),
          const SizedBox(height: 8),
          Wrap(runSpacing: 6, children: [
            _choice('views_shown', 'Views', _chart,
                (v) => setState(() {
                  _chart = v;
                  _picked = null;
                })),
            _choice('requests', 'Requests', _chart,
                (v) => setState(() {
                  _chart = v;
                  _picked = null;
                })),
            _choice('taps', 'Request taps', _chart,
                (v) => setState(() {
                  _chart = v;
                  _picked = null;
                })),
            _choice('showing', 'Pages showing', _chart,
                (v) => setState(() {
                  _chart = v;
                  _picked = null;
                })),
            _choice('listings', 'Have prices', _chart,
                (v) => setState(() {
                  _chart = v;
                  _picked = null;
                })),
            _choice('products', 'Products', _chart,
                (v) => setState(() {
                  _chart = v;
                  _picked = null;
                })),
          ]),
          const SizedBox(height: 10),
          if (at != null)
            Text(
                views
                    ? '${dayLabel(at)}: ${_num.format(_n(at['views_shown']))} '
                        'of ${_num.format(_n(at['views_all']))} views could '
                        'see prices'
                        '${_n(at['views_all']) > 0 ? ' (${_pct(_n(at['views_shown']), _n(at['views_all']))})' : ''}'
                    : '${dayLabel(at)}: ${_num.format(_n(at[key]))} $word',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          if (days.isEmpty)
            _small('Nothing to show yet.')
          else ...[
            SizedBox(
              height: h,
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < days.length; i++)
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _picked = i),
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: views
                                ? Container(
                                    margin: const EdgeInsets.symmetric(
                                        horizontal: 0.75),
                                    height: (h * _n(days[i]['views_all']) / max)
                                        .clamp(1.0, h)
                                        .toDouble(),
                                    alignment: Alignment.bottomCenter,
                                    decoration: BoxDecoration(
                                        color:
                                            (_picked ?? days.length - 1) == i
                                                ? Brand.inkMuted
                                                : Brand.inkFaint,
                                        borderRadius:
                                            const BorderRadius.vertical(
                                                top: Radius.circular(2))),
                                    child: Container(
                                      height: _n(days[i]['views_shown']) <= 0
                                          ? 0.0
                                          : (h *
                                                  _n(days[i]['views_shown']) /
                                                  max)
                                              .clamp(3.0, h)
                                              .toDouble(),
                                      color: Brand.accent,
                                    ),
                                  )
                                : Container(
                                    margin: const EdgeInsets.symmetric(
                                        horizontal: 0.75),
                                    height: (h * _n(days[i][key]) / max)
                                        .clamp(
                                            _n(days[i][key]) > 0 ? 3.0 : 1.0, h)
                                        .toDouble(),
                                    decoration: BoxDecoration(
                                        color:
                                            (_picked ?? days.length - 1) == i
                                                ? Brand.ink
                                                : Brand.accent,
                                        borderRadius:
                                            const BorderRadius.vertical(
                                                top: Radius.circular(2))),
                                  ),
                          ),
                        ),
                      ),
                  ]),
            ),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: _small(dayLabel(days.first))),
              _small(dayLabel(days.last)),
            ]),
          ],
        ]));
  }

  /// The same numbers a week at a time, newest first: steadier than
  /// single days when there are only a few requests a month.
  Widget _weeks(Map<String, dynamic> d) {
    final by = <DateTime, List<int>>{};
    for (final x in _l(d['days'])) {
      final t = DateTime.tryParse('${x['d'] ?? ''}');
      if (t == null) continue;
      final day = DateTime.utc(t.year, t.month, t.day);
      final start = day.subtract(Duration(days: day.weekday - 1));
      final w = by.putIfAbsent(start, () => [0, 0, 0, 0]);
      w[0] += _n(x['views_all']);
      w[1] += _n(x['views_shown']);
      w[2] += _n(x['requests']);
      w[3] += _n(x['taps']);
    }
    final starts = by.keys.toList()..sort((a, b) => b.compareTo(a));
    final shown = starts.length > 8 ? starts.sublist(0, 8) : starts;
    return _card(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title('Week by week'),
          _small('Coworking pages, weeks starting Monday, newest first. '
              'The first line is the week so far.'),
          const SizedBox(height: 10),
          if (shown.isEmpty) _small('Nothing to show yet.'),
          for (final wk in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Week of ${DateFormat('d MMM').format(wk)}',
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700)),
                            _small('${_num.format(by[wk]![0])} views, '
                                '${_num.format(by[wk]![1])} could see prices '
                                '(${_pct(by[wk]![1], by[wk]![0])}), '
                                '${_num.format(by[wk]![3])} tapped Request'),
                          ]),
                    ),
                    const SizedBox(width: 8),
                    Text(
                        '${by[wk]![2]} '
                        '${by[wk]![2] == 1 ? 'request' : 'requests'}',
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w700)),
                  ]),
            ),
        ]));
  }

  List<_Place> _places(Map<String, dynamic> d) {
    final by = <String, _Place>{};
    for (final r in _l(d['places'])) {
      final country = '${r['country'] ?? ''}';
      final city = '${r['city'] ?? ''}';
      final area = '${r['area'] ?? ''}';
      String name;
      String under;
      if (_level == 'country') {
        name = country;
        under = '';
      } else if (_level == 'city') {
        name = city;
        under = country;
      } else {
        if (area.isEmpty) continue;
        name = area;
        under = '$city, $country';
      }
      final p = by.putIfAbsent('$name|$under', () => _Place(name, under));
      p.pages += _n(r['pages']);
      p.withPrices += _n(r['with_prices']);
      p.showing += _n(r['showing']);
      p.products += _n(r['products']);
    }
    final out = by.values.toList();
    out.sort((a, b) {
      final s = b.showing.compareTo(a.showing);
      if (s != 0) return s;
      final c = b.withPrices.compareTo(a.withPrices);
      if (c != 0) return c;
      final e = b.pages.compareTo(a.pages);
      if (e != 0) return e;
      return a.name.compareTo(b.name);
    });
    return out;
  }

  Widget _byPlace(Map<String, dynamic> d) {
    final all = _places(d);
    final shown = _allPlaces || all.length <= 25 ? all : all.sublist(0, 25);
    return _card(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title('Coworking pages showing prices, by place'),
          _small('The share of live coworking pages in each place that show '
              'their prices to visitors. Most first.'),
          const SizedBox(height: 8),
          Row(children: [
            _choice('country', 'Country', _level,
                (v) => setState(() => _level = v)),
            _choice('city', 'Region', _level,
                (v) => setState(() => _level = v)),
            _choice('area', 'Location', _level,
                (v) => setState(() => _level = v)),
          ]),
          const SizedBox(height: 12),
          if (shown.isEmpty) _small('Nothing to show yet.'),
          for (final p in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p.name,
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700)),
                                  if (p.under.isNotEmpty) _small(p.under),
                                ]),
                          ),
                          const SizedBox(width: 8),
                          Text(_pct(p.showing, p.pages),
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w800)),
                        ]),
                    const SizedBox(height: 4),
                    _meter(p.showing, p.pages),
                    const SizedBox(height: 3),
                    _small('${_num.format(p.showing)} of '
                        '${_num.format(p.pages)} pages showing prices. '
                        '${_num.format(p.withPrices - p.showing < 0 ? 0 : p.withPrices - p.showing)} '
                        'more have prices not shown yet.'),
                  ]),
            ),
          if (shown.length < all.length)
            TextButton(
                onPressed: () => setState(() => _allPlaces = true),
                child: Text('Show all ${all.length}')),
        ]));
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    Widget body;
    if (_error != null && d == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, style: const TextStyle(color: Brand.red)),
            const SizedBox(height: 12),
            OutlinedButton(
                onPressed: () {
                  setState(() => _error = null);
                  _load();
                },
                child: const Text('Try again')),
          ]),
        ),
      );
    } else if (d == null) {
      body = const Center(child: CircularProgressIndicator(color: Brand.red));
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 40),
                children: [
                  _top(d),
                  _requests(d),
                  const SizedBox(height: 10),
                  _overTime(d),
                  const SizedBox(height: 10),
                  _weeks(d),
                  const SizedBox(height: 10),
                  _waiting(d),
                  const SizedBox(height: 10),
                  _byPlace(d),
                  const SizedBox(height: 10),
                  _kinds(d),
                ]),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: const Text('Prices overview')),
      body: body,
    );
  }
}
