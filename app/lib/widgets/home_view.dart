import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme.dart';

/// Home, the first screen of the control centre (Jonathan, 9 Nov 2026:
/// "I should have it where I have an overview of what things I could
/// do, and then I could choose what to do", with charts of what we are
/// working towards). Two parts: where we stand (admin_home, migration
/// 288), and what you could do, grouped, each line opening the place
/// where it is done. No order to follow: you pick.

/// One line under "What you could do".
class HomeRow {
  final String label;

  /// How many; null shows no number.
  final int? count;

  /// Someone is waiting on us (a red dot).
  final bool waiting;
  final VoidCallback onTap;
  const HomeRow(this.label, this.onTap, {this.count, this.waiting = false});
}

/// A card of lines. [urgent]: the card of things someone waits for,
/// with a red edge.
class HomeGroup {
  final String title;
  final List<HomeRow> rows;
  final bool urgent;

  /// What the card is for, behind the (i) at its top right (Jonathan,
  /// 9 Nov 2026: "an i in the top right, explaining the purpose of
  /// this card").
  final String? info;
  const HomeGroup(this.title, this.rows, {this.urgent = false, this.info});
}

class HomeView extends StatefulWidget {
  /// admin_home(); null while it is read.
  final Map<String, dynamic>? data;

  /// Why the numbers could not be read, if they could not.
  final String? error;
  final List<HomeGroup> groups;
  final Future<void> Function() onRefresh;

  /// The search and the health check, at the top right.
  final List<Widget> actions;

  /// A bar of "Outreach sent each week" tapped: its week (a Monday)
  /// and the switch above the chart ('' all, 'listed', 'new').
  final void Function(DateTime week, String who)? onOutreachWeek;
  const HomeView({
    super.key,
    required this.data,
    required this.groups,
    required this.onRefresh,
    this.error,
    this.actions = const [],
    this.onOutreachWeek,
  });

  @override
  State<HomeView> createState() => _HomeViewState();
}

/// The ways we write to spaces, in the order they stack.
const _ways = [
  ('email', 'Email', Color(0xFF1F6FB2)),
  ('whatsapp', 'WhatsApp', Brand.success),
  ('instagram', 'Instagram', Color(0xFFC2407A)),
  ('facebook', 'Facebook', Color(0xFF5B6CC9)),
  ('form', 'Contact form', Brand.goldTextDark),
];

const _blue = Color(0xFF1F6FB2);

class _HomeViewState extends State<HomeView> {
  /// The outreach chart: '' all, 'listed' spaces already on
  /// nomadwise.io, 'new' spaces not listed yet.
  String _who = '';

  Map<String, dynamic> _map(String k) {
    final v = widget.data?[k];
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  List<Map<String, dynamic>> _list(String k) {
    final v = widget.data?[k];
    return v is List
        ? [for (final x in v) if (x is Map) Map<String, dynamic>.from(x)]
        : <Map<String, dynamic>>[];
  }

  static double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

  static String _short(double v) {
    if (v >= 1000000) return '${_trim(v / 1000000)}m';
    if (v >= 10000) return '${(v / 1000).round()}k';
    if (v >= 1000) return '${_trim(v / 1000)}k';
    return _trim(v);
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

  static String _whole(num v) => NumberFormat.decimalPattern().format(v);

  static DateTime? _date(Object? v) => DateTime.tryParse('${v ?? ''}');

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final phone = width < 600;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(
        title: const Text('Home'),
        actions: widget.actions,
      ),
      body: RefreshIndicator(
        color: Brand.red,
        onRefresh: widget.onRefresh,
        child: LayoutBuilder(builder: (context, box) {
          final pad = phone ? 16.0 : 28.0;
          final inner = math.min(box.maxWidth - 2 * pad, 1180.0);
          return ListView(
            padding: EdgeInsets.symmetric(
                horizontal: math.max(pad, (box.maxWidth - inner) / 2), vertical: phone ? 12 : 20),
            children: [
              if (!phone)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(children: [
                    const Expanded(child: _Heading('WHERE WE STAND')),
                    Text(DateFormat('EEEE d MMM').format(DateTime.now()),
                        style: const TextStyle(fontSize: 13, color: Brand.inkSecondary)),
                  ]),
                )
              else
                const _Heading('WHERE WE STAND'),
              const SizedBox(height: 10),
              if (widget.data == null && widget.error == null)
                const _Card(
                    child: SizedBox(
                        height: 120,
                        child: Center(child: CircularProgressIndicator(color: Brand.red))))
              else if (widget.data == null)
                _Card(
                  child: Row(children: [
                    Expanded(
                        child: Text('The numbers could not be read: ${widget.error}',
                            style: const TextStyle(fontSize: 13.5, color: Brand.inkSecondary))),
                    TextButton(onPressed: widget.onRefresh, child: const Text('Try again')),
                  ]),
                )
              else ...[
                phone ? _standPhone() : _standWide(inner),
                const SizedBox(height: 14),
                _outreachCard(phone),
              ],
              const SizedBox(height: 22),
              const _Heading('WHAT YOU COULD DO'),
              const SizedBox(height: 4),
              const Text('Pick any. A red dot means someone is waiting on us.',
                  style: TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
              const SizedBox(height: 10),
              _groupsLaid(inner >= 820),
              const SizedBox(height: 24),
            ],
          );
        }),
      ),
    );
  }

  // ------------------------------------------------- where we stand

  Widget _goalCard({bool compact = false}) {
    final g = _map('goal');
    final mrr = _num(g['mrr_eur']);
    final target = _num(g['target_eur']) > 0 ? _num(g['target_eur']) : 1000.0;
    final paying = _num(g['paying']).round();
    final money = NumberFormat.currency(symbol: '€', decimalDigits: 0);
    final bar = ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: (mrr / target).clamp(0.01, 1.0),
        minHeight: compact ? 7 : 8,
        backgroundColor: Brand.field,
        color: Brand.success,
      ),
    );
    if (compact) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Expanded(
              child: Text('Goal ${money.format(target)} a month',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800))),
          Text(money.format(mrr), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 8),
        bar,
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Goal: ${money.format(target)} a month from Premium',
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 8, children: [
        Text(money.format(mrr),
            style: const TextStyle(fontSize: 30, height: 1.1, fontWeight: FontWeight.w800)),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('a month · $paying paying',
              style: const TextStyle(fontSize: 13, color: Brand.inkSecondary)),
        ),
      ]),
      const SizedBox(height: 10),
      bar,
      const SizedBox(height: 10),
      Text('${_whole(_num(g['live']))} spaces live · ${_whole(_num(g['claimed']))} claimed',
          style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
    ]);
  }

  /// Claims a month, the current month so far in a lighter green.
  Widget _claimsChart() {
    final rows = _list('claims');
    final target = _num(_map('targets')['claims_month']);
    return HomeBarChart(
      target: target > 0 ? target : null,
      totals: true,
      columns: [
        for (final r in rows)
          BarColumn(
            r['so_far'] == true
                ? '${_monthName(r['month'])} so far'
                : _monthName(r['month']),
            [(_num(r['n']), r['so_far'] == true ? const Color(0xFFA7D7B3) : Brand.success)],
          ),
      ],
    );
  }

  static String _monthName(Object? m) {
    final d = _date(m);
    return d == null ? '' : DateFormat('MMM').format(d);
  }

  Widget _monthsChart(String key) => HomeBarChart(
        columns: [
          for (final r in _list(key)) BarColumn(_monthName(r['month']), [(_num(r['n']), _blue)]),
        ],
      );

  /// "115k in October": the last full month.
  String _lastMonth(String key) {
    final rows = _list(key);
    if (rows.isEmpty) return '';
    final last = rows.last;
    final d = _date(last['month']);
    return '${_short(_num(last['n']))} in ${d == null ? '' : DateFormat('MMMM').format(d)}';
  }

  Widget _standWide(double inner) {
    final cards = <Widget>[
      _Card(child: _goalCard()),
      _Card(
          child: _Titled(
              title: 'Claims a month',
              sub: _num(_map('targets')['claims_month']) > 0
                  ? 'target ${_trim(_num(_map('targets')['claims_month']))}'
                  : null,
              child: _claimsChart())),
      _Card(
          child: _Titled(
              title: 'Shown in Google',
              foot: _lastMonth('google'),
              child: _monthsChart('google'))),
      _Card(
          child: _Titled(
              title: 'Page views', foot: _lastMonth('views'), child: _monthsChart('views'))),
    ];
    const gap = 14.0;
    final across = inner >= 980 ? 4 : 2;
    final w = (inner - (across - 1) * gap) / across;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [for (final c in cards) SizedBox(width: w, height: 236, child: c)],
    );
  }

  Widget _standPhone() {
    final claims = _list('claims');
    final now = claims.isEmpty ? 0 : _num(claims.last['n']).round();
    final target = _num(_map('targets')['claims_month']).round();
    final google = _list('google');
    final views = _list('views');
    final gLast = google.isEmpty ? null : google.last;
    final vLast = views.isEmpty ? null : views.last;
    String month(Map<String, dynamic>? r) {
      final d = _date(r?['month']);
      return d == null ? '' : DateFormat('MMM').format(d);
    }

    Widget tile(String n, String words, {Color? color}) => Container(
          padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
          decoration: BoxDecoration(color: Brand.bg, borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: color)),
            Text(words, style: const TextStyle(fontSize: 11.5, color: Brand.inkSecondary)),
          ]),
        );
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _goalCard(compact: true),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, box) {
          final w = (box.maxWidth - 8) / 2;
          return Wrap(spacing: 8, runSpacing: 8, children: [
            SizedBox(
                width: w,
                child: tile(_whole(_num(_map('goal')['claimed'])), 'claimed',
                    color: const Color(0xFF2E7D46))),
            SizedBox(
                width: w,
                child: tile(target > 0 ? '$now of $target' : '$now', 'claims this month')),
            SizedBox(
                width: w,
                child: tile(_short(_num(gLast?['n'])), 'shown in Google, ${month(gLast)}')),
            SizedBox(
                width: w,
                child: tile(_whole(_num(vLast?['n'])), 'page views, ${month(vLast)}')),
          ]);
        }),
      ]),
    );
  }

  Widget _outreachCard(bool phone) {
    final weeks = _list('outreach');
    final target = _num(_map('targets')['outreach_sent_week']);
    double n(Map<String, dynamic> w, String part, String way) {
      final p = w[part];
      return p is Map ? _num(p[way]) : 0;
    }

    final cols = [
      for (final w in weeks)
        BarColumn(
          _date(w['week']) == null ? '' : DateFormat('d MMM').format(_date(w['week'])!),
          [
            for (final way in _ways)
              (
                switch (_who) {
                  'listed' => n(w, 'listed', way.$1),
                  'new' => n(w, 'new', way.$1),
                  _ => n(w, 'listed', way.$1) + n(w, 'new', way.$1),
                },
                way.$3
              ),
          ],
        ),
    ];
    final toggle = _Segmented(
      value: _who,
      options: const [('', 'All'), ('listed', 'Already listed'), ('new', 'Not listed yet')],
      onChanged: (v) => setState(() => _who = v),
    );
    final title = Text.rich(TextSpan(children: [
      TextSpan(
          text: phone ? 'Outreach each week' : 'Outreach sent each week',
          style: const TextStyle(fontWeight: FontWeight.w800)),
      if (target > 0)
        TextSpan(
            text: ' · target ${_trim(target)}',
            style: const TextStyle(fontWeight: FontWeight.w500, color: Brand.inkSecondary)),
    ]), style: const TextStyle(fontSize: 13.5, color: Brand.ink));
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (phone) ...[
          title,
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerLeft, child: toggle),
        ] else
          Row(children: [Expanded(child: title), toggle]),
        const SizedBox(height: 10),
        HomeBarChart(
          columns: cols,
          target: target > 0 ? target : null,
          totals: true,
          height: phone ? 90 : 110,
          compactLabels: phone,
          onTap: widget.onOutreachWeek == null
              ? null
              : (i) {
                  final w = _date(weeks[i]['week']);
                  if (w != null) widget.onOutreachWeek!(w, _who);
                },
        ),
        const SizedBox(height: 4),
        Center(
            child: Text(
                widget.onOutreachWeek == null
                    ? 'Week starting Monday'
                    : 'Week starting Monday · tap a bar to see the spaces',
                style: const TextStyle(fontSize: 11, color: Brand.inkMuted))),
        const SizedBox(height: 8),
        Wrap(spacing: 14, runSpacing: 6, children: [
          for (final way in _ways)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 9,
                  height: 9,
                  decoration:
                      BoxDecoration(color: way.$3, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 5),
              Text(way.$2, style: const TextStyle(fontSize: 12, color: Brand.inkSecondary)),
            ]),
        ]),
      ]),
    );
  }

  // ------------------------------------------------ what you could do

  Widget _groupsLaid(bool two) {
    final cards = [for (final g in widget.groups) _groupCard(g)];
    if (!two) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final c in cards) Padding(padding: const EdgeInsets.only(bottom: 12), child: c),
      ]);
    }
    // Two columns, each card under the one before it (no gaps when one
    // card is longer than the one beside it).
    final left = <Widget>[], right = <Widget>[];
    for (var i = 0; i < cards.length; i++) {
      (i.isEven ? left : right)
          .add(Padding(padding: const EdgeInsets.only(bottom: 14), child: cards[i]));
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left)),
      const SizedBox(width: 14),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right)),
    ]);
  }

  void _showInfo(HomeGroup g) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          title: Text(g.title),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Text(g.info!,
                style: const TextStyle(fontSize: 14.5, height: 1.5, color: Brand.ink)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
          ],
        ),
      );

  Widget _groupCard(HomeGroup g) => _Card(
        border: g.urgent && g.rows.any((r) => r.waiting) ? Brand.red : null,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Expanded(
                child: Text(g.title,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              ),
              if (g.info != null)
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    tooltip: 'What is this for?',
                    padding: EdgeInsets.zero,
                    iconSize: 19,
                    color: Brand.inkMuted,
                    onPressed: () => _showInfo(g),
                    icon: const Icon(Icons.info_outline),
                  ),
                ),
            ]),
          ),
          if (g.rows.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(0, 8, 0, 12),
              child: Text('Nothing here right now.',
                  style: TextStyle(fontSize: 13.5, color: Brand.inkMuted)),
            ),
          for (final r in g.rows)
            InkWell(
              onTap: r.onTap,
              child: Container(
                constraints: const BoxConstraints(minHeight: 44),
                decoration:
                    const BoxDecoration(border: Border(top: BorderSide(color: Brand.hairline))),
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  if (g.urgent) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: r.waiting ? Brand.red : Colors.transparent,
                          borderRadius: BorderRadius.circular(4)),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                      child: Text(r.label,
                          style: const TextStyle(fontSize: 14, height: 1.3, color: Brand.ink))),
                  if (r.count != null) ...[
                    const SizedBox(width: 8),
                    Text(_whole(r.count!),
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                  ],
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right, size: 18, color: Brand.inkMuted),
                ]),
              ),
            ),
        ]),
      );
}

// ------------------------------------------------------------ pieces

class _Heading extends StatelessWidget {
  final String text;
  const _Heading(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: .7, color: Brand.inkSecondary));
}

class _Card extends StatelessWidget {
  final Widget child;
  final Color? border;
  final EdgeInsets padding;
  const _Card({required this.child, this.border, this.padding = const EdgeInsets.all(16)});
  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border ?? Brand.border),
        ),
        child: child,
      );
}

/// A chart with its title on top and a line of words under it.
class _Titled extends StatelessWidget {
  final String title;
  final String? sub;
  final String? foot;
  final Widget child;
  const _Titled({required this.title, required this.child, this.sub, this.foot});
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text.rich(
            TextSpan(children: [
              TextSpan(text: title, style: const TextStyle(fontWeight: FontWeight.w800)),
              if (sub != null)
                TextSpan(
                    text: ' · $sub',
                    style: const TextStyle(fontWeight: FontWeight.w500, color: Brand.inkSecondary)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, color: Brand.ink)),
        const SizedBox(height: 6),
        Expanded(child: Align(alignment: Alignment.bottomCenter, child: child)),
        if (foot != null && foot!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(foot!, style: const TextStyle(fontSize: 12, color: Brand.inkSecondary)),
        ],
      ]);
}

class _Segmented extends StatelessWidget {
  final String value;
  final List<(String, String)> options;
  final ValueChanged<String> onChanged;
  const _Segmented({required this.value, required this.options, required this.onChanged});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration:
            BoxDecoration(color: const Color(0xFFECEEF1), borderRadius: BorderRadius.circular(8)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final o in options)
            Semantics(
              button: true,
              selected: o.$1 == value,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => onChanged(o.$1),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 30),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: o.$1 == value ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: o.$1 == value
                        ? const [
                            BoxShadow(color: Color(0x1F142032), blurRadius: 2, offset: Offset(0, 1))
                          ]
                        : null,
                  ),
                  child: Text(o.$2,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: o.$1 == value ? FontWeight.w700 : FontWeight.w600,
                          color: o.$1 == value ? Brand.ink : Brand.inkSecondary)),
                ),
              ),
            ),
        ]),
      );
}

// ------------------------------------------------------------- chart

/// One bar: its label under it and its parts, bottom first.
class BarColumn {
  final String label;
  final List<(double, Color)> parts;
  const BarColumn(this.label, this.parts);
  double get total => parts.fold(0.0, (s, p) => s + p.$1);
}

/// Bars with a scale up the left and faint lines across (Jonathan,
/// 9 Nov 2026: "I prefer to see a y axis gauge on numbers, so I can
/// easily see a size reference on the bar"), and a dashed line for a
/// target.
class HomeBarChart extends StatelessWidget {
  final List<BarColumn> columns;
  final double? target;

  /// The total over each bar that has one.
  final bool totals;
  final double height;

  /// Shorter labels under the bars (a phone): the first word only.
  final bool compactLabels;

  /// A bar (or its label) tapped, by its place in [columns].
  final void Function(int index)? onTap;
  const HomeBarChart({
    super.key,
    required this.columns,
    this.target,
    this.totals = false,
    this.height = 96,
    this.compactLabels = false,
    this.onTap,
  });

  Widget _tappable(int i, Widget child) => onTap == null
      ? child
      : MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
              behavior: HitTestBehavior.opaque, onTap: () => onTap!(i), child: child),
        );

  /// A round step so the scale has two to four lines: 1, 2 or 5 times
  /// a power of ten.
  static double _step(double top) {
    if (top <= 0) return 1;
    final raw = top / 3;
    final p = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    for (final m in const [1.0, 2.0, 5.0, 10.0]) {
      if (raw <= m * p) return math.max(1, m * p);
    }
    return 10 * p;
  }

  static String _label(double v) {
    if (v >= 1000000) return '${_HomeViewState._trim(v / 1000000)}m';
    if (v >= 1000) return '${_HomeViewState._trim(v / 1000)}k';
    return _HomeViewState._trim(v);
  }

  @override
  Widget build(BuildContext context) {
    final most = columns.fold(0.0, (m, c) => math.max(m, c.total));
    final top0 = math.max(most, (target ?? 0) * 1.1);
    final step = _step(top0 <= 0 ? 4 : top0);
    final top = (top0 / step).ceil() * step == 0 ? step : (top0 / step).ceil() * step;
    final ticks = [for (var t = 0.0; t <= top + step / 2; t += step) t];
    final widest = ticks.map(_label).fold(0, (m, s) => math.max(m, s.length));
    final axis = 10.0 + widest * 6.5;
    final h = height;
    double y(double v) => v / top * h;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 8),
      SizedBox(
        height: h,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: axis,
            child: Stack(clipBehavior: Clip.none, children: [
              for (final t in ticks)
                Positioned(
                  right: 6,
                  bottom: y(t) - 7,
                  child: Text(_label(t),
                      style: const TextStyle(fontSize: 10.5, height: 1.3, color: Brand.inkSecondary)),
                ),
            ]),
          ),
          Expanded(
            child: Stack(clipBehavior: Clip.none, children: [
              for (final t in ticks)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: y(t),
                  child: Container(
                      height: 1,
                      color: t == 0 ? const Color(0x33142032) : const Color(0x14142032)),
                ),
              if (target != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: y(target!),
                  child: const SizedBox(
                      height: 1.5, child: CustomPaint(painter: _Dashes(Brand.goldTextDark))),
                ),
              Positioned.fill(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final (i, c) in columns.indexed)
                    Expanded(
                      child: _tappable(i, Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: columns.length > 4 ? (compactLabels ? 4 : 8) : 6),
                        child: Stack(clipBehavior: Clip.none, children: [
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                for (final p in c.parts.reversed)
                                  if (p.$1 > 0) Container(height: y(p.$1), color: p.$2),
                              ]),
                            ),
                          ),
                          if (totals && c.total > 0)
                            Positioned(
                              left: -8,
                              right: -8,
                              bottom: y(c.total) + 2,
                              child: Text(_label(c.total),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: 11, fontWeight: FontWeight.w700, color: Brand.ink)),
                            ),
                        ]),
                      )),
                    ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 5),
      Row(children: [
        SizedBox(width: axis),
        for (final (i, c) in columns.indexed)
          Expanded(
            child: _tappable(
                i,
                Text(compactLabels ? c.label.split(' ').first : c.label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    softWrap: false,
                    style: const TextStyle(fontSize: 11, color: Brand.inkSecondary))),
          ),
      ]),
    ]);
  }
}

class _Dashes extends CustomPainter {
  final Color color;
  const _Dashes(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(Offset(x, 0), Offset(math.min(x + 4, size.width), 0), p);
    }
  }

  @override
  bool shouldRepaint(_Dashes old) => old.color != color;
}


// ----------------------------------------------------- one week's outreach

/// The spaces behind one bar of "Outreach sent each week" (Jonathan,
/// 9 Nov 2026: "if i click onto a particular bar, a modal appears
/// showing me a breakdown of each space contacted"). A box in the
/// middle on a computer, a sheet from the bottom on a phone. Tapping a
/// space opens its overview.
Future<void> showOutreachWeek(
  BuildContext context, {
  required DateTime week,
  required String who,
  required Future<List<Map<String, dynamic>>> Function() load,
  required void Function(String venueId, String name) openSpace,
}) {
  final wide = MediaQuery.sizeOf(context).width >= 700;
  Widget body(BuildContext ctx) => _OutreachWeek(
        week: week,
        who: who,
        load: load,
        openSpace: (id, name) {
          Navigator.of(ctx).pop();
          openSpace(id, name);
        },
      );
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: 640, maxHeight: MediaQuery.sizeOf(ctx).height * .8),
          child: body(ctx),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * .85),
      child: body(ctx),
    ),
  );
}

class _OutreachWeek extends StatefulWidget {
  final DateTime week;
  final String who;
  final Future<List<Map<String, dynamic>>> Function() load;
  final void Function(String venueId, String name) openSpace;
  const _OutreachWeek(
      {required this.week, required this.who, required this.load, required this.openSpace});
  @override
  State<_OutreachWeek> createState() => _OutreachWeekState();
}

class _OutreachWeekState extends State<_OutreachWeek> {
  late String _who = widget.who;
  List<Map<String, dynamic>>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.load().then((r) {
      if (mounted) setState(() => _rows = r);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  static String _wayName(String w) => {
        for (final x in _ways) x.$1: x.$2,
      }[w] ??
      'Email';

  static Color _wayColor(String w) => {
        for (final x in _ways) x.$1: x.$3,
      }[w] ??
      _blue;

  /// Where things stand with the space now, in words, and its colour.
  static (String, Color) _now(Map<String, dynamic> r) {
    if (r['claimed'] == true) return ('Claimed', Brand.success);
    return switch ('${r['stage'] ?? ''}') {
      'claimed' || 'verified' => ('Claimed', Brand.success),
      'replied' => ('Wrote back', Brand.goldTextDark),
      'declined' => ('Said no', Brand.inkSecondary),
      'unsubscribed' => ('Unsubscribed', Brand.inkSecondary),
      'bounced' => ('Bounced', Brand.red),
      'not_now' => ('Put aside', Brand.inkSecondary),
      _ => r['replied'] == true
          ? ('Wrote back', Brand.goldTextDark)
          : ('No reply yet', Brand.inkMuted),
    };
  }

  @override
  Widget build(BuildContext context) {
    final all = _rows;
    final rows = all == null
        ? const <Map<String, dynamic>>[]
        : [
            for (final r in all)
              if (_who == '' ||
                  (_who == 'listed' && r['listed'] == true) ||
                  (_who == 'new' && r['listed'] != true))
                r
          ];
    final end = widget.week.add(const Duration(days: 6));
    final title = 'Week of ${DateFormat('d MMM').format(widget.week)} to '
        '${DateFormat('d MMM').format(end)}';
    final byWay = <String, int>{};
    for (final r in rows) {
      final w = '${r['way'] ?? 'email'}';
      byWay[w] = (byWay[w] ?? 0) + 1;
    }
    final claimed = rows.where((r) => _now(r).$1 == 'Claimed').length;
    final wrote = rows.where((r) => _now(r).$1 == 'Wrote back').length;

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(
                  all == null
                      ? 'Reading…'
                      : '${rows.length} ${rows.length == 1 ? 'message' : 'messages'}'
                          '${claimed > 0 ? ' · $claimed claimed' : ''}'
                          '${wrote > 0 ? ' · $wrote wrote back' : ''}',
                  style: const TextStyle(fontSize: 13, color: Brand.inkSecondary)),
            ]),
          ),
          IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: _Segmented(
            value: _who,
            options: const [('', 'All'), ('listed', 'Already listed'), ('new', 'Not listed yet')],
            onChanged: (v) => setState(() => _who = v),
          ),
        ),
      ),
      if (byWay.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Wrap(spacing: 14, runSpacing: 6, children: [
            for (final way in _ways)
              if ((byWay[way.$1] ?? 0) > 0)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                          color: way.$3, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(width: 5),
                  Text('${way.$2} ${byWay[way.$1]}',
                      style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
                ]),
          ]),
        ),
      const SizedBox(height: 10),
      const Divider(height: 1, color: Brand.hairline),
      Flexible(
        child: all == null && _error == null
            ? const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator(color: Brand.red)))
            : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('Could not read that week: $_error',
                        style: const TextStyle(color: Brand.red)))
                : rows.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Nothing was sent that week.',
                            style: TextStyle(fontSize: 14, color: Brand.inkSecondary)))
                    : ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(bottom: 12),
                        itemCount: rows.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: 20, endIndent: 20, color: Brand.hairline),
                        itemBuilder: (context, i) => _row(rows[i]),
                      ),
      ),
    ]);
  }

  Widget _row(Map<String, dynamic> r) {
    final way = '${r['way'] ?? 'email'}';
    final where = [r['city'], r['country']]
        .map((x) => '${x ?? ''}'.trim())
        .where((x) => x.isNotEmpty)
        .join(', ');
    final at = DateTime.tryParse('${r['at'] ?? ''}')?.toLocal();
    final (now, color) = _now(r);
    final id = '${r['venue_id'] ?? ''}';
    final name = '${r['name'] ?? 'A space'}';
    return InkWell(
      onTap: id.isEmpty ? null : () => widget.openSpace(id, name),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
        child: Row(children: [
          Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: _wayColor(way), borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, height: 1.3)),
              const SizedBox(height: 2),
              Text(
                  [
                    if (where.isNotEmpty) where,
                    _wayName(way),
                    if (at != null) DateFormat('EEE d MMM').format(at),
                    if (r['listed'] != true) 'not listed yet',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary, height: 1.3)),
            ]),
          ),
          const SizedBox(width: 8),
          Text(now, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
          if (id.isNotEmpty) const Icon(Icons.chevron_right, size: 18, color: Brand.inkMuted),
        ]),
      ),
    );
  }
}
