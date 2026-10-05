import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import 'website_screen.dart' show openLivePagePhotos;

/// The database's own words for a refused action.
String _plainError(Object e) {
  if (e is PostgrestException) return e.message;
  final s = '$e';
  final m = RegExp(r'message: (.*?), code: ', dotAll: true).firstMatch(s);
  return m?.group(1)?.trim() ?? s;
}

/// A photo list as the database keeps it (a JSON array of links, or
/// already a list), as links.
List<String> _photoLinks(dynamic v) {
  dynamic j = v;
  if (v is String) {
    try {
      j = jsonDecode(v);
    } catch (_) {
      return const [];
    }
  }
  if (j is! List) return const [];
  return [
    for (final x in j)
      if ('$x'.trim().startsWith('http')) '$x'.trim()
  ];
}

/// Small pictures in a row, in page order.
Widget _photoStrip(List<String> urls) {
  if (urls.isEmpty) {
    return const Text('No photos.',
        style: TextStyle(fontSize: 13, color: Brand.inkSecondary));
  }
  return Wrap(spacing: 6, runSpacing: 6, children: [
    for (final u in urls)
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(u,
            width: 84,
            height: 63,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
                width: 84,
                height: 63,
                color: Brand.field,
                child: const Icon(Icons.broken_image_outlined,
                    color: Brand.inkMuted))),
      ),
  ]);
}

String _when(dynamic iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  if (d == null) return '';
  return DateFormat('d MMM yyyy').format(d.toLocal());
}

int _int(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

String _num(int n) => NumberFormat.decimalPattern().format(n);

String _kindLabel(String k) => switch (k) {
      'title' => 'Page title',
      'search_description' => 'Search description',
      'description' => 'Page description',
      'photos' => 'Photos',
      'prices' => 'Prices',
      'wifi' => 'WiFi speed',
      _ => 'Other',
    };

/// What each text part of a page is, in a line.
String _kindWhat(String k) => switch (k) {
      'title' => 'The headline Google shows for the page, and the name on '
          'the browser tab. About 60 characters show.',
      'search_description' => 'The line Google shows under the headline. '
          'About 160 characters show.',
      'description' => 'The text of the page itself.',
      _ => '',
    };

/// "Area, Region, Country" without repeats.
String _whereOf(Map<String, dynamic> r) {
  final area = '${r['area'] ?? ''}'.trim();
  final region = '${r['region'] ?? ''}'.trim();
  final country = '${r['country'] ?? ''}'.trim();
  return <String>[
    if (area.isNotEmpty) area,
    if (region.isNotEmpty && region.toLowerCase() != area.toLowerCase()) region,
    if (country.isNotEmpty && country.toLowerCase() != region.toLowerCase())
      country,
  ].join(', ');
}

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

/// What the page has now on the left, the upgrade on the right; one
/// under the other where the screen is narrow.
Widget _compare(Widget left, Widget right) => LayoutBuilder(
      builder: (ctx, box) => box.maxWidth >= 620
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: left),
              const SizedBox(width: 10),
              Expanded(child: right),
            ])
          : Column(children: [left, right]),
    );

/// The note that goes with "Request upgrade". Returns the note (it
/// may be empty), or null when the box was closed without asking.
Future<String?> _askRequestNote(
    BuildContext context, String name, String start) async {
  final note = TextEditingController(text: start);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Request an upgrade for $name'),
      content: SizedBox(
        width: 480,
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'The page is put on the list to be drafted: a title, a '
                  'search description and a page description, written '
                  'from what people search for and from the space\'s own '
                  'website. The drafts come back here and wait for your Go.',
                  style: TextStyle(fontSize: 13.5, height: 1.45)),
              const SizedBox(height: 14),
              TextField(
                controller: note,
                maxLines: 3,
                maxLength: 400,
                decoration: const InputDecoration(
                    labelText: 'Anything to steer it (optional)',
                    hintText: 'They have a pool. Keep it short.',
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
            child: const Text('Request upgrade')),
      ],
    ),
  );
  // The controller is left to the garbage collector: the dialog reads
  // it while it closes.
  if (ok != true) return null;
  return note.text.trim();
}

/// Go, Edit, Skip and Undo for one upgrade, the same on the queue and
/// on the one-page view.
mixin _UpgradeActions<T extends StatefulWidget> on State<T> {
  final _supabase = SupabaseService();
  // Upgrades with a Go, Skip or Undo on its way, so a second tap does
  // nothing.
  final Set<String> _busy = {};

  /// Loads the screen again after a change.
  Future<void> _load();

  void _snack(String text, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  Future<void> _go(Map<String, dynamic> u, {String? text}) async {
    final id = '${u['id']}';
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await _supabase.upgradeGo(id, text: text);
      _snack('${u['name']}: on its way to the website.');
      await _load();
    } catch (e) {
      _snack(_plainError(e), bad: true);
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
      _snack(_plainError(e), bad: true);
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
          title: const Text('Put the earlier version back?'),
          content: Text(
              'The page for ${u['name']} goes back to what it had before '
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
          ? '${u['name']}: the earlier version is being put back.'
          : '${u['name']}: back in the queue.');
      await _load();
    } catch (e) {
      _snack(_plainError(e), bad: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  /// The wording box for one text part. Returns the text, or null
  /// when it was closed without saving.
  Future<String?> _askText(
      {required String kind,
      required String name,
      required String start,
      required String action}) async {
    final isLine = kind != 'description';
    final shown = kind == 'title' ? 60 : 160;
    final ctl = TextEditingController(text: start);
    final text = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: Text('${_kindLabel(kind)} for $name'),
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
                              'shows about $shown.'
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
                child: Text(action)),
          ],
        ),
      ),
    );
    // The controller is left to the garbage collector: the dialog is
    // still on screen while it closes, and reads it until then.
    return text;
  }

  /// Edit: change the words of an upgrade, then send that wording.
  Future<void> _editText(Map<String, dynamic> u) async {
    final text = await _askText(
        kind: '${u['kind']}',
        name: '${u['name'] ?? 'this page'}',
        start: '${u['final'] ?? u['proposed'] ?? ''}',
        action: 'Go with this wording');
    if (text == null || !mounted) return;
    await _go(u, text: text);
  }
}

/// Page upgrades (migrations 125, 127, 129): changes to listing pages
/// on nomadwise.io, taken one page at a time. "Choose a page" lists
/// the pages, the most promising first; a page opens with what it
/// says now next to the upgrade for its title, search description and
/// page description, each with its own Go. Photos are pasted in, as
/// for a new listing. The queue below shows every change by where it
/// stands. Nothing reaches the website until a founder presses Go;
/// the website push then writes it within minutes, and Undo puts the
/// earlier version back. Founders only.
class AdminUpgradesScreen extends StatefulWidget {
  const AdminUpgradesScreen({super.key});
  @override
  State<AdminUpgradesScreen> createState() => _AdminUpgradesScreenState();
}

class _AdminUpgradesScreenState extends State<AdminUpgradesScreen>
    with _UpgradeActions<AdminUpgradesScreen> {
  final _search = TextEditingController();
  Map<String, dynamic> _overview = {};
  List<Map<String, dynamic>>? _rows;
  String _status = 'proposed';
  String _kind = '';
  String? _error;

  static const _statuses = <(String, String)>[
    ('proposed', 'Waiting for your Go'),
    ('approved', 'On its way'),
    ('applied', 'Live'),
    ('failed', 'Needs a look'),
    ('skipped', 'Skipped'),
  ];

  static const _kindFilters = <(String, String)>[
    ('', 'All kinds'),
    ('title', 'Titles'),
    ('search_description', 'Search descriptions'),
    ('description', 'Page descriptions'),
    ('photos', 'Photos'),
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

  @override
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
      if (mounted && n == _req) setState(() => _error = _plainError(e));
    }
  }

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

  // ------------------------------------------------------------ actions

  /// Photos are changed on the photo page, not in a text box. Saving
  /// there sends the new list to the page.
  Future<void> _editPhotos(Map<String, dynamic> u) async {
    final current = _photoLinks(u['final'] ?? u['proposed']);
    final saved = await openLivePagePhotos(context,
        name: '${u['name'] ?? ''}',
        searchText: [u['name'], u['area'], u['region'], u['country']]
            .where((x) => x != null && '$x'.trim().isNotEmpty)
            .join(' '),
        current: current);
    if (saved == null || !mounted) return;
    if (saved.isEmpty) {
      _snack('Add at least one photo.', bad: true);
      return;
    }
    // Saving an untouched list changes nothing, except on a card the
    // website refused, where it is a second try.
    if ('${u['status']}' != 'failed' &&
        saved.length == current.length &&
        [for (var i = 0; i < saved.length; i++) saved[i] == current[i]]
            .every((same) => same)) {
      _snack('Nothing changed.');
      return;
    }
    try {
      await _supabase.upgradePhotos('${u['venue_id']}', saved, seen: current);
      _snack('${u['name']}: on its way to the website.');
      await _load();
    } catch (e) {
      _snack(_plainError(e), bad: true);
      // A refusal usually means the card is out of date: show it fresh.
      await _load();
    }
  }

  Future<void> _edit(Map<String, dynamic> u) async {
    if ('${u['kind']}' == 'photos') {
      await _editPhotos(u);
    } else {
      await _editText(u);
    }
  }

  Future<void> _openPhotoGaps() async {
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => const _PhotoGapsPage()));
    if (!mounted) return;
    setState(() => _rows = null);
    await _load();
  }

  Future<void> _openPages() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const _PagesPage()));
    if (!mounted) return;
    setState(() => _rows = null);
    await _load();
  }

  Future<void> _openPage(Map<String, dynamic> u) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => _PageReviewPage(
                venueId: '${u['venue_id']}', name: '${u['name'] ?? ''}')));
    if (!mounted) return;
    await _load();
  }

  // --------------------------------------------------------------- help

  static const _help = <(IconData, String, String)>[
    (
      Icons.auto_fix_high_outlined,
      'What this is',
      'Improvements to the listing pages on nomadwise.io, taken one page '
          'at a time. You see what the page says now next to the upgrade, '
          'and nothing reaches the website until you press Go.'
    ),
    (
      Icons.list_alt,
      'Choose a page',
      'Lists every live page, the most promising first. Open one to see '
          'its three text parts: the page title, the search description '
          'and the page description. Each part has its own Go, so you can '
          'take the title and leave the rest.'
    ),
    (
      Icons.assignment_outlined,
      'Request upgrade',
      'Puts a page on the list to be drafted. The drafts are written '
          'outside the app, from what people search for on Google and from '
          'the space\'s own website, then uploaded. They come back to the '
          'page and to "Waiting for your Go", with a line saying what each '
          'one was based on. "Copy requests" gives the list to paste to '
          'Claude.'
    ),
    (
      Icons.edit_outlined,
      'Write my own',
      'On a page, any part can be written by hand. Saving sends it to the '
          'website, so it is the Go. "Build from the facts" makes a plain '
          'search description from what we hold about the place, for you '
          'to check first.'
    ),
    (
      Icons.sort,
      'The order',
      'The score comes from how many people viewed the page in the last '
          '90 days, how well known the place is on Google, whether it is '
          'a coworking space, and what the page already ranks for: a page '
          'sitting below the top spot for a search people make has the '
          'most to gain. The reason is on every row.'
    ),
    (
      Icons.photo_library_outlined,
      'Photos',
      '"Add photos" lists the pages with fewer than five. Open the place '
          'on Google, right-click a photo, choose "Copy image address" and '
          'paste it into a free slot. Saving sends them to the page.'
    ),
    (
      Icons.undo,
      'Undo',
      'On the Live tab, Undo puts back exactly what the page had before. '
          'On the "On its way" tab, Take back stops a change that has not '
          'reached the website yet.'
    ),
    (
      Icons.shield_outlined,
      'What it leaves alone',
      'A page with an owner keeps the description its owner wrote.\n'
          'Price lines already on a page stay under a new description.\n'
          'The layout of the page is not touched from here: that is one '
          'change in Webflow for every page, kept on its own list.'
    ),
    (
      Icons.insights_outlined,
      'Where the numbers come from',
      'What each page says is read from the website every night. Page '
          'views come from the site\'s analytics, and what a page ranks '
          'for comes from Ahrefs; both are refreshed when drafts are '
          'uploaded.'
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

  /// One of the two ways in: a title, the numbers, what it is, and a
  /// button.
  Widget _entry(
      {required String title,
      required String numbers,
      required String what,
      required Widget button}) {
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
                  Text(numbers,
                      style: const TextStyle(
                          fontSize: 13, color: Brand.inkSecondary)),
                ]),
          ),
          const SizedBox(width: 10),
          button,
        ]),
        const SizedBox(height: 6),
        Text(what,
            style: const TextStyle(
                fontSize: 12.5, height: 1.4, color: Brand.inkMuted)),
      ]),
    );
  }

  Widget _textEntry() {
    final t = _overview['text'];
    final m = t is Map ? t : const {};
    final requested = _int(m['requested']);
    final waiting = _int(m['waiting']);
    final ranked = _int(m['search_pages']);
    return _entry(
        title: 'Titles and text, one page at a time',
        numbers: [
          '${_num(_int(m['generic_meta']))} pages on the generic search '
              'description',
          '${_num(_int(m['no_desc_coworking']))} coworking pages with no '
              'description',
          if (ranked > 0) '${_num(ranked)} pages rank for a search on Google',
          if (requested > 0) '$requested requested',
          if (waiting > 0) '$waiting waiting for your Go',
        ].join(' · '),
        what: 'Pick a page and see what it says now next to the upgrade '
            'for its title, search description and page description. '
            'Each part has its own Go.',
        button: FilledButton.icon(
            onPressed: _openPages,
            icon: const Icon(Icons.list_alt, size: 18),
            label: const Text('Choose a page')));
  }

  Widget _photosEntry(Map<String, dynamic> k) {
    final gap = _int(k['gap']);
    final more = _int(k['gap_more']);
    final waiting = _int(k['waiting']);
    return _entry(
        title: '${k['title'] ?? 'Photos'}',
        numbers: '${_num(gap)} ${k['gap_words'] ?? 'pages'}'
            '${more > 0 ? ', and ${_num(more)} ${k['gap_more_words'] ?? 'more'}' : ''}'
            '${waiting > 0 ? ' · $waiting waiting for your Go' : ''}',
        what: '${k['what'] ?? ''}',
        button: OutlinedButton.icon(
            onPressed: gap > 0 || waiting > 0 ? _openPhotoGaps : null,
            icon: const Icon(Icons.photo_library_outlined, size: 18),
            label: const Text('Add photos')));
  }

  Widget _photoBox(String label, List<String> urls, {required bool proposed}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: proposed ? Brand.logoTealTint : Brand.field,
          borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${label.toUpperCase()} · ${urls.length} OF 5',
            style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.4,
                fontWeight: FontWeight.w800,
                color: proposed ? Brand.logoNavy : Brand.inkMuted)),
        const SizedBox(height: 6),
        _photoStrip(urls),
      ]),
    );
  }

  Widget _card(Map<String, dynamic> u) {
    final id = '${u['id']}';
    final kind = '${u['kind']}';
    final status = '${u['status']}';
    final name = '${u['name'] ?? ''}'.trim();
    final where = _whereOf(u);
    final slug = '${u['slug'] ?? ''}'.trim();
    // Null means it was not known when the upgrade was made, which is
    // not the same as the page having nothing there.
    final beforeKnown = u['before'] != null;
    final before = '${u['before'] ?? ''}'.trim();
    final proposed = '${u['final'] ?? u['proposed'] ?? ''}'.trim();
    final note = '${u['note'] ?? ''}'.trim();
    final error = '${u['error'] ?? ''}'.trim();
    final busy = _busy.contains(id);
    final isLine = kind == 'search_description' || kind == 'title';
    final isPhotos = kind == 'photos';
    final photosBefore = isPhotos ? _photoLinks(u['before']) : const <String>[];
    final photosAfter =
        isPhotos ? _photoLinks(u['final'] ?? u['proposed']) : const <String>[];
    final edited = u['final'] != null &&
        '${u['final']}'.trim() != '${u['proposed'] ?? ''}'.trim();
    final source = '${u['source']}';

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
              if (source == 'drafted') _chip('DRAFTED'),
              if (source == 'founder' && !isPhotos) _chip('YOUR WORDING'),
              if (source == 'rule') _chip('FROM THE FACTS'),
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
        if (isPhotos) ...[
          _photoBox(
              status == 'applied' || status == 'undo_requested'
                  ? 'Before this change'
                  : 'On the page now',
              photosBefore,
              proposed: false),
          _photoBox(
              status == 'applied' ? 'Live on the page' : 'Your photos',
              photosAfter,
              proposed: true),
        ] else
          _compare(
              _textBox(
                  status == 'applied' || status == 'undo_requested'
                      ? 'Before this change'
                      : 'Current',
                  !beforeKnown
                      ? 'Not recorded.'
                      : before.isEmpty
                          ? (kind == 'description'
                              ? 'No description on the page.'
                              : 'Nothing.')
                          : before,
                  proposed: false,
                  foot: isLine && before.isNotEmpty
                      ? '${before.length} characters'
                      : null),
              _textBox(
                  status == 'applied'
                      ? 'Live on the page'
                      : edited
                          ? 'Your wording'
                          : 'Upgraded',
                  proposed,
                  proposed: true,
                  foot: isLine ? '${proposed.length} characters' : null)),
        if (note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Based on: $note',
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
                const Text('The earlier version is being put back.',
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
              if (!isPhotos)
                TextButton.icon(
                    onPressed: () => _openPage(u),
                    icon: const Icon(Icons.article_outlined, size: 16),
                    label: const Text('The whole page')),
              if (slug.isNotEmpty)
                TextButton.icon(
                    onPressed: () => launchUrl(
                        Uri.parse('https://www.nomadwise.io/coworking/$slug')),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('See it live')),
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
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 40),
                      children: [
                        Row(children: [
                          const Expanded(
                            child: Text(
                                'Listing pages, improved one page at a '
                                'time. You see what a page says now next '
                                'to the upgrade, and nothing reaches the '
                                'website until you press Go.',
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
                        const Text('WHERE TO START',
                            style: TextStyle(
                                fontSize: 11,
                                letterSpacing: 0.5,
                                fontWeight: FontWeight.w800,
                                color: Brand.inkMuted)),
                        const SizedBox(height: 8),
                        _textEntry(),
                        if (kinds is List)
                          for (final k in kinds)
                            if (k is Map && k['paste'] == true)
                              _photosEntry(Map<String, dynamic>.from(k)),
                        const SizedBox(height: 12),
                        const Text('EVERY CHANGE, BY WHERE IT STANDS',
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
                                      'Nothing is waiting. Choose a page '
                                          'above and request an upgrade, or '
                                          'write one yourself.',
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
                        else
                          for (final u in rows) _card(u),
                      ]),
                ),
              ),
            ),
    );
  }
}

/// Every live page, the most promising first. A page can be put on
/// the list to be drafted ("Request upgrade") or opened to see what
/// it says now next to its upgrades.
class _PagesPage extends StatefulWidget {
  const _PagesPage();
  @override
  State<_PagesPage> createState() => _PagesPageState();
}

class _PagesPageState extends State<_PagesPage> {
  final _supabase = SupabaseService();
  final _search = TextEditingController();
  List<Map<String, dynamic>>? _rows;
  String _filter = '';
  String? _error;
  int _limit = 60;
  final Set<String> _busy = {};
  bool _copying = false;
  int _req = 0;

  static const _filters = <(String, String)>[
    ('', 'All pages'),
    ('search', 'Searched for on Google'),
    ('requested', 'Requested'),
    ('waiting', 'Waiting for your Go'),
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

  Future<void> _load() async {
    final n = ++_req;
    try {
      final rows = await _supabase.upgradesPages(
          query: _search.text.trim(), filter: _filter, limit: _limit);
      if (!mounted || n != _req) return;
      setState(() {
        _rows = rows;
        _error = null;
      });
    } catch (e) {
      if (mounted && n == _req) setState(() => _error = _plainError(e));
    }
  }

  void _snack(String text, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  Future<void> _request(Map<String, dynamic> r) async {
    final id = '${r['venue_id']}';
    if (_busy.contains(id)) return;
    final open = r['request'];
    final note = await _askRequestNote(context, '${r['name'] ?? 'this page'}',
        open is Map ? '${open['note'] ?? ''}' : '');
    if (note == null || !mounted) return;
    setState(() => _busy.add(id));
    try {
      await _supabase.upgradePageRequest(id, note: note.isEmpty ? null : note);
      _snack('${r['name']}: requested. Use "Copy requests" to pass the '
          'list on.');
      await _load();
    } catch (e) {
      _snack(_plainError(e), bad: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _withdraw(Map<String, dynamic> r) async {
    final id = '${r['venue_id']}';
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await _supabase.upgradePageRequestCancel(id);
      _snack('${r['name']}: request withdrawn.');
      await _load();
    } catch (e) {
      _snack(_plainError(e), bad: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _open(Map<String, dynamic> r) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => _PageReviewPage(
                venueId: '${r['venue_id']}', name: '${r['name'] ?? ''}')));
    if (!mounted) return;
    await _load();
  }

  /// The requested pages as a list to paste into a chat: name, page
  /// address and note, one page per line.
  Future<void> _copyRequests() async {
    if (_copying) return;
    setState(() => _copying = true);
    try {
      final rows =
          await _supabase.upgradesPages(filter: 'requested', limit: 300);
      if (rows.isEmpty) {
        _snack('No page has been requested yet.');
        return;
      }
      final lines = <String>['Page upgrade requests (${rows.length}):'];
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        final open = r['request'];
        final note = open is Map ? '${open['note'] ?? ''}'.trim() : '';
        lines.add('${i + 1}. ${r['name']} | '
            'https://www.nomadwise.io/coworking/${r['slug']}'
            '${note.isEmpty ? '' : ' | $note'}');
      }
      final text = lines.join('\n');
      var copied = true;
      try {
        await Clipboard.setData(ClipboardData(text: text));
      } catch (_) {
        // A browser may refuse the clipboard after a wait: show the
        // list to copy by hand instead.
        copied = false;
      }
      if (!mounted) return;
      if (copied) {
        _snack('${rows.length} copied. Paste the list to Claude to have '
            'them drafted.');
      } else {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Requested pages'),
            content: SizedBox(
              width: 620,
              child: SingleChildScrollView(child: SelectableText(text)),
            ),
            actions: [
              FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Done')),
            ],
          ),
        );
      }
    } catch (e) {
      _snack(_plainError(e), bad: true);
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  Widget _card(Map<String, dynamic> r) {
    final id = '${r['venue_id']}';
    final name = '${r['name'] ?? ''}'.trim();
    final where = _whereOf(r);
    final slug = '${r['slug'] ?? ''}'.trim();
    final busy = _busy.contains(id);
    final open = r['request'];
    final requested = open is Map;
    final note = requested ? '${open['note'] ?? ''}'.trim() : '';
    final waiting = _int(r['waiting']);
    final onWay = _int(r['on_way']);
    final live = _int(r['live']);
    final failed = _int(r['failed']);
    final words = _int(r['desc_words']);
    final title = '${r['title'] ?? ''}'.trim();
    final photos = r['photos'] is num ? (r['photos'] as num).toInt() : null;

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
              if (waiting > 0)
                _chip('$waiting WAITING FOR YOUR GO',
                    bg: Brand.logoTealTint, fg: Brand.logoNavy),
              if (requested)
                _chip('REQUESTED', bg: Brand.goldTint, fg: Brand.goldTextDark),
              if (failed > 0)
                _chip('$failed NEED A LOOK', bg: Brand.accentTint, fg: Brand.red),
              if (onWay > 0) _chip('$onWay ON THE WAY'),
              if (live > 0) _chip('$live LIVE'),
              if (r['owned'] == true)
                _chip('HAS AN OWNER',
                    bg: Brand.goldTint, fg: Brand.goldTextDark),
            ]),
        const SizedBox(height: 3),
        Text(
            [
              if (where.isNotEmpty) where,
              '${r['reason'] ?? ''}',
            ].where((x) => x.isNotEmpty).join(' · '),
            style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        const SizedBox(height: 6),
        Text(
            [
              if (title.isNotEmpty) 'Title: "$title"',
              r['meta_generic'] == true
                  ? 'Search description: the generic line'
                  : 'Search description: its own',
              words == 0
                  ? 'Description: none'
                  : 'Description: $words words',
              if (photos != null) 'Photos: $photos of 5',
            ].join('  ·  '),
            style: const TextStyle(
                fontSize: 12.5, height: 1.4, color: Brand.inkMuted)),
        if (requested)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                'Requested on ${_when(open['created_at'])}. Waiting to be '
                'drafted.${note.isEmpty ? '' : ' "$note"'}',
                style: const TextStyle(
                    fontSize: 12.5, height: 1.4, color: Brand.goldTextDark)),
          ),
        const SizedBox(height: 8),
        Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                  onPressed: () => _open(r),
                  icon: const Icon(Icons.article_outlined, size: 18),
                  label: Text(waiting > 0 ? 'Review' : 'Open')),
              if (!requested)
                OutlinedButton(
                    onPressed: busy ? null : () => _request(r),
                    child: const Text('Request upgrade'))
              else ...[
                TextButton(
                    onPressed: busy ? null : () => _request(r),
                    child: const Text('Change the note')),
                TextButton(
                    onPressed: busy ? null : () => _withdraw(r),
                    child: const Text('Withdraw')),
              ],
              if (slug.isNotEmpty)
                TextButton.icon(
                    onPressed: () => launchUrl(
                        Uri.parse('https://www.nomadwise.io/coworking/$slug')),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('See it live')),
            ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: const Text('Choose a page')),
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
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 40),
                      children: [
                        Row(children: [
                          const Expanded(
                            child: Text(
                                'Every live page, the most promising first. '
                                'Open a page to see what it says now and to '
                                'change it, or request an upgrade to have '
                                'it drafted for you.',
                                style: TextStyle(
                                    fontSize: 13,
                                    height: 1.45,
                                    color: Brand.inkSecondary)),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                              onPressed: _copying ? null : _copyRequests,
                              icon: const Icon(Icons.copy, size: 16),
                              label: const Text('Copy requests')),
                        ]),
                        const SizedBox(height: 10),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final f in _filters)
                            ChoiceChip(
                              label: Text(f.$2),
                              showCheckmark: false,
                              selectedColor: Brand.ink,
                              labelStyle: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: _filter == f.$1
                                      ? Colors.white
                                      : Brand.ink),
                              selected: _filter == f.$1,
                              onSelected: (_) {
                                setState(() {
                                  _filter = f.$1;
                                  _limit = 60;
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
                            hintText:
                                'Search by space, area, city or country, '
                                'then press Enter',
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
                                  switch (_filter) {
                                    'requested' =>
                                      'No page has been requested yet.',
                                    'waiting' =>
                                      'No drafts are waiting for your Go.',
                                    'search' =>
                                      'No page is known to rank for a '
                                          'search yet.',
                                    _ => 'No page matches that.',
                                  },
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: Brand.inkSecondary)),
                            ),
                          )
                        else ...[
                          for (final r in rows) _card(r),
                          if (rows.length >= _limit && _limit < 300)
                            Center(
                              child: TextButton(
                                  onPressed: () {
                                    setState(() => _limit =
                                        _limit + 60 > 300 ? 300 : _limit + 60);
                                    _load();
                                  },
                                  child: const Text('Show more')),
                            ),
                        ],
                      ]),
                ),
              ),
            ),
    );
  }
}

/// One page: what its title, search description and page description
/// say now, next to the upgrade for each, with a Go for each part.
class _PageReviewPage extends StatefulWidget {
  const _PageReviewPage({required this.venueId, required this.name});
  final String venueId;
  final String name;
  @override
  State<_PageReviewPage> createState() => _PageReviewPageState();
}

class _PageReviewPageState extends State<_PageReviewPage>
    with _UpgradeActions<_PageReviewPage> {
  Map<String, dynamic>? _page;
  String? _error;
  bool _working = false;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Future<void> _load() async {
    final n = ++_req;
    try {
      final page = await _supabase.upgradePage(widget.venueId);
      if (!mounted || n != _req) return;
      setState(() {
        _page = page;
        _error = null;
      });
    } catch (e) {
      if (mounted && n == _req) setState(() => _error = _plainError(e));
    }
  }

  String get _name {
    final n = '${_page?['name'] ?? widget.name}'.trim();
    return n.isEmpty ? 'this page' : n;
  }

  Future<void> _request() async {
    if (_working) return;
    final open = _page?['request'];
    final note = await _askRequestNote(
        context, _name, open is Map ? '${open['note'] ?? ''}' : '');
    if (note == null || !mounted) return;
    setState(() => _working = true);
    try {
      await _supabase.upgradePageRequest(widget.venueId,
          note: note.isEmpty ? null : note);
      _snack('Requested. "Copy requests" on the list of pages gives the '
          'list to pass on.');
      await _load();
    } catch (e) {
      _snack(_plainError(e), bad: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _withdraw() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await _supabase.upgradePageRequestCancel(widget.venueId);
      _snack('Request withdrawn.');
      await _load();
    } catch (e) {
      _snack(_plainError(e), bad: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// The plain search description, built from the facts we hold, as a
  /// proposal on this page.
  Future<void> _buildFromFacts() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await _supabase.upgradePrepareOne(widget.venueId);
      _snack('Built. Check it, then Go, Edit or Skip.');
      await _load();
    } catch (e) {
      _snack(_plainError(e), bad: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// A part written by hand. Saving sends it to the website.
  Future<void> _write(String kind, String start) async {
    if (_working) return;
    final text = await _askText(
        kind: kind,
        name: _name,
        start: start,
        action: 'Save and send to the page');
    if (text == null || !mounted) return;
    setState(() => _working = true);
    try {
      await _supabase.upgradeWrite(widget.venueId, kind, text);
      _snack('$_name: on its way to the website.');
      await _load();
    } catch (e) {
      _snack(_plainError(e), bad: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _part(Map<String, dynamic> p, {required bool owned}) {
    final kind = '${p['kind']}';
    final isLine = kind != 'description';
    final rawUp = p['upgrade'];
    final up = rawUp is Map ? Map<String, dynamic>.from(rawUp) : null;
    final status = up == null ? '' : '${up['status']}';
    final hasOpen = up != null && status != 'skipped' && status != 'undone';
    final current = p['current'] == null ? null : '${p['current']}'.trim();
    final beforeKnown = up != null && up['before'] != null;
    final before = up == null ? '' : '${up['before'] ?? ''}'.trim();
    final proposed =
        up == null ? '' : '${up['final'] ?? up['proposed'] ?? ''}'.trim();
    final note = up == null ? '' : '${up['note'] ?? ''}'.trim();
    final error = up == null ? '' : '${up['error'] ?? ''}'.trim();
    final source = up == null ? '' : '${up['source']}';
    final edited = up != null &&
        up['final'] != null &&
        '${up['final']}'.trim() != '${up['proposed'] ?? ''}'.trim();
    final busy = _working || (up != null && _busy.contains('${up['id']}'));
    final empty = switch (kind) {
      'title' => 'No title.',
      'description' => 'No description on the page.',
      _ => 'Nothing.',
    };
    final afterChange = status == 'applied' || status == 'undo_requested';
    final leftText = afterChange
        ? (!beforeKnown
            ? 'Not recorded.'
            : before.isEmpty
                ? empty
                : before)
        : current == null
            ? 'Not read from the website yet. Pages are read every night.'
            : (current.isEmpty ? empty : current);
    final leftCounted = afterChange ? before : (current ?? '');
    // The owner writes the description of a page that has one.
    final ownersPart = owned && kind == 'description';
    // What a hand-written version starts from: the upgrade when there
    // is one, otherwise what the page says now.
    final startText = proposed.isNotEmpty ? proposed : (current ?? '');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
              Text(_kindLabel(kind),
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15)),
              if (hasOpen && source == 'drafted') _chip('DRAFTED'),
              if (hasOpen && source == 'founder') _chip('YOUR WORDING'),
              if (hasOpen && source == 'rule') _chip('FROM THE FACTS'),
              if (ownersPart)
                _chip('THE OWNER WRITES THIS',
                    bg: Brand.goldTint, fg: Brand.goldTextDark),
            ]),
        const SizedBox(height: 2),
        Text(_kindWhat(kind),
            style: const TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
        _compare(
            _textBox(afterChange ? 'Before this change' : 'Current', leftText,
                proposed: false,
                foot: isLine && leftCounted.isNotEmpty
                    ? '${leftCounted.length} characters'
                    : null),
            hasOpen
                ? _textBox(
                    status == 'applied'
                        ? 'Live on the page'
                        : edited
                            ? 'Your wording'
                            : 'Upgraded',
                    proposed,
                    proposed: true,
                    foot: isLine ? '${proposed.length} characters' : null)
                : _textBox(
                    'Upgraded',
                    ownersPart
                        ? 'The owner writes this in the Owner account.'
                        : status == 'skipped'
                            ? 'The last upgrade was skipped.'
                            : status == 'undone'
                                ? 'The last upgrade was undone.'
                                : 'Nothing yet. Request an upgrade above, '
                                    'or write one yourself.',
                    proposed: false)),
        if (hasOpen && note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Based on: $note',
                style: const TextStyle(
                    fontSize: 12.5, height: 1.4, color: Brand.inkSecondary)),
          ),
        if (hasOpen && error.isNotEmpty)
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
              if (up != null && (status == 'proposed' || status == 'failed')) ...[
                FilledButton.icon(
                    onPressed: busy ? null : () => _go(up),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: Text(status == 'failed' ? 'Try again' : 'Go')),
                OutlinedButton(
                    onPressed: busy ? null : () => _editText(up),
                    child: const Text('Edit')),
                TextButton(
                    onPressed: busy ? null : () => _skip(up),
                    child: const Text('Skip')),
              ],
              if (up != null && status == 'approved') ...[
                const Text('On its way to the website.',
                    style: TextStyle(fontSize: 13, color: Brand.inkSecondary)),
                TextButton(
                    onPressed: busy ? null : () => _undo(up),
                    child: const Text('Take back')),
              ],
              if (status == 'undo_requested')
                const Text('The earlier version is being put back.',
                    style: TextStyle(fontSize: 13, color: Brand.inkSecondary)),
              if (up != null && status == 'applied') ...[
                Text('Live since ${_when(up['applied_at'])}.',
                    style: const TextStyle(
                        fontSize: 13, color: Brand.success)),
                TextButton(
                    onPressed: busy ? null : () => _undo(up),
                    child: const Text('Undo')),
              ],
              if (up != null && (status == 'skipped' || status == 'undone'))
                TextButton(
                    onPressed: busy ? null : () => _undo(up),
                    child: const Text('Bring it back')),
              if (!ownersPart &&
                  (up == null ||
                      status == 'applied' ||
                      status == 'skipped' ||
                      status == 'undone'))
                OutlinedButton.icon(
                    onPressed: busy ? null : () => _write(kind, startText),
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: Text(
                        status == 'applied' ? 'Write a new one' : 'Write my own')),
              if (kind == 'search_description' &&
                  (up == null ||
                      status == 'applied' ||
                      status == 'skipped' ||
                      status == 'undone'))
                TextButton.icon(
                    onPressed: busy ? null : _buildFromFacts,
                    icon: const Icon(Icons.build_outlined, size: 16),
                    label: const Text('Build from the facts')),
            ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    final slug = '${page?['slug'] ?? ''}'.trim();
    final where = page == null ? '' : _whereOf(page);
    final open = page?['request'];
    final requested = open is Map;
    final reqNote = requested ? '${open['note'] ?? ''}'.trim() : '';
    final owned = page?['owned'] == true;
    final searches = page?['searches'];
    final parts = page?['parts'];
    final photos = page?['photos'];

    return Scaffold(
      appBar: AppBar(title: Text(_name)),
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
          : page == null
              ? const Center(
                  child: CircularProgressIndicator(color: Brand.red))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000),
                      child: ListView(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 40),
                          children: [
                            Text(
                                [
                                  if (where.isNotEmpty) where,
                                  '${page['reason'] ?? ''}',
                                ].where((x) => x.isNotEmpty).join(' · '),
                                style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.45,
                                    color: Brand.inkSecondary)),
                            if (searches is List && searches.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                    color: Brand.logoTealTint,
                                    borderRadius: BorderRadius.circular(10)),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                          'WHAT PEOPLE SEARCH ON GOOGLE TO '
                                          'FIND THIS PAGE',
                                          style: TextStyle(
                                              fontSize: 10.5,
                                              letterSpacing: 0.4,
                                              fontWeight: FontWeight.w800,
                                              color: Brand.logoNavy)),
                                      const SizedBox(height: 4),
                                      for (final s in searches)
                                        if (s is Map)
                                          Text(
                                              '"${s['keyword']}": position '
                                              '${s['position'] ?? '?'}, about '
                                              '${_num(_int(s['volume']))} '
                                              'searches a month'
                                              '${'${s['country'] ?? ''}'.isEmpty ? '' : ' (${s['country']})'}',
                                              style: const TextStyle(
                                                  fontSize: 13, height: 1.5)),
                                    ]),
                              ),
                            ],
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                              decoration: BoxDecoration(
                                  color: requested
                                      ? Brand.goldTint
                                      : Brand.field,
                                  borderRadius: BorderRadius.circular(10)),
                              child: Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  crossAxisAlignment:
                                      WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                        requested
                                            ? 'Upgrade requested on '
                                                '${_when(open['created_at'])}. '
                                                'Waiting to be drafted.'
                                                '${reqNote.isEmpty ? '' : ' "$reqNote"'}'
                                            : 'Want this page drafted for '
                                                'you, from what people '
                                                'search for?',
                                        style: TextStyle(
                                            fontSize: 13,
                                            height: 1.4,
                                            color: requested
                                                ? Brand.goldTextDark
                                                : Brand.inkSecondary)),
                                    if (!requested)
                                      OutlinedButton(
                                          onPressed:
                                              _working ? null : _request,
                                          child:
                                              const Text('Request upgrade'))
                                    else ...[
                                      TextButton(
                                          onPressed:
                                              _working ? null : _request,
                                          child:
                                              const Text('Change the note')),
                                      TextButton(
                                          onPressed:
                                              _working ? null : _withdraw,
                                          child: const Text('Withdraw')),
                                    ],
                                    if (slug.isNotEmpty)
                                      TextButton.icon(
                                          onPressed: () => launchUrl(Uri.parse(
                                              'https://www.nomadwise.io/coworking/$slug')),
                                          icon: const Icon(Icons.open_in_new,
                                              size: 16),
                                          label: const Text('See it live')),
                                  ]),
                            ),
                            const SizedBox(height: 12),
                            if (parts is List)
                              for (final p in parts)
                                if (p is Map)
                                  _part(Map<String, dynamic>.from(p),
                                      owned: owned),
                            if (photos is num)
                              Text(
                                  'Photos: ${photos.toInt()} of 5. They are '
                                  'added from "Add photos" on the Page '
                                  'upgrades screen.',
                                  style: const TextStyle(
                                      fontSize: 12.5,
                                      color: Brand.inkMuted)),
                          ]),
                    ),
                  ),
                ),
    );
  }
}

/// The pages with fewer than five photos, highest impact first. Each
/// opens the same photo page a new listing uses: its photos sit in the
/// slots, and image addresses copied from Google go into the free
/// ones. Saving sends the list to the page (it is the Go).
class _PhotoGapsPage extends StatefulWidget {
  const _PhotoGapsPage();
  @override
  State<_PhotoGapsPage> createState() => _PhotoGapsPageState();
}

class _PhotoGapsPageState extends State<_PhotoGapsPage> {
  final _supabase = SupabaseService();
  final _search = TextEditingController();
  List<Map<String, dynamic>>? _rows;
  String? _error;
  int _limit = 60;
  final Set<String> _busy = {};
  int _req = 0;

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

  Future<void> _load() async {
    final n = ++_req;
    try {
      final rows = await _supabase.upgradesPhotoGaps(
          query: _search.text.trim(), limit: _limit);
      if (!mounted || n != _req) return;
      setState(() {
        _rows = rows;
        _error = null;
      });
    } catch (e) {
      if (mounted && n == _req) setState(() => _error = _plainError(e));
    }
  }

  void _snack(String text, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  Future<void> _add(Map<String, dynamic> r) async {
    final id = '${r['venue_id']}';
    if (_busy.contains(id)) return;
    // A change still on its way holds the newer list: start from it.
    final current = _photoLinks(r['pending_urls'] ?? r['urls']);
    final saved = await openLivePagePhotos(context,
        name: '${r['name'] ?? ''}',
        searchText: [r['name'], r['area'], r['region'], r['country']]
            .where((x) => x != null && '$x'.trim().isNotEmpty)
            .join(' '),
        placeId: r['place_id'] == null ? null : '${r['place_id']}',
        current: current);
    if (saved == null || !mounted) return;
    if (saved.isEmpty) {
      _snack('Add at least one photo.', bad: true);
      return;
    }
    if (saved.length == current.length &&
        [for (var i = 0; i < saved.length; i++) saved[i] == current[i]]
            .every((same) => same)) {
      _snack('Nothing changed.');
      return;
    }
    setState(() => _busy.add(id));
    try {
      await _supabase.upgradePhotos(id, saved, seen: current);
      _snack('${r['name']}: ${saved.length} of 5, on its way to the website.');
      await _load();
    } catch (e) {
      _snack(_plainError(e), bad: true);
      // A refusal usually means the list is out of date: load it fresh.
      await _load();
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Widget _card(Map<String, dynamic> r) {
    final id = '${r['venue_id']}';
    final name = '${r['name'] ?? ''}'.trim();
    final area = '${r['area'] ?? ''}'.trim();
    final region = '${r['region'] ?? ''}'.trim();
    final country = '${r['country'] ?? ''}'.trim();
    final where = <String>[
      if (area.isNotEmpty) area,
      if (region.isNotEmpty && region.toLowerCase() != area.toLowerCase())
        region,
      if (country.isNotEmpty && country.toLowerCase() != region.toLowerCase())
        country,
    ].join(', ');
    final urls = _photoLinks(r['urls']);
    final n = r['photos'] is num ? (r['photos'] as num).toInt() : urls.length;
    final pending = '${r['pending'] ?? ''}';
    final slug = '${r['slug'] ?? ''}'.trim();
    final busy = _busy.contains(id);

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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: n <= 1 ? Brand.accentTint : Brand.goldTint,
                    borderRadius: BorderRadius.circular(20)),
                child: Text('$n OF 5 PHOTOS',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: n <= 1 ? Brand.red : Brand.goldTextDark)),
              ),
            ]),
        const SizedBox(height: 3),
        Text(
            [
              if (where.isNotEmpty) where,
              '${r['reason'] ?? ''}',
            ].where((x) => x.isNotEmpty).join(' · '),
            style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        const SizedBox(height: 8),
        _photoStrip(urls),
        const SizedBox(height: 8),
        Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                  onPressed: busy || pending == 'undo_requested'
                      ? null
                      : () => _add(r),
                  icon: const Icon(Icons.add_photo_alternate_outlined,
                      size: 18),
                  label: Text(pending.isEmpty ? 'Add photos' : 'Change')),
              if (pending == 'approved')
                const Text('A change is on its way to the website.',
                    style: TextStyle(fontSize: 13, color: Brand.inkSecondary)),
              if (pending == 'failed')
                const Text('The last change did not go through.',
                    style: TextStyle(fontSize: 13, color: Brand.red)),
              if (pending == 'undo_requested')
                const Text('The earlier photos are being put back.',
                    style: TextStyle(fontSize: 13, color: Brand.inkSecondary)),
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
    return Scaffold(
      appBar: AppBar(title: const Text('Pages short of photos')),
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
                        const Text(
                            'Pages with fewer than five photos, the most '
                            'visited first. Press Add photos, open the place '
                            'on Google, copy the image address of a photo and '
                            'paste it into a free slot. Saving sends the '
                            'photos to the page within minutes.',
                            style: TextStyle(
                                fontSize: 13,
                                height: 1.45,
                                color: Brand.inkSecondary)),
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
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(
                              child: Text(
                                  'No page is short of photos here. If the '
                                  'screen was only just set up, the counts '
                                  'arrive with tonight\'s sync.',
                                  textAlign: TextAlign.center,
                                  style:
                                      TextStyle(color: Brand.inkSecondary)),
                            ),
                          )
                        else ...[
                          for (final r in rows) _card(r),
                          if (rows.length >= _limit && _limit < 300)
                            Center(
                              child: OutlinedButton(
                                  onPressed: () {
                                    setState(() => _limit =
                                        _limit + 60 > 300 ? 300 : _limit + 60);
                                    _load();
                                  },
                                  child: const Text('Show more')),
                            ),
                        ],
                      ]),
                ),
              ),
            ),
    );
  }
}
