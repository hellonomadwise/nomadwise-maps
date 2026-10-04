import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Page upgrades (migration 125): changes to listing pages on
/// nomadwise.io, lined up by how much they are likely to matter. Each
/// card is one change to one page, with the text on the page now and
/// the proposed text. Nothing reaches the website until a founder
/// presses Go; the website push then writes it within minutes, and
/// Undo puts the old text back. Founders only.
class AdminUpgradesScreen extends StatefulWidget {
  const AdminUpgradesScreen({super.key});
  @override
  State<AdminUpgradesScreen> createState() => _AdminUpgradesScreenState();
}

class _AdminUpgradesScreenState extends State<AdminUpgradesScreen> {
  final _supabase = SupabaseService();
  final _search = TextEditingController();
  Map<String, dynamic> _overview = {};
  List<Map<String, dynamic>>? _rows;
  String _status = 'proposed';
  String _kind = '';
  String? _error;
  // Cards with a Go, Skip or Undo on its way, so a second tap does
  // nothing; and the kind being prepared.
  final Set<String> _busy = {};
  String _preparing = '';
  bool _goingAll = false;

  static const _statuses = <(String, String)>[
    ('proposed', 'Waiting for your Go'),
    ('approved', 'On its way'),
    ('applied', 'Live'),
    ('failed', 'Needs a look'),
    ('skipped', 'Skipped'),
  ];

  static const _kindFilters = <(String, String)>[
    ('', 'All kinds'),
    ('search_description', 'Search descriptions'),
    ('description', 'Page descriptions'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // Counts the loads, so a slow earlier answer never overwrites the
  // tab picked after it.
  int _req = 0;

  Future<void> _load() async {
    final n = ++_req;
    try {
      final rows = await _supabase.upgradesList(
          status: _status, kind: _kind, query: _search.text.trim());
      final overview = await _supabase.upgradesOverview();
      if (!mounted || n != _req) return;
      setState(() {
        _rows = rows;
        _overview = overview;
        _error = null;
      });
    } catch (e) {
      if (mounted && n == _req) setState(() => _error = _plain(e));
    }
  }

  void _snack(String text, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  /// The database's own words for a refused action.
  String _plain(Object e) {
    if (e is PostgrestException) return e.message;
    final s = '$e';
    final m = RegExp(r'message: (.*?), code: ', dotAll: true).firstMatch(s);
    return m?.group(1)?.trim() ?? s;
  }

  static String _when(dynamic iso) {
    final d = DateTime.tryParse('${iso ?? ''}');
    if (d == null) return '';
    return DateFormat('d MMM yyyy').format(d.toLocal());
  }

  static int _int(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

  int _count(String status) {
    final c = _overview['counts'];
    if (c is! Map) return 0;
    // "On its way" also holds undos on their way back; "Skipped" also
    // holds the ones that were undone.
    final extra = status == 'approved'
        ? _int(c['undo_requested'])
        : status == 'skipped'
            ? _int(c['undone'])
            : 0;
    return _int(c[status]) + extra;
  }

  static String _kindLabel(String k) => switch (k) {
        'search_description' => 'Search description',
        'description' => 'Page description',
        'prices' => 'Prices',
        'wifi' => 'WiFi speed',
        _ => 'Other',
      };

  // ------------------------------------------------------------ actions

  Future<void> _go(Map<String, dynamic> u, {String? text}) async {
    final id = '${u['id']}';
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await _supabase.upgradeGo(id, text: text);
      _snack('${u['name']}: on its way to the website.');
      await _load();
    } catch (e) {
      _snack(_plain(e), bad: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _skip(Map<String, dynamic> u) async {
    final id = '${u['id']}';
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await _supabase.upgradeSkip(id);
      _snack('${u['name']}: skipped.');
      await _load();
    } catch (e) {
      _snack(_plain(e), bad: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _undo(Map<String, dynamic> u) async {
    final id = '${u['id']}';
    if (_busy.contains(id)) return;
    final status = '${u['status']}';
    if (status == 'applied') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Put the old text back?'),
          content: Text(
              'The page for ${u['name']} goes back to what it said before '
              'this change. It takes a few minutes.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep the change')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Put it back')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _busy.add(id));
    try {
      final now = await _supabase.upgradeUndo(id);
      _snack(now == 'undo_requested'
          ? '${u['name']}: the old text is being put back.'
          : '${u['name']}: back in the queue.');
      await _load();
    } catch (e) {
      _snack(_plain(e), bad: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _edit(Map<String, dynamic> u) async {
    final kind = '${u['kind']}';
    final isLine = kind == 'search_description';
    final ctl = TextEditingController(
        text: '${u['final'] ?? u['proposed'] ?? ''}');
    final text = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: Text('${_kindLabel(kind)} for ${u['name']}'),
          content: SizedBox(
            width: 620,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: ctl,
                    autofocus: true,
                    minLines: isLine ? 3 : 10,
                    maxLines: isLine ? 5 : 18,
                    onChanged: (_) => setInner(() {}),
                    decoration: const InputDecoration(
                        border: OutlineInputBorder(), isDense: true),
                  ),
                  const SizedBox(height: 8),
                  Text(
                      isLine
                          ? '${ctl.text.trim().length} characters. Google '
                              'shows about 160.'
                          : 'Plain text. Leave an empty line between '
                              'paragraphs, and start a line with ## for a '
                              'heading.',
                      style: const TextStyle(
                          fontSize: 12.5, color: Brand.inkSecondary)),
                ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: ctl.text.trim().isEmpty
                    ? null
                    : () => Navigator.pop(ctx, ctl.text),
                child: const Text('Go with this wording')),
          ],
        ),
      ),
    );
    // The controller is left to the garbage collector: the dialog is
    // still on screen while it closes, and reads it until then.
    if (text == null || !mounted) return;
    await _go(u, text: text);
  }

  Future<void> _goAll() async {
    final rows = _rows ?? const [];
    final ids = [
      for (final r in rows)
        if ('${r['status']}' == 'proposed') '${r['id']}'
    ];
    if (ids.isEmpty || _goingAll) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Go for all ${ids.length} shown?'),
        content: const Text(
            'Each one goes to the website as proposed, over the next few '
            'minutes. You can undo any of them afterwards on the Live tab.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not yet')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Go for ${ids.length}')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _goingAll = true);
    try {
      final n = await _supabase.upgradesGoMany(ids);
      _snack(n == ids.length
          ? '$n on their way to the website.'
          : '$n of ${ids.length} on their way. The rest need a look first.');
      await _load();
    } catch (e) {
      _snack(_plain(e), bad: true);
    } finally {
      if (mounted) setState(() => _goingAll = false);
    }
  }

  Future<void> _prepare(String kind, int n) async {
    if (_preparing.isNotEmpty) return;
    setState(() => _preparing = kind);
    try {
      final made = await _supabase.upgradesPrepare(kind, n);
      _snack(made == 0
          ? 'Nothing more to prepare.'
          : '$made added to the queue, highest impact first.');
      if (mounted) {
        setState(() {
          _status = 'proposed';
          _rows = null;
        });
      }
      await _load();
    } catch (e) {
      _snack(_plain(e), bad: true);
    } finally {
      if (mounted) setState(() => _preparing = '');
    }
  }

  Map<String, dynamic>? _openRequest(String kind) {
    final r = _overview['requests'];
    if (r is! List) return null;
    for (final x in r) {
      if (x is Map && '${x['kind']}' == kind) {
        return Map<String, dynamic>.from(x);
      }
    }
    return null;
  }

  Future<void> _ask(String kind, String title) async {
    final open = _openRequest(kind);
    int n = open == null ? 20 : _int(open['how_many']);
    if (!const [10, 20, 40].contains(n)) n = 20;
    final note = TextEditingController(text: '${open?['note'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: Text('Ask for a batch: $title'),
          content: SizedBox(
            width: 480,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'These are written from each space\'s own website, so '
                      'they are drafted outside the app. The request is kept '
                      'here; when the batch is uploaded it lands in the '
                      'queue and waits for your Go.',
                      style: TextStyle(fontSize: 13.5, height: 1.45)),
                  const SizedBox(height: 14),
                  const Text('How many pages',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: Brand.inkSecondary)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, children: [
                    for (final k in const [10, 20, 40])
                      ChoiceChip(
                        label: Text('$k'),
                        showCheckmark: false,
                        selectedColor: Brand.ink,
                        labelStyle: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: n == k ? Colors.white : Brand.ink),
                        selected: n == k,
                        onSelected: (_) => setInner(() => n = k),
                      ),
                  ]),
                  const SizedBox(height: 14),
                  TextField(
                    controller: note,
                    maxLines: 3,
                    maxLength: 400,
                    decoration: const InputDecoration(
                        labelText: 'Anything to steer it (optional)',
                        hintText: 'London first. Keep them short.',
                        border: OutlineInputBorder(),
                        isDense: true),
                  ),
                ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(open == null ? 'Ask' : 'Change the request')),
          ],
        ),
      ),
    );
    final words = note.text.trim();
    if (ok != true || !mounted) return;
    try {
      await _supabase.upgradeRequest(kind, n,
          note: words.isEmpty ? null : words);
      _snack('Asked for $n. Tell Claude the request is in, and the batch '
          'will be drafted.');
      await _load();
    } catch (e) {
      _snack(_plain(e), bad: true);
    }
  }

  Future<void> _cancelRequest(Map<String, dynamic> r) async {
    try {
      await _supabase.upgradeRequestCancel('${r['id']}');
      _snack('Request withdrawn.');
      await _load();
    } catch (e) {
      _snack(_plain(e), bad: true);
    }
  }

  // --------------------------------------------------------------- help

  static const _help = <(IconData, String, String)>[
    (
      Icons.auto_fix_high_outlined,
      'What this is',
      'A queue of improvements to the listing pages on nomadwise.io. Each '
          'card is one change to one page, with what the page says now and '
          'what is proposed. Nothing reaches the website until you press Go.'
    ),
    (
      Icons.sort,
      'The order',
      'Highest impact first. The score comes from how many people viewed '
          'the page in the last 90 days, how well known the place is on '
          'Google, and whether it is a coworking space. The reason is on '
          'every card.'
    ),
    (
      Icons.category_outlined,
      'Two kinds of upgrade',
      'Search descriptions (the line Google shows under the title) are '
          'built from facts we already hold, so "Prepare" adds more to the '
          'queue at once.\n'
          'Page descriptions and prices have to be written from each '
          'space\'s own website. "Ask for a batch" files a request; the '
          'batch is drafted outside the app, uploaded, and then waits here '
          'like everything else.'
    ),
    (
      Icons.play_arrow_rounded,
      'Go, Edit and Skip',
      'Go sends the proposed text to the page. It is live within minutes.\n'
          'Edit lets you change the words first, then sends your wording.\n'
          'Skip drops it. That page is not proposed again unless you bring '
          'it back from the Skipped tab.'
    ),
    (
      Icons.undo,
      'Undo',
      'On the Live tab, Undo puts back exactly what the page said before. '
          'On the "On its way" tab, Take back stops a change that has not '
          'reached the website yet.'
    ),
    (
      Icons.shield_outlined,
      'What it leaves alone',
      'A page with an owner keeps the description its owner wrote.\n'
          'Price lines already on a page stay under a new description.\n'
          'One change per page and kind at a time.'
    ),
    (
      Icons.insights_outlined,
      'Where the numbers come from',
      'What each page holds is read from the website every night. Page '
          'views come from the site\'s analytics and are refreshed when a '
          'new batch is drafted, so a change you make here shows in the '
          'counts by the next morning.'
    ),
  ];

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('How Page upgrades works'),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final h in _help)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(h.$1, size: 20, color: Brand.logoNavy),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(h.$2,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 14.5)),
                                    const SizedBox(height: 3),
                                    Text(h.$3,
                                        style: const TextStyle(
                                            fontSize: 13.5,
                                            height: 1.45,
                                            color: Brand.inkSecondary)),
                                  ]),
                            ),
                          ]),
                    ),
                ]),
          ),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Got it')),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- build

  Widget _chip(String text, {Color? bg, Color? fg}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: bg ?? Brand.field, borderRadius: BorderRadius.circular(20)),
        child: Text(text,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: fg ?? Brand.inkSecondary)),
      );

  /// One kind of upgrade: how many pages have the gap, and the button
  /// that lines more of them up.
  Widget _kindCard(Map<String, dynamic> k) {
    final kind = '${k['kind']}';
    final title = '${k['title'] ?? _kindLabel(kind)}';
    final gap = _int(k['gap']);
    final more = _int(k['gap_more']);
    final waiting = _int(k['waiting']);
    final instant = k['instant'] == true;
    final open = _openRequest(kind);
    final canAsk = kind == 'description' || kind == 'prices';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Brand.surface,
        border: Border.all(color: Brand.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(
                      '${NumberFormat.decimalPattern().format(gap)} '
                      '${k['gap_words'] ?? 'pages'}'
                      '${more > 0 ? ', and ${NumberFormat.decimalPattern().format(more)} ${k['gap_more_words'] ?? 'more'}' : ''}'
                      '${waiting > 0 ? ' · $waiting waiting for your Go' : ''}',
                      style: const TextStyle(
                          fontSize: 13, color: Brand.inkSecondary)),
                ]),
          ),
          const SizedBox(width: 10),
          if (instant)
            PopupMenuButton<int>(
              tooltip: 'Add more of these to the queue',
              enabled: _preparing.isEmpty && gap > 0,
              onSelected: (n) => _prepare(kind, n),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 10, child: Text('Prepare 10')),
                PopupMenuItem(value: 25, child: Text('Prepare 25')),
                PopupMenuItem(value: 50, child: Text('Prepare 50')),
                PopupMenuItem(value: 100, child: Text('Prepare 100')),
              ],
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                    border: Border.all(
                        color: gap > 0 ? Brand.logoNavy : Brand.border),
                    borderRadius: BorderRadius.circular(8)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(_preparing == kind ? 'Preparing...' : 'Prepare more',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                          color: gap > 0 ? Brand.logoNavy : Brand.inkMuted)),
                  Icon(Icons.arrow_drop_down,
                      size: 20,
                      color: gap > 0 ? Brand.logoNavy : Brand.inkMuted),
                ]),
              ),
            )
          else if (canAsk)
            OutlinedButton(
                onPressed: () => _ask(kind, title),
                child: Text(open == null ? 'Ask for a batch' : 'Change')),
        ]),
        const SizedBox(height: 6),
        Text('${k['what'] ?? ''}',
            style: const TextStyle(
                fontSize: 12.5, height: 1.4, color: Brand.inkMuted)),
        if (open != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
            decoration: BoxDecoration(
                color: Brand.goldTint,
                borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Expanded(
                child: Text(
                    'Asked for ${_int(open['how_many'])} on '
                    '${_when(open['created_at'])}. Waiting to be drafted.'
                    '${'${open['note'] ?? ''}'.trim().isEmpty ? '' : ' "${'${open['note']}'.trim()}"'}',
                    style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: Brand.goldTextDark)),
              ),
              TextButton(
                  onPressed: () => _cancelRequest(open),
                  child: const Text('Withdraw')),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _textBox(String label, String text,
      {required bool proposed, String? foot}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: proposed ? Brand.logoTealTint : Brand.field,
          borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(),
            style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.4,
                fontWeight: FontWeight.w800,
                color: proposed ? Brand.logoNavy : Brand.inkMuted)),
        const SizedBox(height: 4),
        SelectableText(text,
            style: TextStyle(
                fontSize: 13.5,
                height: 1.45,
                color: proposed ? Brand.ink : Brand.inkSecondary)),
        if (foot != null && foot.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(foot,
              style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
        ],
      ]),
    );
  }

  Widget _card(Map<String, dynamic> u) {
    final id = '${u['id']}';
    final kind = '${u['kind']}';
    final status = '${u['status']}';
    final name = '${u['name'] ?? ''}'.trim();
    final area = '${u['area'] ?? ''}'.trim();
    final region = '${u['region'] ?? ''}'.trim();
    final country = '${u['country'] ?? ''}'.trim();
    final where = <String>[
      if (area.isNotEmpty) area,
      if (region.isNotEmpty && region.toLowerCase() != area.toLowerCase())
        region,
      if (country.isNotEmpty && country.toLowerCase() != region.toLowerCase())
        country,
    ].join(', ');
    final slug = '${u['slug'] ?? ''}'.trim();
    final before = '${u['before'] ?? ''}'.trim();
    final proposed = '${u['final'] ?? u['proposed'] ?? ''}'.trim();
    final note = '${u['note'] ?? ''}'.trim();
    final error = '${u['error'] ?? ''}'.trim();
    final busy = _busy.contains(id);
    final isLine = kind == 'search_description';
    final edited = u['final'] != null &&
        '${u['final']}'.trim() != '${u['proposed'] ?? ''}'.trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Brand.surface,
        border: Border.all(color: Brand.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(name.isEmpty ? 'A page' : name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15.5)),
              _chip(_kindLabel(kind).toUpperCase(),
                  bg: Brand.logoTealTint, fg: Brand.logoNavy),
              if ('${u['source']}' == 'drafted') _chip('DRAFTED'),
              if (u['owned'] == true)
                _chip('HAS AN OWNER',
                    bg: Brand.goldTint, fg: Brand.goldTextDark),
            ]),
        const SizedBox(height: 3),
        Text(
            [
              if (where.isNotEmpty) where,
              '${u['reason'] ?? ''}',
            ].where((x) => x.isNotEmpty).join(' · '),
            style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        _textBox(
            status == 'applied' || status == 'undo_requested'
                ? 'Before this change'
                : 'On the page now',
            before.isEmpty
                ? (isLine ? 'Nothing.' : 'No description on the page.')
                : before,
            proposed: false),
        _textBox(
            status == 'applied'
                ? 'Live on the page'
                : edited
                    ? 'Your wording'
                    : 'Proposed',
            proposed,
            proposed: true,
            foot: isLine ? '${proposed.length} characters' : null),
        if (note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Note: $note',
                style: const TextStyle(
                    fontSize: 12.5, height: 1.4, color: Brand.inkSecondary)),
          ),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('It did not go through: $error',
                style: const TextStyle(
                    fontSize: 12.5, height: 1.4, color: Brand.red)),
          ),
        const SizedBox(height: 8),
        Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (status == 'proposed' || status == 'failed') ...[
                FilledButton.icon(
                    onPressed: busy ? null : () => _go(u),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: Text(status == 'failed' ? 'Try again' : 'Go')),
                OutlinedButton(
                    onPressed: busy ? null : () => _edit(u),
                    child: const Text('Edit')),
                TextButton(
                    onPressed: busy ? null : () => _skip(u),
                    child: const Text('Skip')),
              ],
              if (status == 'approved') ...[
                const Text('On its way to the website.',
                    style: TextStyle(fontSize: 13, color: Brand.inkSecondary)),
                TextButton(
                    onPressed: busy ? null : () => _undo(u),
                    child: const Text('Take back')),
              ],
              if (status == 'undo_requested')
                const Text('The old text is being put back.',
                    style: TextStyle(fontSize: 13, color: Brand.inkSecondary)),
              if (status == 'applied') ...[
                Text('Live since ${_when(u['applied_at'])}.',
                    style: const TextStyle(
                        fontSize: 13, color: Brand.success)),
                TextButton(
                    onPressed: busy ? null : () => _undo(u),
                    child: const Text('Undo')),
              ],
              if (status == 'skipped' || status == 'undone') ...[
                Text(status == 'undone' ? 'Undone.' : 'Skipped.',
                    style: const TextStyle(
                        fontSize: 13, color: Brand.inkSecondary)),
                TextButton(
                    onPressed: busy ? null : () => _undo(u),
                    child: const Text('Bring back')),
              ],
              if (slug.isNotEmpty)
                TextButton.icon(
                    onPressed: () => launchUrl(
                        Uri.parse('https://www.nomadwise.io/coworking/$slug')),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('See the page')),
            ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final kinds = _overview['kinds'];
    final pages = _int(_overview['pages']);
    final factsPages = _int(_overview['facts_pages']);
    final proposedShown = [
      for (final r in rows ?? const <Map<String, dynamic>>[])
        if ('${r['status']}' == 'proposed') r
    ].length;

    return Scaffold(
      appBar: AppBar(title: const Text('Page upgrades')),
      body: _error != null
          ? Center(
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
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 40),
                      children: [
                        Row(children: [
                          const Expanded(
                            child: Text(
                                'Changes to listing pages, lined up by how '
                                'much they are likely to matter. Nothing '
                                'reaches the website until you press Go.',
                                style: TextStyle(
                                    fontSize: 13,
                                    height: 1.45,
                                    color: Brand.inkSecondary)),
                          ),
                          TextButton.icon(
                              onPressed: _showHelp,
                              icon: const Icon(Icons.help_outline, size: 18),
                              label: const Text('How it works')),
                        ]),
                        if (_overview.isNotEmpty && factsPages < pages) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                                color: Brand.goldTint,
                                borderRadius: BorderRadius.circular(10)),
                            child: Text(
                                factsPages == 0
                                    ? 'The pages have not been read yet. The '
                                        'counts fill in after tonight\'s sync.'
                                    : '$factsPages of $pages pages have been '
                                        'read so far. The rest follow with '
                                        'tonight\'s sync.',
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    height: 1.4,
                                    color: Brand.goldTextDark)),
                          ),
                        ],
                        const SizedBox(height: 12),
                        const Text('WHAT CAN BE IMPROVED',
                            style: TextStyle(
                                fontSize: 11,
                                letterSpacing: 0.5,
                                fontWeight: FontWeight.w800,
                                color: Brand.inkMuted)),
                        const SizedBox(height: 8),
                        if (kinds is List)
                          for (final k in kinds)
                            if (k is Map)
                              _kindCard(Map<String, dynamic>.from(k)),
                        const SizedBox(height: 12),
                        const Text('THE QUEUE',
                            style: TextStyle(
                                fontSize: 11,
                                letterSpacing: 0.5,
                                fontWeight: FontWeight.w800,
                                color: Brand.inkMuted)),
                        const SizedBox(height: 8),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final s in _statuses)
                            ChoiceChip(
                              label: Text('${s.$2} ${_count(s.$1)}'),
                              showCheckmark: false,
                              selectedColor: Brand.ink,
                              labelStyle: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: _status == s.$1
                                      ? Colors.white
                                      : Brand.ink),
                              selected: _status == s.$1,
                              onSelected: (_) {
                                setState(() {
                                  _status = s.$1;
                                  _rows = null;
                                });
                                _load();
                              },
                            ),
                        ]),
                        const SizedBox(height: 8),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final k in _kindFilters)
                            ChoiceChip(
                              label: Text(k.$2),
                              showCheckmark: false,
                              selectedColor: Brand.logoNavy,
                              labelStyle: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: _kind == k.$1
                                      ? Colors.white
                                      : Brand.ink),
                              selected: _kind == k.$1,
                              onSelected: (_) {
                                setState(() {
                                  _kind = k.$1;
                                  _rows = null;
                                });
                                _load();
                              },
                            ),
                        ]),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) {
                            setState(() => _rows = null);
                            _load();
                          },
                          decoration: InputDecoration(
                            hintText: 'Search by space, area, city or country',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _search.text.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      _search.clear();
                                      setState(() => _rows = null);
                                      _load();
                                    }),
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (rows == null)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(
                                child: CircularProgressIndicator(
                                    color: Brand.red)),
                          )
                        else if (rows.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Center(
                              child: Text(
                                  switch (_status) {
                                    'proposed' =>
                                      'Nothing is waiting. Prepare more '
                                          'above, or ask for a batch.',
                                    'approved' =>
                                      'Nothing is on its way right now.',
                                    'applied' =>
                                      'Nothing has gone live from here yet.',
                                    'failed' =>
                                      'Nothing needs a look.',
                                    _ => 'Nothing has been skipped.',
                                  },
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: Brand.inkSecondary)),
                            ),
                          )
                        else ...[
                          if (_status == 'proposed' && proposedShown > 1)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Row(children: [
                                Expanded(
                                  child: Text(
                                      'Showing ${rows.length}, highest '
                                      'impact first.',
                                      style: const TextStyle(
                                          fontSize: 12.5,
                                          color: Brand.inkSecondary)),
                                ),
                                OutlinedButton(
                                    onPressed: _goingAll ? null : _goAll,
                                    child: Text(_goingAll
                                        ? 'Sending...'
                                        : 'Go for all $proposedShown shown')),
                              ]),
                            ),
                          for (final u in rows) _card(u),
                        ],
                      ]),
                ),
              ),
            ),
    );
  }
}
