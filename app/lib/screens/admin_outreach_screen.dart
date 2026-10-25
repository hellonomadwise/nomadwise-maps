import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/clipboard_stub.dart'
    if (dart.library.html) '../services/clipboard_web.dart' as rich;
import '../services/places_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/email_typo_hint.dart';

/// Outreach (migration 121): every cafe, coworking or coliving space
/// we are talking to, in one list. Who they are, what they wrote,
/// which stage they are at, and a Reply button that fills one of our
/// templates with their details, sends it from hello@nomadwise.io and
/// logs it. Founders only.
class AdminOutreachScreen extends StatefulWidget {
  const AdminOutreachScreen({super.key, this.initialStep, this.initialQuery});

  /// Opens on one step of the path (from "Next up": the spaces that
  /// looked at claiming).
  final String? initialStep;

  /// Opens on the whole picture, searched for this (a space's name,
  /// from the control centre's search: "Write to them").
  final String? initialQuery;
  @override
  State<AdminOutreachScreen> createState() => _AdminOutreachScreenState();
}

class _AdminOutreachScreenState extends State<AdminOutreachScreen> {
  final _supabase = SupabaseService();
  // One for the screen, so a phone number looked up on Google is kept
  // and not paid for again on the next press.
  final _places = PlacesService();
  final _search = TextEditingController();
  List<Map<String, dynamic>>? _rows;

  /// Per space, the customers we sent it (enquiries passed on, or sent
  /// straight to a Verified space) and how many booked, by venue id
  /// (migration 193): the best opening for a hello.
  Map<String, Map<String, dynamic>> _customers = const {};
  // Business checks on email addresses (migration 222), by line.
  Map<String, Map<String, dynamic>> _business = const {};
  Map<String, int> _counts = {};
  List<Map<String, dynamic>> _templates = [];
  String _stage = 'new';
  // '' all, 'wrote' they wrote to us, 'listed' on the site and
  // unclaimed, 'prospect' spaces we found.
  String _group = '';
  String? _error;
  final Set<String> _expanded = {};

  // The path (migration 148): its numbers, the step whose spaces the
  // list is showing (null: the chips decide), and whether it is open.
  Map<String, dynamic>? _path;
  String? _step;
  bool _pathOpen = true;
  // The numbers were asked for at least once (so an empty card can
  // say they did not come, and not just be missing).
  bool _numbersAsked = false;

  // The whole picture (migration 153): every place counted once.
  Map<String, dynamic>? _whole;
  bool _wholeOpen = true;

  // The pages we approved, from live to signed in (migration 178).
  List<Map<String, dynamic>>? _newPages;

  // Which card is showing above the list: the new pages (migration
  // 178), the signs of interest (migration 154), the path, or the
  // whole picture.
  String _view = 'new';

  static const _stages = <(String, String)>[
    ('new', 'New'),
    ('contacted', 'Contacted'),
    ('replied', 'Replied'),
    ('claimed', 'Claimed'),
    ('verified', 'Plus'),
    ('not_now', 'Not now'),
    ('declined', 'Declined'),
    ('unsubscribed', 'Unsubscribed'),
    ('', 'All'),
  ];

  // Spaces 2.0, step 1 (Jonathan, 25 Oct 2026): the stages worked
  // through every day stay in view; the ones that are rarely needed
  // (stepped off, set up by us, tests, not for outreach) sit behind
  // "More". Nothing is hidden from the lists themselves.
  static const _mainStages = {'new', 'contacted', 'replied', 'claimed', 'verified', ''};
  bool _moreOpen = false;

  static const _groups = <(String, String, String)>[
    ('', 'Everyone', ''),
    ('wrote', 'Wrote to us', '_wrote'),
    ('listed', 'Listed, unclaimed', '_listed'),
    ('prospect', 'Prospects', '_prospect'),
  ];

  static const _kinds = ['coworking', 'cafe', 'coliving', 'hotel', 'restaurant', 'other'];

  @override
  void initState() {
    super.initState();
    _step = widget.initialStep;
    final q = (widget.initialQuery ?? '').trim();
    if (q.isNotEmpty) {
      _search.text = q;
      _view = 'whole';
      _stage = ''; // All stages, so a space already written to shows
    }
    if (q.isEmpty && _step == null) {
      _loadRemembered();
    } else {
      _load();
    }
    _supabase.outreachTemplates().then((t) {
      if (mounted) setState(() => _templates = t);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // Counts the loads, so a slow earlier answer never overwrites the
  // tab picked after it.
  int _req = 0;

  // The group and stage last chosen, kept on this device, so Outreach
  // opens where it was left.
  static const _keyGroup = 'outreach_group';
  static const _keyStage = 'outreach_stage';

  Future<void> _loadRemembered() async {
    try {
      final p = await SharedPreferences.getInstance();
      final g = p.getString(_keyGroup);
      final st = p.getString(_keyStage);
      if (mounted) {
        setState(() {
          if (g != null && _groups.any((x) => x.$1 == g)) _group = g;
          if (st != null &&
              (_stages.any((x) => x.$1 == st) ||
                  const {'ours', 'tests', 'aside'}.contains(st))) {
            _stage = st;
            if (!_mainStages.contains(st)) _moreOpen = true;
          }
        });
      }
    } catch (_) {
      // Nothing remembered: the usual start.
    }
    if (mounted) _load();
  }

  void _remember() {
    if (_step != null || _search.text.trim().isNotEmpty) return;
    final g = _group;
    final st = _stage;
    SharedPreferences.getInstance().then((p) {
      p.setString(_keyGroup, g);
      p.setString(_keyStage, st);
    }).catchError((_) {});
  }

  Future<void> _load() async {
    final n = ++_req;
    _remember();
    // Started first and read last: it never throws, and the list does
    // not wait for it.
    final pathF = _supabase.outreachPath();
    final wholeF = _supabase.outreachWhole();
    final newF = _supabase.outreachNewPages();
    final customersF = _supabase.venueCustomers();
    final businessF = _supabase.outreachBusinessChecks();
    try {
      final rows = await _supabase.outreachList(
          stage: _stage,
          query: _search.text.trim(),
          group: _group,
          step: _step);
      final counts = await _supabase.outreachCounts(group: _group);
      final path = await pathF;
      final whole = await wholeF;
      final fresh = await newF;
      final customers = await customersF;
      final business = await businessF;
      if (!mounted || n != _req) return;
      setState(() {
        _rows = rows;
        _customers = customers;
        _business = business;
        _counts = counts;
        if (path != null) _path = path;
        if (whole != null) _whole = whole;
        if (fresh != null) _newPages = fresh;
        _numbersAsked = true;
        _error = null;
      });
    } catch (e) {
      // An earlier request that failed says nothing about this one.
      if (mounted && n == _req) setState(() => _error = '$e');
    }
  }

  void _snack(String text, {bool bad = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  /// The database's own words for a refused action, whole (they can
  /// hold commas and braces, such as a placeholder's name).
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

  static String _stageLabel(String s) =>
      _stages.firstWhere((x) => x.$1 == s, orElse: () => (s, s)).$2;

  // ------------------------------------------------------------ actions

  /// Moves a contact to another stage. The message that confirms it
  /// carries an Undo for a few seconds, which puts the contact back
  /// where it was (a slip of the finger on "They replied", say).
  Future<void> _setStage(Map<String, dynamic> c, String stage,
      {bool undoable = true}) async {
    final was = '${c['stage'] ?? ''}';
    final who = '${c['space_name'] ?? c['email']}';
    try {
      await _supabase.outreachUpdate('${c['id']}', {'stage': stage});
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            // An Undo button would otherwise keep it up until closed.
            duration: const Duration(seconds: 20),
            persist: false,
            content: Text('$who: ${_stageLabel(stage)}.'),
            action: undoable && was.isNotEmpty && was != stage
                ? SnackBarAction(
                    label: 'Undo',
                    onPressed: () => _setStage(
                        {...c, 'stage': stage}, was,
                        undoable: false))
                : null));
      await _load();
    } catch (e) {
      if (mounted) _snack(_plain(e), bad: true);
    }
  }

  Future<void> _editNote(Map<String, dynamic> c) async {
    final note = TextEditingController(text: '${c['notes'] ?? ''}');
    final follow = TextEditingController(text: '${c['follow_up_on'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Note on ${c['space_name'] ?? c['email'] ?? 'this contact'}'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: note,
                maxLines: 5,
                decoration: const InputDecoration(
                    labelText: 'Notes', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(
                controller: follow,
                decoration: const InputDecoration(
                    labelText: 'Follow up on (YYYY-MM-DD, or blank)',
                    border: OutlineInputBorder())),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _supabase.outreachUpdate('${c['id']}', {
        'notes': note.text,
        'follow_up_on': follow.text.trim(),
      });
      await _load();
    } catch (e) {
      _snack(_plain(e), bad: true);
    }
  }

  Future<void> _logReply(Map<String, dynamic> c) async {
    final text = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('What they wrote'),
        content: SizedBox(
          width: 520,
          child: TextField(
              controller: text,
              maxLines: 8,
              autofocus: true,
              decoration: const InputDecoration(
                  hintText: 'Paste their reply from the inbox',
                  border: OutlineInputBorder())),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Keep it')),
        ],
      ),
    );
    if (ok != true || text.text.trim().isEmpty) return;
    try {
      await _supabase.outreachLogIn('${c['id']}', text.text);
      await _load();
    } catch (e) {
      _snack(_plain(e), bad: true);
    }
  }

  /// A field of the contact form: compact, with a small icon, the
  /// label above the words once there are any.
  static InputDecoration _formDecoration(String label, IconData? icon) {
    OutlineInputBorder edge(Color color, [double width = 1]) =>
        OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: color, width: width));
    return InputDecoration(
      labelText: label,
      isDense: true,
      filled: true,
      fillColor: Brand.surface,
      prefixIcon:
          icon == null ? null : Icon(icon, size: 18, color: Brand.inkMuted),
      prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      contentPadding: EdgeInsets.fromLTRB(icon == null ? 14 : 0, 13, 12, 13),
      labelStyle: const TextStyle(fontSize: 14, color: Brand.inkSecondary),
      floatingLabelStyle: const TextStyle(
          fontSize: 13, fontWeight: FontWeight.w600, color: Brand.ink),
      alignLabelWithHint: true,
      border: edge(Brand.border),
      enabledBorder: edge(Brand.border),
      focusedBorder: edge(Brand.ink, 1.4),
    );
  }

  /// Add or edit a contact. [c] null means a new one.
  Future<void> _editContact(Map<String, dynamic>? c) async {
    String v(String k) => '${c?[k] ?? ''}';
    final space = TextEditingController(text: v('space_name'));
    final person = TextEditingController(text: v('person_name'));
    final email = TextEditingController(text: v('email'));
    final phone = TextEditingController(text: v('phone'));
    final city = TextEditingController(text: v('city'));
    final country = TextEditingController(text: v('country'));
    final website = TextEditingController(text: v('website'));
    final instagram = TextEditingController(text: v('instagram'));
    final message = TextEditingController();
    final notes = TextEditingController(text: v('notes'));
    String kind = _kinds.contains(v('kind')) ? v('kind') : 'coworking';
    String source = 'manual';

    // Jonathan, 21 Oct 2026, on a phone: the form was "big in terms of
    // text", with words cut off in half-width boxes. On a phone it is a
    // full page, one field to a line, in three short sections, with
    // Save at the top; on a laptop a dialog with two fields to a line.
    // The kind (and, for a new contact, how we know them) are pills
    // rather than drop-down menus.
    Widget field(TextEditingController t, String label,
            {IconData? icon, int lines = 1, TextInputType? type}) =>
        TextField(
          controller: t,
          minLines: lines > 1 ? 2 : 1,
          maxLines: lines,
          keyboardType: lines > 1 ? TextInputType.multiline : type,
          style: const TextStyle(fontSize: 15, color: Brand.ink),
          decoration: _formDecoration(label, icon),
        );

    Widget heading(String text, {bool first = false}) => Padding(
          padding: EdgeInsets.fromLTRB(2, first ? 2 : 18, 2, 8),
          child: Text(text,
              style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .8,
                  color: Brand.inkMuted)),
        );

    const gap = SizedBox(height: 10, width: 10);
    Widget pair(bool narrow, Widget a, Widget b) => narrow
        ? Column(children: [a, gap, b])
        : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: a),
            gap,
            Expanded(child: b),
          ]);

    String capital(String k) =>
        k.isEmpty ? k : k[0].toUpperCase() + k.substring(1);

    List<Widget> form(bool narrow, StateSetter setD) => [
          heading('THE SPACE', first: true),
          field(space, 'Space name', icon: Icons.storefront_outlined),
          gap,
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final k in _kinds)
              _pill(capital(k),
                  on: kind == k,
                  idle: Brand.inkSecondary,
                  onTap: () => setD(() => kind = k)),
          ]),
          gap,
          pair(
              narrow,
              field(city, 'City', icon: Icons.location_city_outlined),
              field(country, 'Country', icon: Icons.public)),
          heading('HOW TO REACH THEM'),
          pair(
              narrow,
              field(person, 'Person', icon: Icons.person_outline),
              Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    field(email, 'Email',
                        icon: Icons.alternate_email,
                        type: TextInputType.emailAddress),
                    EmailTypoHint(controller: email),
                  ])),
          gap,
          field(phone, 'Phone or WhatsApp',
              icon: Icons.phone_outlined, type: TextInputType.phone),
          gap,
          pair(
              narrow,
              field(website, 'Website',
                  icon: Icons.language, type: TextInputType.url),
              field(instagram, 'Instagram', icon: Icons.camera_alt_outlined)),
          if (c == null) ...[
            heading('HOW WE KNOW THEM'),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final (k, label) in const [
                ('email', 'They emailed us'),
                ('prospect', 'We found them'),
                ('listing', 'Already listed'),
                ('manual', 'Other'),
              ])
                _pill(label,
                    on: source == k,
                    idle: Brand.inkSecondary,
                    onTap: () => setD(() => source = k)),
            ]),
            gap,
            field(message, 'What they wrote (optional)', lines: 5),
          ],
          heading('NOTES'),
          field(notes, 'Notes', lines: 4),
        ];

    final title = c == null ? 'Add a contact' : 'Edit contact';
    final narrow = MediaQuery.sizeOf(context).width < 600;

    // Jonathan, 25 Oct 2026: "after i clicked save, nothing happened ...
    // nothing had been saved". Save now saves from inside the form. If
    // the database says no, the form stays open with everything typed
    // still in it and the reason above the buttons; when it worked, a
    // short message says so.
    var busy = false;
    String? err;
    Map<String, dynamic> collect() => <String, dynamic>{
          'space_name': space.text.trim(),
          'person_name': person.text.trim(),
          'email': email.text.trim(),
          'phone': phone.text.trim(),
          'city': city.text.trim(),
          'country': country.text.trim(),
          'kind': kind,
          'website': website.text.trim(),
          'instagram': instagram.text.trim(),
          'notes': notes.text.trim(),
        };
    Future<void> save(BuildContext ctx, StateSetter setD) async {
      if (busy) return;
      setD(() {
        busy = true;
        err = null;
      });
      try {
        final fields = collect();
        if (c == null) {
          await _supabase.outreachAdd({
            ...fields,
            'source': source,
            'stage': 'new',
            if (message.text.trim().isNotEmpty) 'message': message.text.trim(),
            if (message.text.trim().isNotEmpty)
              'first_in_at': DateTime.now().toUtc().toIso8601String(),
          });
        } else {
          await _supabase.outreachUpdate('${c['id']}', fields);
        }
        if (ctx.mounted) Navigator.pop(ctx, true);
      } catch (e) {
        if (ctx.mounted) {
          setD(() {
            busy = false;
            err = _plain(e);
          });
        }
      }
    }

    Widget errorBox() => Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
              color: Brand.accentTint, borderRadius: BorderRadius.circular(10)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(
              padding: EdgeInsets.only(top: 1, right: 8),
              child: Icon(Icons.error_outline, size: 18, color: Brand.red),
            ),
            Expanded(
              child: Text(err ?? '',
                  style: const TextStyle(
                      fontSize: 13.5, height: 1.35, color: Brand.ink)),
            ),
          ]),
        );

    Widget saveButton(BuildContext ctx, StateSetter setD) => FilledButton(
          onPressed: busy ? null : () => save(ctx, setD),
          child: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(c == null ? 'Add' : 'Save'),
        );

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        // Back (the phone's gesture, the browser's button) closes the
        // form only while nothing is being saved.
        builder: (ctx, setD) => PopScope(
          canPop: !busy,
          child: narrow
            // A phone: the whole screen, Save always in reach.
            ? Dialog.fullscreen(
                backgroundColor: Brand.bg,
                child: Scaffold(
                  backgroundColor: Brand.bg,
                  appBar: AppBar(
                    leading: IconButton(
                        tooltip: 'Cancel',
                        onPressed: busy ? null : () => Navigator.pop(ctx, false),
                        icon: const Icon(Icons.close)),
                    title: Text(title),
                    actions: [
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: saveButton(ctx, setD),
                      ),
                    ],
                  ),
                  body: SafeArea(
                    top: false,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                      if (err != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                          child: errorBox(),
                        ),
                      Expanded(
                        child: ListView(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                            children: form(true, setD)),
                      ),
                    ]),
                  ),
                ),
              )
            : AlertDialog(
                title: Text(title),
                content: SizedBox(
                  width: 560,
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: form(false, setD)),
                      ),
                    ),
                    if (err != null) errorBox(),
                  ]),
                ),
                actions: [
                  TextButton(
                      onPressed: busy ? null : () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  saveButton(ctx, setD),
                ],
              ),
        ),
      ),
    );
    // The form takes a few frames to close before its fields can go.
    Future.delayed(const Duration(milliseconds: 400), () {
      for (final t in [
        space, person, email, phone, city, country, website, instagram,
        message, notes
      ]) {
        t.dispose();
      }
    });
    if (ok != true || !mounted) return;
    final name = space.text.trim().isEmpty ? 'the contact' : space.text.trim();
    _snack(c == null ? 'Added: $name' : 'Saved: $name');
    try {
      await _load();
    } catch (e) {
      if (mounted) _snack(_plain(e), bad: true);
    }
  }

  Future<void> _delete(Map<String, dynamic> c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this contact?'),
        content: Text(
            'Everything we have on ${c['space_name'] ?? c['email']} goes, '
            'including the messages. For a space that asked not to be '
            'written to, use Declined or Unsubscribed instead, so we '
            'remember.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _supabase.outreachDelete('${c['id']}');
      await _load();
    } catch (e) {
      _snack(_plain(e), bad: true);
    }
  }

  /// What a conversation was about (migration 171), as shown on the
  /// card and offered in its menu.
  static const _topics = <(String, String)>[
    ('listing', 'Listing'),
    ('booking', 'Booking'),
    ('partnership', 'Partnership'),
    ('other', 'Other business'),
    ('not_a_fit', 'Removed or not a fit'),
    ('recommendation', 'User recommendation'),
  ];

  static String? _topicLabel(Object? t) {
    for (final x in _topics) {
      if (x.$1 == t) return x.$2;
    }
    return null;
  }

  Future<void> _pickTopic(Map<String, dynamic> c) async {
    final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
              title: Text('What was it about with '
                  '${c['space_name'] ?? 'this space'}?'),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                      'Other business and Removed or not a fit move the '
                      'card to Not for outreach, unless the space has '
                      'claimed or pays.',
                      style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
                ),
                for (final t in _topics)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, t.$1),
                    child: Row(children: [
                      Icon(
                          c['topic'] == t.$1
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          size: 18,
                          color: Brand.inkMuted),
                      const SizedBox(width: 10),
                      Text(t.$2),
                    ]),
                  ),
              ],
            ));
    if (picked == null || picked == c['topic']) return;
    try {
      await _supabase.outreachSetTopic('${c['id']}', picked);
      if (!mounted) return;
      final aside = (picked == 'other' || picked == 'not_a_fit') &&
          c['stage'] != 'claimed' &&
          c['stage'] != 'verified';
      _snack(aside
          ? '${c['space_name'] ?? 'It'}: ${_topicLabel(picked)}. Moved to Not '
              'for outreach.'
          : '${c['space_name'] ?? 'It'}: ${_topicLabel(picked)}.');
      await _load();
    } catch (e) {
      if (mounted) _snack(_plain(e), bad: true);
    }
  }

  /// Marks a line as a test, or takes the mark off (migration 149):
  /// one of us trying things out, left out of every count. For a
  /// claimed space the owner's address is what is marked, so the other
  /// spaces claimed with it follow.
  Future<void> _setTest(Map<String, dynamic> c) async {
    final on = c['is_test'] != true;
    try {
      final n = await _supabase.outreachSetTest('${c['id']}', on);
      if (!mounted) return;
      final name = '${c['space_name'] ?? c['email'] ?? 'This line'}';
      final more = n > 1 ? ' (and ${n - 1} more of the same owner)' : '';
      _snack(on
          ? '$name is marked as a test and left out of the counts$more. '
              'It is under Tests.'
          : '$name is no longer a test$more.');
      await _load();
    } catch (e) {
      if (mounted) _snack(_plain(e), bad: true);
    }
  }

  /// Rows copied from a spreadsheet (or typed as lines) into contacts.
  /// With a header row the columns are read by name; without one each
  /// cell is recognised by what it looks like: an address, a link, an
  /// Instagram handle, and the first plain cell as the space's name.
  static List<Map<String, dynamic>> _rowsFromText(String raw) {
    final lines = raw
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trimRight())
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return [];
    final sep = lines.any((l) => l.contains('\t'))
        ? '\t'
        : lines.where((l) => l.contains(';')).length > lines.length / 2
            ? ';'
            : ',';
    List<String> cells(String l) => l
        .split(sep)
        .map((c) => c.trim().replaceAll(RegExp(r'^"|"$'), '').trim())
        .toList();

    String? field(String header) {
      final h = header.toLowerCase().trim();
      if (h.contains('mail')) return 'email';
      if (h.contains('instagram') || h == 'ig') return 'instagram';
      if (h.contains('web') || h.contains('url') || h == 'site') return 'website';
      if (h.contains('phone') || h.contains('whatsapp') || h == 'tel') return 'phone';
      if (h.contains('country')) return 'country';
      if (h.contains('city') || h.contains('town') || h.contains('location')) {
        return 'city';
      }
      if (h.contains('note') || h.contains('comment')) return 'notes';
      if (h == 'type' || h == 'kind') return 'kind';
      if (h.contains('person') || h.contains('contact') || h.contains('owner') ||
          h.contains('your name') || h.contains('first name')) {
        return 'person_name';
      }
      if (h.contains('space') || h.contains('business') || h.contains('venue') ||
          h.contains('listing') || h.contains('cafe') || h.contains('name')) {
        return 'space_name';
      }
      return null;
    }

    final first = cells(lines.first);
    final headers = [for (final c in first) field(c)];
    // A header row is made of column labels, matched whole: "Workspace
    // Cafe, Mexico City" is a space, not a header, and reading it as one
    // would drop the first contact and scramble the rest.
    const labels = {
      'space', 'space name', 'name', 'business', 'business name', 'venue',
      'cafe', 'coworking', 'listing', 'email', 'e-mail', 'email address',
      'mail', 'city', 'town', 'location', 'country', 'website', 'web', 'url',
      'site', 'instagram', 'ig', 'phone', 'whatsapp', 'tel', 'notes', 'note',
      'comment', 'comments', 'type', 'kind', 'person', 'contact',
      'contact name', 'owner', 'your name', 'first name',
    };
    final labelled =
        first.where((c) => labels.contains(c.toLowerCase())).length;
    final hasHeader = !first.any((c) => c.contains('@')) &&
        (labelled >= 2 ||
            (first.length == 1 && labelled == 1 && lines.length > 1));

    final out = <Map<String, dynamic>>[];
    for (final line in lines.skip(hasHeader ? 1 : 0)) {
      final cs = cells(line);
      final row = <String, dynamic>{};
      if (hasHeader) {
        for (var i = 0; i < cs.length && i < headers.length; i++) {
          final f = headers.elementAt(i);
          final v = cs.elementAt(i);
          if (f != null && v.isNotEmpty && !row.containsKey(f)) row[f] = v;
        }
      } else {
        final plain = <String>[];
        for (final v in cs) {
          if (v.isEmpty) continue;
          final low = v.toLowerCase();
          if (v.contains('@') && v.contains('.') && !v.contains(' ') &&
              !v.startsWith('@')) {
            row.putIfAbsent('email', () => v);
          } else if (low.contains('instagram.com') || v.startsWith('@')) {
            row.putIfAbsent('instagram', () => v);
          } else if (low.startsWith('http') || low.startsWith('www.')) {
            row.putIfAbsent('website', () => v);
          } else {
            plain.add(v);
          }
        }
        const order = ['space_name', 'city', 'country', 'notes'];
        for (var i = 0; i < plain.length && i < order.length; i++) {
          row[order.elementAt(i)] = plain.elementAt(i);
        }
      }
      if ('${row['email'] ?? ''}'.isEmpty && '${row['space_name'] ?? ''}'.isEmpty) {
        continue;
      }
      out.add(row);
    }
    return out;
  }

  /// Contacts from the clipboard: the backlog file (copied whole), or
  /// rows copied from a spreadsheet. Read straight from the clipboard,
  /// so a long list never has to be pasted into a box, and people's
  /// details never go through the code repository.
  Future<void> _importClipboard() async {
    String text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = (data?.text ?? '').trim();
    } catch (_) {
      text = '';
    }
    List<dynamic> list = [];
    bool fromSheet = false;
    if (text.startsWith('[')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is List) list = decoded;
      } catch (_) {}
    }
    // A file that starts like the backlog but does not read as one (cut
    // short while copying) is refused, not guessed at as rows.
    if (list.isEmpty &&
        text.isNotEmpty &&
        !text.startsWith('[') &&
        !text.startsWith('{')) {
      list = _rowsFromText(text);
      fromSheet = true;
    }
    if (list.isEmpty) {
      _snack(
          'Nothing to import on the clipboard. Copy the contacts file, or '
          'the rows of a spreadsheet (space, email, city), then press '
          'Import again.',
          bad: true);
      return;
    }
    if (!mounted) return;
    String source = 'prospect';
    String line(dynamic r) {
      final m = r is Map ? r : const {};
      return [
        '${m['space_name'] ?? ''}',
        '${m['email'] ?? ''}',
        '${m['city'] ?? ''}',
      ].where((x) => x.isNotEmpty).join(' · ');
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('Import ${list.length} contacts?'),
          content: SizedBox(
            width: 480,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('The first few, as they were read:',
                      style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
                  const SizedBox(height: 6),
                  for (final r in list.take(4))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(line(r),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13.5)),
                    ),
                  if (fromSheet) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: source,
                      decoration: const InputDecoration(
                          labelText: 'These are',
                          border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(
                            value: 'prospect',
                            child: Text('Prospects: spaces we found')),
                        DropdownMenuItem(
                            value: 'email',
                            child: Text('Spaces that wrote to us')),
                        DropdownMenuItem(
                            value: 'listing',
                            child: Text('Spaces already listed')),
                      ],
                      onChanged: (v) => setD(() => source = v ?? source),
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                      'Anyone already here is left as they are. Nothing is '
                      'sent.',
                      style: TextStyle(fontSize: 13)),
                ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Import')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (fromSheet) {
      list = [
        for (final r in list)
          {...Map<String, dynamic>.from(r as Map), 'source': source}
      ];
    }
    try {
      final r = await _supabase.outreachImport(list);
      final skipped = (r['skipped'] as num?)?.toInt() ?? 0;
      _snack('Read ${r['filed'] ?? 0} rows'
          '${skipped > 0 ? ', $skipped could not be filed (${r['first_problem']})' : ''}.');
      await _load();
    } catch (e) {
      _snack(_plain(e), bad: true);
    }
  }

  /// Every unclaimed space on nomadwise.io becomes a contact in the
  /// Listed group. Nothing is sent; addresses we do not have yet are
  /// looked up from each space's own website over the following hours.
  Future<void> _addListed() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bring in the listed spaces?'),
        content: const Text(
            'Every space on nomadwise.io that nobody has claimed gets a '
            'card here, in the Listed group. Nothing is sent. Where we do '
            'not have an email address yet, the sync reads the space\'s own '
            'website for one over the next day.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Bring them in')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await _supabase.outreachAddListed();
      _snack('Added ${r['added'] ?? 0} listed spaces, '
          '${r['with_email'] ?? 0} with an email address already.');
      await _load();
    } catch (e) {
      _snack(_plain(e), bad: true);
    }
  }

  // -------------------------------------------------------------- reply

  /// What goes inside <body> of the designed email: the part a mail
  /// program keeps when it is pasted in.
  static String _htmlFragment(String doc) {
    final start = doc.indexOf('<body');
    final open = start < 0 ? -1 : doc.indexOf('>', start);
    final end = doc.lastIndexOf('</body>');
    if (open < 0 || end <= open) return doc;
    return doc.substring(open + 1, end);
  }

  /// A second message to a space we have written to is offered only
  /// when there is a sign of interest since: the claim page was opened
  /// after our message, they have not answered, and we have written
  /// once. It is due three days after our message (Jonathan, 14 Oct
  /// 2026: no follow-ups without activity, and a good gap after the
  /// first message). Migration 187 holds its words.
  static const _followUpGap = Duration(days: 3);
  ({bool interest, DateTime? due}) _followUp(Map<String, dynamic> c) {
    final out = DateTime.tryParse('${c['last_out_at'] ?? ''}');
    final look = c['claim_look'] is Map
        ? DateTime.tryParse('${(c['claim_look'] as Map)['last_at'] ?? ''}')
        : null;
    final once = (num.tryParse('${c['message_count'] ?? 0}') ?? 0) <= 1;
    if (out == null ||
        look == null ||
        c['last_in_at'] != null ||
        !once ||
        look.isBefore(out)) {
      return (interest: false, due: null);
    }
    return (interest: true, due: out.add(_followUpGap));
  }

  /// The WhatsApp (and Instagram, Facebook) words for a space: the
  /// follow-up after our message, the note for a stranger who opened
  /// the claim page, or the first hello to a space we put on the site
  /// that has not heard from us (migration 221).
  String _waKey(Map<String, dynamic> c) {
    if (_followUp(c).interest) return 'followup_after_ours_wa';
    if (c['claim_look'] is Map) return 'claim_looked_wa';
    if (c['last_out_at'] == null && c['last_in_at'] == null) {
      return 'invite_new_page_wa';
    }
    return 'claim_looked_wa';
  }

  // ------------------------------------------------- business check

  static const _freeMail = [
    'gmail.', 'googlemail.', 'hotmail.', 'outlook.', 'live.', 'msn.',
    'yahoo.', 'ymail.', 'icloud.', 'me.com', 'mac.com', 'aol.',
    'proton.me', 'protonmail.', 'pm.me', 'gmx.', 'web.de', 'mail.ru',
    'yandex.', 'qq.com', '163.com', '126.com', 'zoho.', 'tutanota.',
  ];

  /// Whether an email address may get a first email without consent
  /// (GDPR: we only write cold to businesses; Jonathan, 25 Oct 2026):
  /// 'ok' (on the space's own website domain, or checked by one of us),
  /// 'no' (checked: not a business's), or 'check' (still to check).
  String _bizState(Map<String, dynamic> c) {
    final email = '${c['email'] ?? ''}'.trim().toLowerCase();
    if (email.isEmpty || !email.contains('@')) return 'check';
    final b = _business['${c['id']}'];
    if (b != null && '${b['email'] ?? ''}' == email) {
      return b['ok'] == true ? 'ok' : 'no';
    }
    final domain = email.split('@').last;
    if (_freeMail.any((f) => domain.startsWith(f) || domain == f)) {
      return 'check';
    }
    final site = '${c['website'] ?? ''}'.trim().toLowerCase();
    final host = (Uri.tryParse(site.contains('://') ? site : 'https://$site')
                ?.host ??
            '')
        .replaceFirst(RegExp(r'^www\.'), '');
    if (host.isNotEmpty &&
        (host == domain ||
            host.endsWith('.$domain') ||
            domain.endsWith('.$host'))) {
      return 'ok';
    }
    return 'check';
  }

  Widget _bizChip(Map<String, dynamic> c) {
    final email = '${c['email'] ?? ''}'.trim();
    if (email.isEmpty) return const SizedBox.shrink();
    final st = _bizState(c);
    final (String words, Color bg, Color fg) = switch (st) {
      'ok' => ('Business address', Brand.successTint, Brand.success),
      'no' => ('Personal address: no email', Brand.accentTint, Brand.red),
      _ => ('Check it is a business', Brand.goldTint, Brand.goldTextDark),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: st == 'ok' && _business['${c['id']}'] == null
            ? null
            : () => _confirmBusiness(c),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration:
              BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
          child: Text(words,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
        ),
      ),
    );
  }

  /// Asks whether the address is a business's and keeps the answer.
  /// True when it is.
  Future<bool> _confirmBusiness(Map<String, dynamic> c) async {
    final email = '${c['email'] ?? ''}'.trim();
    final space = '${c['space_name'] ?? c['venue_name'] ?? 'this space'}';
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Is this a business address?'),
              content: Text(
                  '$email for $space.\n\n'
                  'Under GDPR we only write to a business address without '
                  'their consent. Check it belongs to the business: on '
                  'their website, Google listing or social pages, and not '
                  'a person\'s own address.',
                  style: const TextStyle(height: 1.45)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Not a business')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Yes, a business')),
              ],
            ));
    if (ok == null) return false;
    try {
      await _supabase.outreachBusinessCheck('${c['id']}', ok);
      if (mounted) {
        setState(() {
          _business = {
            ..._business,
            '${c['id']}': {
              'email': email.toLowerCase(),
              'ok': ok,
              'at': DateTime.now().toIso8601String(),
            },
          };
        });
      }
    } catch (e) {
      _snack(_plain(e), bad: true);
      return false;
    }
    return ok;
  }

  Future<void> _reply(Map<String, dynamic> c) async {
    if ('${c['email'] ?? ''}'.isEmpty) {
      _snack('No email address for this contact yet. Edit it first.', bad: true);
      return;
    }
    // A first email to someone who has not written to us goes only to
    // a business address (GDPR). Replies to people who wrote are fine.
    if (c['last_in_at'] == null) {
      final st = _bizState(c);
      if (st == 'no') {
        _snack('This address was marked as personal, so no email. Use '
            'WhatsApp, Instagram or a business address instead.', bad: true);
        return;
      }
      if (st == 'check' && !await _confirmBusiness(c)) {
        if (mounted && _bizState(c) == 'no') {
          _snack('Marked as a personal address, so no email. Use WhatsApp, '
              'Instagram or a business address instead.', bad: true);
        }
        return;
      }
      if (!mounted) return;
    }
    if (_templates.isEmpty) {
      try {
        _templates = await _supabase.outreachTemplates();
      } catch (e) {
        _snack(_plain(e), bad: true);
        return;
      }
    }
    if (_templates.isEmpty) {
      _snack('No templates found.', bad: true);
      return;
    }
    if (!mounted) return;
    // The likeliest template first: already on the site, or not.
    final onSite = c['on_site'] == true;
    // Somebody looked at their claim page: the follow-up comes first.
    // (each in turn, down to the plain reply, if one is not there)
    // A space that has claimed gets the way into its Owner account,
    // not an invitation to claim (seen 7 Oct 2026 with Lisbon-Cowork).
    final theirOwn = (c['stage'] == 'claimed' || c['stage'] == 'verified') &&
        !(c['owner'] is Map && (c['owner'] as Map)['mine'] == false);
    // A space we know from a booking or a partnership talk is not
    // thanked for asking to be listed (migration 171).
    final known = c['topic'] == 'booking' || c['topic'] == 'partnership';
    // Never written to and never wrote to us: a first hello, not a
    // reply. A page we approved has its own (migration 178).
    final cold = c['last_in_at'] == null &&
        c['last_out_at'] == null &&
        (c['source'] == 'listing' || c['source'] == 'prospect');
    final newPage = (_newPages ?? const [])
        .any((p) => p['venue_id'] != null && p['venue_id'] == c['venue_id']);
    String key = <String>[
      if (theirOwn) 'owner_account_how',
      if (known && onSite) 'reply_we_know_you',
      if (c['signup'] is Map) 'signed_up',
      if (_followUp(c).interest) 'followup_after_ours',
      if (c['claim_look'] is Map) 'claim_looked',
      if (cold && onSite && newPage) 'invite_new_page',
      if (cold && onSite) 'invite_listed',
      onSite ? 'reply_already_listed' : 'reply_listing',
    ].firstWhere((k) => _templates.any((t) => t['key'] == k),
        orElse: () => '');
    if (key.isEmpty) {
      key = '${_templates.firstWhere((t) => !'${t['key']}'.endsWith('_wa'), orElse: () => _templates.first)['key']}';
    }
    final subject = TextEditingController();
    final body = TextEditingController();
    bool force = false;
    bool loading = true;
    bool started = false;
    // True once the email is ready to send from our own inbox (handed
    // to the mail app, or its parts offered to copy): the dialog then
    // asks whether it was sent.
    bool drafted = false;
    // The link that hands the draft to the mail app, and the part
    // last put on the clipboard.
    Uri? draftUri;
    // The designed email (migration 186), copied so that pasting it into
    // Spark keeps the button and signature; null when it could not be
    // made, and then the plain text is copied.
    String? richHtml;
    bool richCopied = false;
    String? copied;
    // Spark on Windows cannot take an email link (Readdle: "you cannot
    // currently set Spark as your default email client"), so there the
    // parts are copied over by hand and no link is fired at whatever
    // other mail app Windows has (Jonathan, 7 Oct 2026: "this open in
    // mail app didn't do anything").
    final onWindows = defaultTargetPlatform == TargetPlatform.windows;
    String unsubLink = '';
    String? problem;
    final lastOut = DateTime.tryParse('${c['last_out_at'] ?? ''}');
    final recent = lastOut != null &&
        DateTime.now().difference(lastOut).inDays < 30;

    // [open] says whether the dialog is still on screen, so nothing is
    // redrawn after Cancel.
    bool open = true;
    Future<void> fill(String k, void Function(void Function()) setD) async {
      if (!open) return;
      setD(() {
        loading = true;
        problem = null;
      });
      try {
        final p = await _supabase.outreachPreview('${c['id']}', k);
        subject.text = '${p['subject'] ?? ''}';
        body.text = '${p['body'] ?? ''}';
        unsubLink = '${p['unsubscribe_link'] ?? ''}';
      } catch (e) {
        problem = _plain(e);
      }
      if (open) setD(() => loading = false);
    }

    // The email as it leaves from our own inbox: the same words, with
    // the unsubscribe line the Postmark route adds by itself.
    String ownInboxBody() {
      final b = body.text.trimRight();
      if (b.contains('?unsubscribe=') || unsubLink.isEmpty) return b;
      return '$b\n\nIf you would rather not hear from us again: $unsubLink';
    }

    // Gets the email ready to be sent from our own mailbox by hand.
    // Where the computer's mail app can take a link (a Mac with Spark
    // as its default), the draft opens there; on Windows the address,
    // subject and text are offered to copy into Spark. The full text
    // also goes on the clipboard.
    Future<void> openDraft(void Function(void Function()) setD) async {
      setD(() {
        loading = true;
        problem = null;
      });
      try {
        // The same checks the other route makes in the database.
        final leftover = RegExp(r'\{[a-z_]+\}').firstMatch(body.text);
        final String? stop = subject.text.trim().isEmpty ||
                body.text.trim().isEmpty
            ? 'Subject and email are both needed.'
            : leftover != null
                ? 'The email still has a placeholder in it: ${leftover.group(0)}'
                : unsubLink.isEmpty && !body.text.contains('?unsubscribe=')
                    ? 'Pick the template again: the unsubscribe link did '
                        'not load.'
                    : null;
        if (stop != null) {
          if (open) {
            setD(() {
              loading = false;
              problem = stop;
            });
          }
          return;
        }
        final why = await _supabase.outreachCanSend('${c['id']}', force: force);
        if (why.isNotEmpty) {
          if (open) {
            setD(() {
              loading = false;
              problem = why;
            });
          }
          return;
        }
        final text = ownInboxBody();
        // The designed version first (Jonathan, 10 Oct 2026: Spark
        // showed the bare text, long links and no button); a browser
        // may refuse it, and then the plain text is copied. The draft
        // still opens, and the copy buttons are there.
        richHtml = await _supabase.outreachEmailHtml(text);
        richCopied = false;
        if (richHtml != null) {
          richCopied = await rich.copyRich(_htmlFragment(richHtml!), text);
        }
        if (richCopied) {
          copied = 'email';
        } else {
          try {
            await Clipboard.setData(ClipboardData(text: text));
            copied = 'email';
          } catch (_) {}
        }
        // Windows drops a link much over 2,000 characters without a
        // word, so there a long email goes over with its address and
        // subject only (for the "try this computer's mail app" button).
        final head = 'mailto:${c['email']}'
            '?subject=${Uri.encodeComponent(subject.text.trim())}';
        final full = '$head&body='
            '${Uri.encodeComponent(text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n'))}';
        // With the designed email on the clipboard, the draft opens with
        // its address and subject only, for the email to be pasted in.
        final uri = Uri.tryParse(
            richCopied || (onWindows && full.length > 1800) ? head : full);
        draftUri = uri;
        if (!onWindows && uri != null) {
          // The page cannot tell whether a mail app took the link, so
          // the next step also says what to do when nothing opened.
          try {
            await launchUrl(uri);
          } catch (_) {}
        }
        if (open) {
          setD(() {
            loading = false;
            drafted = true;
          });
        }
      } catch (e) {
        if (open) {
          setD(() {
            loading = false;
            problem = _plain(e);
          });
        }
      }
    }

    final sent = await showDialog<bool>(
      context: context,
      // Closed only by its buttons, so a send in flight is never lost.
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          if (!started) {
            started = true;
            // After this frame: the first fill redraws the dialog, which
            // cannot happen while it is being built.
            WidgetsBinding.instance
                .addPostFrameCallback((_) => fill(key, setD));
          }
          // On a phone (Jonathan, 9 Oct 2026: "Could look better on
          // mobile"): the box uses the screen's width, the email grows
          // to its full length, Cancel is the cross at the top and the
          // two ways to send sit side by side.
          final phone = MediaQuery.of(ctx).size.width < 600;
          final who = '${c['person_name'] ?? c['space_name'] ?? c['email']}';
          // Never written to and never wrote to us: a first email.
          final first = c['last_in_at'] == null && c['last_out_at'] == null;
          final title = first ? 'Write to $who' : 'Reply to $who';

          Future<void> sendHere() async {
            setD(() {
              loading = true;
              problem = null;
            });
            try {
              await _supabase.outreachSend('${c['id']}', subject.text, body.text,
                  templateKey: key, force: force);
              if (open && ctx.mounted) Navigator.pop(ctx, true);
            } catch (e) {
              if (!open) return;
              setD(() {
                loading = false;
                problem = _plain(e);
              });
            }
          }

          Future<void> logSent() async {
            setD(() {
              loading = true;
              problem = null;
            });
            try {
              await _supabase.outreachLogSent(
                  '${c['id']}', subject.text, ownInboxBody(),
                  templateKey: key, force: force);
              if (open && ctx.mounted) Navigator.pop(ctx, true);
            } catch (e) {
              if (!open) return;
              setD(() {
                loading = false;
                problem = _plain(e);
              });
            }
          }

          // The two buttons at the foot, side by side and the same width
          // on a phone.
          Widget pair(Widget a, Widget b) => Row(children: [
                Expanded(child: a),
                const SizedBox(width: 8),
                Expanded(child: b),
              ]);

          return AlertDialog(
            insetPadding: phone
                ? const EdgeInsets.symmetric(horizontal: 8, vertical: 16)
                : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
            titlePadding: phone
                ? const EdgeInsets.fromLTRB(18, 14, 6, 0)
                : const EdgeInsets.fromLTRB(24, 24, 12, 0),
            contentPadding: phone
                ? const EdgeInsets.fromLTRB(18, 12, 18, 0)
                : const EdgeInsets.fromLTRB(24, 16, 24, 0),
            actionsPadding: phone
                ? const EdgeInsets.fromLTRB(18, 12, 18, 16)
                : const EdgeInsets.fromLTRB(24, 12, 24, 20),
            title: Row(children: [
              Expanded(
                  child: Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: phone ? 19 : 22,
                          fontWeight: FontWeight.w800))),
              if (phone && !drafted)
                IconButton(
                    tooltip: 'Cancel',
                    onPressed: () => Navigator.pop(ctx, false),
                    icon: const Icon(Icons.close)),
            ]),
            content: SizedBox(
              width: 640,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    const Text('To: ', style: TextStyle(color: Brand.inkSecondary)),
                    Expanded(
                        child: Text('${c['email']}',
                            style: const TextStyle(fontWeight: FontWeight.w600))),
                  ]),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: key,
                    // the name is cut with dots, not under the arrow
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Template', border: OutlineInputBorder()),
                    items: [
                      // (the WhatsApp words are not an email)
                      for (final t in _templates)
                        if (!'${t['key']}'.endsWith('_wa'))
                          DropdownMenuItem(
                              value: '${t['key']}',
                              child: Text('${t['name']}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis)),
                    ],
                    // Once the draft is open the words are fixed, so
                    // what is recorded is what was sent.
                    onChanged: drafted
                        ? null
                        : (k) {
                            if (k == null) return;
                            key = k;
                            fill(k, setD);
                          },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                      controller: subject,
                      readOnly: drafted,
                      // a long subject wraps instead of running off;
                      // Enter still moves on (no line break in a subject)
                      minLines: 1,
                      maxLines: 3,
                      keyboardType: TextInputType.text,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                          labelText: 'Subject', border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  TextField(
                      controller: body,
                      readOnly: drafted,
                      // On a phone the whole email shows and the box
                      // scrolls; on a computer it keeps its own scroll.
                      minLines: phone ? 8 : 10,
                      maxLines: phone ? null : 16,
                      style: const TextStyle(fontSize: 13.5, height: 1.4),
                      decoration: const InputDecoration(
                          labelText: 'Email', border: OutlineInputBorder())),
                  if (recent)
                    CheckboxListTile(
                      value: force,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(
                          'We wrote to them on ${_when(c['last_out_at'])}. Send anyway.',
                          style: const TextStyle(fontSize: 13)),
                      onChanged: (v) => setD(() => force = v == true),
                    ),
                  if (problem != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(problem!,
                          style: const TextStyle(color: Brand.red, fontSize: 13)),
                    ),
                  const SizedBox(height: 6),
                  if (drafted)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          color: Brand.goldTint,
                          borderRadius: BorderRadius.circular(8)),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                onWindows
                                    ? 'Spark on Windows cannot be handed an '
                                        'email from a web page, so copy it '
                                        'over: start a new email in Spark, '
                                        'then use the three buttons below '
                                        'and paste each part. '
                                        '${richCopied ? 'The email is copied with its design (the button and the signature): click in the body of the new email and press Ctrl+V. ' : ''}'
                                        'Send it there, then come back and '
                                        'press "I sent it" so the card '
                                        'moves on.'
                                    : richCopied
                                        ? 'Your mail app should now be open '
                                            'with the address and subject. '
                                            'The email is copied with its '
                                            'design (the button and the '
                                            'signature): click in the body '
                                            'and paste it (Cmd+V). Choose '
                                            'the inbox to send from, read '
                                            'it, and send it there. Then '
                                            'come back and press "I sent '
                                            'it" so the card moves on.'
                                        : 'Your mail app should now be open '
                                            'with the draft. Choose the inbox '
                                            'to send from, read it, and send '
                                            'it there. Then come back and '
                                            'press "I sent it" so the card '
                                            'moves on.',
                                style: const TextStyle(
                                    fontSize: 13,
                                    height: 1.4,
                                    color: Brand.goldTextDark)),
                            const SizedBox(height: 6),
                            Wrap(spacing: 4, children: [
                              for (final part in <(String, String)>[
                                ('address', '${c['email']}'),
                                ('subject', subject.text.trim()),
                                ('email', ownInboxBody()),
                              ])
                                TextButton.icon(
                                    onPressed: () async {
                                      try {
                                        // the email with its design when
                                        // the browser allows it
                                        final h = richHtml;
                                        final done = part.$1 == 'email' &&
                                            h != null &&
                                            await rich.copyRich(
                                                _htmlFragment(h), part.$2);
                                        if (!done) {
                                          await Clipboard.setData(
                                              ClipboardData(text: part.$2));
                                        }
                                        if (open) {
                                          setD(() {
                                            copied = part.$1;
                                            problem = null;
                                          });
                                        }
                                      } catch (_) {
                                        if (open) {
                                          setD(() => problem =
                                              'The browser did not allow '
                                              'the copy. Select the text '
                                              'above and copy it by hand.');
                                        }
                                      }
                                    },
                                    icon: Icon(
                                        copied == part.$1
                                            ? Icons.check
                                            : Icons.copy,
                                        size: 16),
                                    label: Text(copied == part.$1
                                        ? 'Copied the ${part.$1}'
                                        : 'Copy the ${part.$1}')),
                              if (draftUri != null)
                                TextButton(
                                    onPressed: () {
                                      final u = draftUri;
                                      if (u != null) {
                                        launchUrl(u)
                                            .catchError((_) => false);
                                      }
                                    },
                                    child: Text(onWindows
                                        ? 'Try this computer\'s mail app'
                                        : 'Nothing opened? Try again')),
                            ]),
                            if (!onWindows)
                              const Text(
                                  'If nothing opens, this computer has no '
                                  'mail app set for email links. On a Mac: '
                                  'Spark, Settings, General, "Make '
                                  'default". Until then, copy the three '
                                  'parts into a new email.',
                                  style: TextStyle(
                                      fontSize: 12,
                                      height: 1.4,
                                      color: Brand.goldTextDark)),
                          ]),
                    )
                  else
                    Text(
                        'Two ways to send. "${phone ? 'My own inbox' : 'From my own inbox'}" gets the '
                        'email ready to send by hand from Spark: use it '
                        'for invitations to spaces that have not written '
                        'to us. "Send from here" goes out at once from '
                        'hello@nomadwise.io: use it to answer someone who '
                        'wrote. Either way an unsubscribe line is added if '
                        'the email has none.',
                        style: const TextStyle(
                            fontSize: 12, height: 1.4, color: Brand.inkMuted)),
                ]),
              ),
            ),
            actions: drafted
                ? [
                    if (phone)
                      pair(
                          OutlinedButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Not sent')),
                          FilledButton(
                              onPressed: loading ? null : logSent,
                              child: Text(loading ? 'One moment' : 'I sent it')))
                    else ...[
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Not sent')),
                      FilledButton(
                          onPressed: loading ? null : logSent,
                          child: Text(loading ? 'One moment' : 'I sent it')),
                    ],
                  ]
                : [
                    if (phone)
                      pair(
                          OutlinedButton(
                              onPressed: loading ? null : () => openDraft(setD),
                              style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 12)),
                              child: const Text('My own inbox',
                                  textAlign: TextAlign.center)),
                          FilledButton(
                              onPressed: loading ? null : sendHere,
                              style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 12)),
                              child: Text(
                                  loading ? 'One moment' : 'Send from here',
                                  textAlign: TextAlign.center)))
                    else ...[
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      OutlinedButton(
                          onPressed: loading ? null : () => openDraft(setD),
                          child: const Text('From my own inbox')),
                      FilledButton(
                        onPressed: loading ? null : sendHere,
                        child: Text(loading ? 'One moment' : 'Send from here'),
                      ),
                    ],
                  ],
          );
        },
      ),
    );
    open = false;
    if (sent == true) {
      _snack(drafted
          ? 'Recorded as sent to ${c['email']}.'
          : 'Sent to ${c['email']}.');
      await _load();
    }
  }

  /// What a template can have filled in for it, with a word on each.
  static const _placeholders = <(String, String)>[
    ('{first_name}', 'their first name, or "there"'),
    ('{space}', 'the space\'s name'),
    ('{city}', 'its city'),
    ('{claim_link}', 'the claim form, opened on their space'),
    ('{page_link}', 'their page on nomadwise.io'),
    ('{price_words}', 'the Plus price for their country'),
    ('{unsubscribe_link}', 'the link that stops our emails'),
    // (migration 183: an email closes "Kind regards, Jonathan Heavens,
    // Cofounder - Nomadwise.io"; a WhatsApp message keeps the short one)
    ('{signoff}', 'Kind regards, Jonathan Heavens, Cofounder'),
  ];

  /// The templates: every one listed with its subject, each editable,
  /// and a button for a new one. The list comes back after each save,
  /// so several can be changed in one go.
  Future<void> _editTemplates() async {
    while (mounted) {
      try {
        _templates = await _supabase.outreachTemplates();
      } catch (e) {
        _snack(_plain(e), bad: true);
        return;
      }
      if (!mounted) return;
      final picked = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Templates'),
          contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final t in _templates)
                  ListTile(
                    title: Text('${t['name']}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${t['subject'] ?? ''}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.edit_outlined, size: 20),
                    onTap: () => Navigator.pop(ctx, t),
                  ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                      'Tap a template to change its name, subject or words. '
                      'New ones appear in the Reply box straight away.',
                      style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close')),
            FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, <String, dynamic>{}),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New template')),
          ],
        ),
      );
      if (picked == null || !mounted) return;
      await _editTemplate(picked.isEmpty ? null : picked);
    }
  }

  /// One template in the editor. [t] null means a new one. Saving
  /// happens inside the box, so a refused save (an unknown placeholder,
  /// say) keeps what was typed.
  Future<void> _editTemplate(Map<String, dynamic>? t) async {
    final name = TextEditingController(text: '${t?['name'] ?? ''}');
    final subject = TextEditingController(text: '${t?['subject'] ?? ''}');
    final body = TextEditingController(
        text: t == null
            ? 'Hi {first_name},\n\n\n\n{signoff}'
            : '${t['body'] ?? ''}');
    bool saving = false;
    bool open = true;
    String? problem;

    // Puts a placeholder where the cursor last was in the email.
    void insert(String token) {
      final text = body.text;
      final sel = body.selection;
      final start = sel.isValid ? sel.start : text.length;
      final end = sel.isValid ? sel.end : text.length;
      body.value = TextEditingValue(
        text: text.replaceRange(start, end, token),
        selection: TextSelection.collapsed(offset: start + token.length),
      );
    }

    final done = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(t == null ? 'New template' : 'Edit template'),
          content: SizedBox(
            width: 680,
            height: 600,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                      controller: name,
                      autofocus: t == null,
                      decoration: const InputDecoration(
                          labelText: 'Name (only we see this)',
                          hintText: 'Prospect: first hello',
                          border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  TextField(
                      controller: subject,
                      decoration: const InputDecoration(
                          labelText: 'Subject',
                          hintText: 'Listing {space} on Nomadwise',
                          border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  const Text('Tap to put one in the email, where the cursor is:',
                      style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final ph in _placeholders)
                      Tooltip(
                        message: ph.$2,
                        child: ActionChip(
                          label: Text(ph.$1,
                              style: const TextStyle(fontSize: 12)),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => insert(ph.$1),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 10),
                  Expanded(
                    child: TextField(
                        controller: body,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(fontSize: 13.5, height: 1.4),
                        decoration: const InputDecoration(
                            labelText: 'Email',
                            alignLabelWithHint: true,
                            border: OutlineInputBorder())),
                  ),
                  if (problem != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(problem!,
                          style:
                              const TextStyle(color: Brand.red, fontSize: 13)),
                    ),
                  const SizedBox(height: 6),
                  const Text(
                      'House rules: no em dashes, no promised times, prices '
                      'with their symbol, "Owner account" never "members '
                      'area". An unsubscribe line is added when an email is '
                      'sent if the template has none.',
                      style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
                ]),
          ),
          actions: [
            if (t != null)
              TextButton(
                onPressed: saving
                    ? null
                    : () async {
                        final sure = await showDialog<bool>(
                          context: ctx,
                          builder: (c2) => AlertDialog(
                            title: const Text('Delete this template?'),
                            content: Text(
                                '"${t['name']}" goes for good. Emails already '
                                'sent with it stay in each space\'s history.'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(c2, false),
                                  child: const Text('Keep')),
                              FilledButton(
                                  style: FilledButton.styleFrom(
                                      backgroundColor: Brand.red),
                                  onPressed: () => Navigator.pop(c2, true),
                                  child: const Text('Delete')),
                            ],
                          ),
                        );
                        if (sure != true || !open) return;
                        setD(() {
                          saving = true;
                          problem = null;
                        });
                        try {
                          await _supabase.outreachDeleteTemplate('${t['key']}');
                          if (open && ctx.mounted) Navigator.pop(ctx, 'deleted');
                        } catch (e) {
                          if (!open || !ctx.mounted) return;
                          setD(() {
                            saving = false;
                            problem = _plain(e);
                          });
                        }
                      },
                child: const Text('Delete', style: TextStyle(color: Brand.red)),
              ),
            TextButton(
                onPressed: saving ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      setD(() {
                        saving = true;
                        problem = null;
                      });
                      try {
                        await _supabase.outreachUpsertTemplate(
                            key: t == null ? null : '${t['key']}',
                            name: name.text,
                            subject: subject.text,
                            body: body.text);
                        if (open && ctx.mounted) Navigator.pop(ctx, 'saved');
                      } catch (e) {
                        if (!open || !ctx.mounted) return;
                        setD(() {
                          saving = false;
                          problem = _plain(e);
                        });
                      }
                    },
              child: Text(saving ? 'One moment' : 'Save'),
            ),
          ],
        ),
      ),
    );
    open = false;
    if (done == 'saved') _snack('Template saved.');
    if (done == 'deleted') _snack('Template deleted.');
  }

  // ------------------------------------------------------------ the path
  // (migration 148, Jonathan 6 Oct 2026) Outreach as steps: where the
  // spaces stand before they claim and after, and what can be done
  // next on each step. Tapping a step shows its spaces below.

  /// Reaching them: key, words, what to do next.
  static const _reachSteps = <(String, String, String)>[
    (
      'no_email',
      'No address yet',
      'The nightly sync reads each space\'s own website for an address. '
          'Until it finds one, the ways in are their Instagram or the '
          'contact form on their site.'
    ),
    (
      'ready',
      'Ready to write to',
      'We hold an address and have sent nothing. Next: the first email.'
    ),
    (
      'waiting',
      'Written to, waiting',
      'We wrote and they have not answered. Next: a follow-up date on '
          'the ones worth a second try.'
    ),
    (
      'follow_up',
      'Follow-up due',
      'The date set for them has come. Next: write again, or mark Not now.'
    ),
    (
      'replied',
      'Replied',
      'They answered. Next: reply, and point them to claiming their page.'
    ),
    (
      'claim_looked',
      'Looked at the claim page',
      'Someone opened the claim page for the space in the last 60 days, '
          'it is still unclaimed, and we have not written since. Next: ask '
          'whether they had a question, by email or WhatsApp. We do not '
          'know the visitor was the owner, so the words do not say so.'
    ),
  ];

  /// Once they have claimed: key, words, what to do next, then the
  /// spaces stuck before the next step: key, words, what to do.
  static const _ownerSteps = <(String, String, String, String, String, String)>[
    (
      'claimed',
      'Claimed their page',
      'Spaces whose owner claimed the page themselves, or has been in '
          'their Owner account.',
      'not_opened',
      'not signed in yet',
      'They claimed and never came back. Next: a short note that their '
          'Owner account is there, and the one thing worth doing in it.'
    ),
    (
      'opened',
      'Signed in to their Owner account',
      'They have been in at least once.',
      'opened_only',
      'changed nothing',
      'They looked and left. Next: point them at one thing to fill in '
          '(photos, prices or opening hours).'
    ),
    (
      'used',
      'Used it',
      'They changed their page, answered a question or voted on an '
          'idea. These are the likeliest to go for Plus. Next: tell them '
          'what Plus adds.',
      '',
      '',
      ''
    ),
    (
      'looked',
      'Looked at Plus',
      'They opened the payment step and did not finish. Next: ask what '
          'held them back.',
      '',
      '',
      ''
    ),
    (
      'verified',
      'On Plus',
      'On the Plus plan. Next: keep them, and ask what they would '
          'like added.',
      '',
      '',
      ''
    ),
  ];

  int _pathN(String band, String key) {
    final b = _path?[band];
    return b is Map ? ((b[key] as num?)?.toInt() ?? 0) : 0;
  }

  /// The words and the next step for the step now showing.
  (String, String) _stepWords(String key) {
    for (final s in _reachSteps) {
      if (s.$1 == key) return (s.$2, s.$3);
    }
    for (final s in _ownerSteps) {
      if (s.$1 == key) return (s.$2, s.$3);
      if (s.$4 == key) return ('${s.$2}, ${s.$5}', s.$6);
    }
    if (key == 'ours') {
      return (
        'Set up by us, not claimed yet',
        'We put these on Plus ourselves, or put the owner on for them: '
            'booking partners, and spaces that paid for a listing the old '
            'way. Nobody there has claimed the page or been in the Owner '
            'account. Next: write to say their Owner account is ready, and '
            'how to get in.'
      );
    }
    if (key == 'form_begun') {
      return (
        'Began the claim form and stopped',
        'Someone began claiming the space, typed an address, and left '
            'before the end. They got one reminder by itself the next '
            'morning. Next: a personal note. "Use that address" on the '
            'card puts the address they typed on the line.'
      );
    }
    if (key == 'signed_up') {
      return (
        'Made an account on the map, did not claim',
        'An account was made on Nomad Maps whose name or address '
            'matches the space. It can be the owner or someone who works '
            'there. Next: tell them the space has a page and that '
            'claiming it is free. "Use that address" puts the account\'s '
            'address on the line.'
      );
    }
    if (key == 'stepped_off') {
      return (
        'Stepped off',
        'Not now, Declined, Unsubscribed, or the address bounced. '
            'Nothing to send; a Not now with a follow-up date comes back '
            'by itself.'
      );
    }
    return (key, '');
  }

  /// The lines marked as tests, and nothing else.
  void _showTests() {
    setState(() {
      _stage = 'tests';
      _group = '';
      _step = null;
      _rows = null;
    });
    _load();
  }

  void _showStep(String? key) {
    setState(() {
      _step = key;
      // A step is counted over everyone, so the group goes back to
      // Everyone and the chips keep telling the truth.
      if (key != null) _group = '';
      _rows = null;
    });
    _load();
  }

  Widget _pathRow(String key, String words, int n, int most, Color colour,
      {String stuckKey = '', String stuckWords = '', int stuckN = 0}) {
    final on = _step == key;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _showStep(on ? null : key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
            color: on ? Brand.accentTint : null,
            borderRadius: BorderRadius.circular(8)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 46,
            child: Text('$n',
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontSize: 18,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    color: n == 0 ? Brand.inkMuted : Brand.ink)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(words,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: most <= 0 ? 0 : (n / most).clamp(0.0, 1.0),
                      minHeight: 7,
                      backgroundColor: Brand.field,
                      valueColor: AlwaysStoppedAnimation<Color>(colour),
                    ),
                  ),
                  if (stuckKey.isNotEmpty && stuckN > 0)
                    InkWell(
                      onTap: () =>
                          _showStep(_step == stuckKey ? null : stuckKey),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text('$stuckN $stuckWords',
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: _step == stuckKey
                                    ? FontWeight.w800
                                    : FontWeight.w500,
                                color: Brand.accent,
                                decoration: TextDecoration.underline)),
                      ),
                    ),
                ]),
          ),
        ]),
      ),
    );
  }

  Widget _pathBand(String title, List<Widget> rows) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Text(title.toUpperCase(),
                  style: const TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.6,
                      fontWeight: FontWeight.w800,
                      color: Brand.inkMuted)),
            ),
            ...rows,
          ]);

  Widget _pathCard() {
    final p = _path;
    if (p == null) return _noNumbers();
    final reachMost = [
      for (final s in _reachSteps) _pathN('reach', s.$1)
    ].fold<int>(0, (a, b) => a > b ? a : b);
    final claimed = _pathN('owners', 'claimed');
    final off = _pathN('reach', 'stepped_off');
    final ours = _pathN('owners', 'ours');
    final paying = (p['paying'] as num?)?.toInt();
    final tests = (p['tests'] as num?)?.toInt() ?? 0;
    final since = _when(p['visits_since']);

    final reach = _pathBand('Reaching them', [
      for (final s in _reachSteps)
        _pathRow(s.$1, s.$2, _pathN('reach', s.$1), reachMost, Brand.logoNavy),
      if (off > 0)
        Padding(
          padding: const EdgeInsets.only(left: 66, right: 8),
          child: InkWell(
            onTap: () =>
                _showStep(_step == 'stepped_off' ? null : 'stepped_off'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('$off stepped off',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: _step == 'stepped_off'
                          ? FontWeight.w800
                          : FontWeight.w500,
                      color: Brand.inkSecondary,
                      decoration: TextDecoration.underline)),
            ),
          ),
        ),
    ]);
    final owners = _pathBand('Once they have claimed', [
      for (final s in _ownerSteps)
        _pathRow(s.$1, s.$2, _pathN('owners', s.$1), claimed, Brand.success,
            stuckKey: s.$4,
            stuckWords: s.$5,
            stuckN: s.$4.isEmpty ? 0 : _pathN('owners', s.$4)),
      // Verified by us, or an owner we put on: not claimed, so not in
      // the steps above. The ones to invite.
      if (ours > 0)
        Padding(
          padding: const EdgeInsets.only(left: 66, right: 8),
          child: InkWell(
            onTap: () => _showStep(_step == 'ours' ? null : 'ours'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('$ours set up by us, not claimed yet',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: _step == 'ours'
                          ? FontWeight.w800
                          : FontWeight.w500,
                      color: Brand.inkSecondary,
                      decoration: TextDecoration.underline)),
            ),
          ),
        ),
      if (paying != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(66, 4, 8, 0),
          child: Text('$paying paying through Stripe (the Money card)',
              style: const TextStyle(
                  fontSize: 12.5, color: Brand.inkSecondary)),
        ),
    ]);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
      decoration: BoxDecoration(
        color: Brand.surface,
        border: Border.all(color: Brand.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const SizedBox(width: 8),
          const Expanded(
            child: Text('The path',
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
          ),
          TextButton(
              onPressed: () => setState(() => _pathOpen = !_pathOpen),
              child: Text(_pathOpen ? 'Hide' : 'Show')),
        ]),
        if (_pathOpen) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 0, 8, 10),
            child: Text(
                'Where the spaces stand, step by step. Tap a step to see '
                'its spaces and what can be done next.',
                style: TextStyle(
                    fontSize: 12.5, height: 1.4, color: Brand.inkSecondary)),
          ),
          LayoutBuilder(
            builder: (context, box) => box.maxWidth >= 620
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        Expanded(child: reach),
                        const Padding(
                          padding: EdgeInsets.fromLTRB(4, 26, 4, 0),
                          child: Icon(Icons.arrow_forward_rounded,
                              size: 18, color: Brand.inkMuted),
                        ),
                        Expanded(child: owners),
                      ])
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        reach,
                        const Padding(
                          padding: EdgeInsets.fromLTRB(8, 8, 8, 8),
                          child: Icon(Icons.arrow_downward_rounded,
                              size: 18, color: Brand.inkMuted),
                        ),
                        owners,
                      ]),
          ),
          if (tests > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
              child: InkWell(
                onTap: _showTests,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(
                      '$tests ${tests == 1 ? 'line' : 'lines'} marked as '
                      '${tests == 1 ? 'a test' : 'tests'} (one of us), left '
                      'out of these numbers',
                      style: const TextStyle(
                          fontSize: 12.5,
                          color: Brand.goldTextDark,
                          decoration: TextDecoration.underline)),
                ),
              ),
            ),
          if (since.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
              child: Text(
                  'Openings of the Owner account are counted from $since. '
                  'Before that we only know whether an owner ever signed '
                  'in, and what they changed.',
                  style: const TextStyle(
                      fontSize: 12, height: 1.4, color: Brand.inkMuted)),
            ),
        ],
      ]),
    );
  }

  /// Which step's spaces the list is showing, what to do with them,
  /// and the way back. Under whichever card is open.
  Widget _showingBox() {
    final step = _step;
    if (step == null) return const SizedBox.shrink();
    final words = _stepWords(step);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 2),
      decoration: BoxDecoration(
          color: Brand.logoTealTint, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: 'Showing: ${words.$1}. ',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                TextSpan(text: words.$2),
              ]),
              style: const TextStyle(fontSize: 12.5, height: 1.45)),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
              onPressed: () => _showStep(null),
              child: const Text('Back to the list')),
        ),
      ]),
    );
  }

  /// The three cards above the list, one at a time.
  Widget _viewSwitch() {
    Widget tab(String key, String label, [int? count]) => _pill(label,
        count: count,
        on: _view == key,
        idle: Brand.inkSecondary,
        onTap: () => setState(() => _view = key));

    final fresh = (_newPages ?? const []).where((p) => p['ours'] != true).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        tab('new', 'New pages', fresh > 0 ? fresh : null),
        tab('signs', 'Signs of interest'),
        tab('path', 'The path'),
        tab('whole', 'The whole picture'),
      ]),
    );
  }

  /// A filter pill: compact, with its number in a small badge (Jonathan,
  /// 21 Oct 2026: "the spacing on the pills filters could be closer
  /// together. Make it look more premium"). The chosen one is filled
  /// with [color]; the others are white with [idle] words. A zero is
  /// shown faint. No extra tap padding around it, which is what spread
  /// the old chips apart.
  Widget _pill(String label,
      {int? count,
      required bool on,
      Color color = Brand.logoNavy,
      Color idle = Brand.ink,
      required VoidCallback onTap}) {
    final words = on ? Colors.white : idle;
    return SelectionContainer.disabled(
      child: Semantics(
        button: true,
        selected: on,
        child: Material(
        color: on ? color : Brand.surface,
        shape: StadiumBorder(
            side: BorderSide(color: on ? color : Brand.border)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 6, count == null ? 12 : 6, 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                      color: words)),
              if (count != null) ...[
                const SizedBox(width: 6),
                Container(
                  constraints: const BoxConstraints(minWidth: 20),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                      color: on
                          ? Colors.white.withValues(alpha: .22)
                          : Brand.field,
                      borderRadius: BorderRadius.circular(10)),
                  child: Text(NumberFormat.decimalPattern('en').format(count),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 11.5,
                          height: 1.3,
                          fontWeight: FontWeight.w700,
                          color: on
                              ? Colors.white
                              : count == 0
                                  ? Brand.inkMuted
                                  : Brand.inkSecondary)),
                ),
              ],
            ]),
          ),
        ),
      ),
      ),
    );
  }

  /// Every way a space shows interest, as a row: what happened, how
  /// many spaces stand there now, what we know, and the one thing to
  /// do (Jonathan, 7 Oct 2026: "in a super clear way, look at these
  /// scenarios and go, right, how do we address this?").
  static const _signs = <(String, String, IconData, String, String, String)>[
    // band, step, icon, what happened, what we know, what to do
    (
      'reach', 'replied', Icons.mark_email_unread_outlined,
      'They wrote back',
      'Their address, and what they said.',
      'Reply, and point them to claiming their page.'
    ),
    (
      'reach', 'form_begun', Icons.edit_note_outlined,
      'Began the claim form and stopped',
      'The address they typed. One reminder goes by itself the next '
          'morning.',
      'A personal note after that: did something on the form not work?'
    ),
    (
      'reach', 'signed_up', Icons.person_add_alt_1_outlined,
      'Made an account on the map, did not claim',
      'The account\'s name and address, which match the space (its '
          'website, its own address, or its name). It can be an owner, '
          'or someone who works there.',
      'Tell them the space has a page, and that claiming it is free.'
    ),
    (
      'reach', 'claim_looked', Icons.visibility_outlined,
      'Looked at the claim page',
      'Which space, when, how far they got, and roughly where the '
          'visitor was. Not who: it can be anyone.',
      'Ask whether they had a question, by email or WhatsApp.'
    ),
    (
      'reach', 'follow_up', Icons.event_available_outlined,
      'A follow-up date has come',
      'We wrote before and set a date to try again.',
      'Write again, or mark Not now.'
    ),
    (
      'owners', 'not_opened', Icons.lock_clock_outlined,
      'Claimed, never been in their Owner account',
      'Their address. The page is theirs and nothing has been done '
          'with it.',
      'Remind them how to get in. Two reminders go by themselves, at '
          'day 7 and day 21: see Sequences in the menu.'
    ),
    (
      'owners', 'opened_only', Icons.hourglass_empty_outlined,
      'Been in their Owner account, changed nothing',
      'Their address, and how often they came.',
      'Ask what they were looking for.'
    ),
    (
      'owners', 'looked', Icons.sell_outlined,
      'Looked at Plus, did not pay',
      'Their address, and that they opened the payment step.',
      'Ask what held them back.'
    ),
    (
      'owners', 'ours', Icons.storefront_outlined,
      'Set up by us, not claimed yet',
      'Partners and spaces listed the old way, on Plus without an '
          'account of their own.',
      'Tell them their Owner account is ready.'
    ),
  ];

  /// A new page's line, read in full, then written to (or its address
  /// added). The line is found by the space's name.
  Future<void> _openNewPage(Map<String, dynamic> p, {required bool write}) async {
    try {
      final rows = await _supabase.outreachList(
          stage: '', query: '${p['name'] ?? ''}', group: '', limit: 50);
      final c = rows.where((r) => r['id'] == p['contact_id']).firstOrNull;
      if (!mounted) return;
      if (c == null) {
        _snack('Its line in Outreach could not be found. Search for it below.',
            bad: true);
        return;
      }
      if (write) {
        await _reply(c);
      } else {
        await _editContact(c);
      }
    } catch (e) {
      if (mounted) _snack(_plain(e), bad: true);
    }
  }

  /// Every page we approved, from the moment it went live: whether we
  /// have an address, wrote to it, and whether it claimed and signed
  /// in (Jonathan, 9 Oct 2026: "to see how many actually sign up").
  Widget _newPagesCard() {
    final all = _newPages;
    if (all == null) return _noNumbers();
    final pages = all.where((p) => p['ours'] != true).toList();
    int count(bool Function(Map<String, dynamic>) f) => pages.where(f).length;
    final steps = <(String, int)>[
      ('Live', pages.length),
      ('Have an address', count((p) => '${p['email'] ?? ''}'.isNotEmpty)),
      ('Written to', count((p) => p['written_at'] != null)),
      ('Opened the claim page',
          count((p) => p['looked_at'] != null || p['claimed_at'] != null)),
      ('Claimed', count((p) => p['claimed_at'] != null)),
      ('In their Owner account', count((p) => p['been_in'] == true)),
    ];

    // Every box the same size, filling the row: six across on a wide
    // screen, three on a phone (Jonathan, 20 Oct 2026: "the boxes are
    // different heights").
    Widget stat((String, int) x, double width) => Container(
          width: width,
          height: 72,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
              color: Brand.field, borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${x.$2}',
                style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: x.$2 > 0 ? Brand.ink : Brand.inkMuted)),
            Text(x.$1,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11.5, height: 1.3, color: Brand.inkSecondary)),
          ]),
        );

    // Where it is, as a short coloured label (the pill beside the name),
    // and the detail with dates under it (Jonathan, 12 Oct 2026: a
    // premium, CRM-like list).
    ({String label, Color fg, Color bg, String detail}) stepOf(
        Map<String, dynamic> p) {
      final hasEmail = '${p['email'] ?? ''}'.isNotEmpty;
      if (p['ours'] == true) {
        return (
          label: 'Not in the test',
          fg: Brand.inkSecondary,
          bg: Brand.field,
          detail: 'Owner put on by us.'
        );
      }
      if (p['been_in'] == true) {
        return (
          label: 'In Owner account',
          fg: Brand.success,
          bg: Brand.successTint,
          detail: 'Claimed on ${_when(p['claimed_at'])} and been in their '
              'Owner account. Our emails went out by themselves when they '
              'claimed and when the claim was approved: nothing to send.'
        );
      }
      if (p['claimed_at'] != null) {
        final waiting = p['claim_status'] == 'free_pending' ||
            p['claim_status'] == 'awaiting_approval';
        return (
          label: waiting ? 'Claimed, to approve' : 'Claimed',
          fg: Brand.success,
          bg: Brand.successTint,
          detail: waiting
              ? 'Claimed on ${_when(p['claimed_at'])}, waiting for your '
                  'approval in Owners.'
              : 'Claimed on ${_when(p['claimed_at'])}, not in their Owner '
                  'account yet. Our emails went out by themselves when they '
                  'claimed and when the claim was approved.'
        );
      }
      if (p['looked_at'] != null) {
        return (
          label: 'Opened claim page',
          fg: Brand.goldTextDark,
          bg: Brand.goldTint,
          detail: 'Opened the claim page on ${_when(p['looked_at'])}, no '
              'claim yet.'
        );
      }
      if (p['written_at'] != null) {
        return (
          label: 'Written to',
          fg: Brand.logoNavy,
          bg: Brand.logoTealTint,
          detail: 'Written to on ${_when(p['written_at'])}. No visit to the '
              'claim page yet.'
        );
      }
      return hasEmail
          ? (
              label: 'Ready to write',
              fg: Brand.accent,
              bg: Brand.accentTint,
              detail: ''
            )
          : (
              label: 'Needs an address',
              fg: Brand.inkSecondary,
              bg: Brand.field,
              detail: ''
            );
    }

    String address(Map<String, dynamic> p) {
      final email = '${p['email'] ?? ''}';
      if (email.isNotEmpty) return email;
      if (p['contact_id'] == null) return 'No line in Outreach.';
      if ('${p['website'] ?? ''}'.isEmpty) {
        return 'No website to look on. Add an address by hand.';
      }
      return p['address_looked'] == true
          ? 'No address on its website. Add one by hand (a contact page '
              'or Instagram may have one).'
          : 'Looking on its website for an address.';
    }

    Widget pill(String text, Color fg, Color bg) => Container(
          padding: const EdgeInsets.fromLTRB(8, 3, 9, 3),
          decoration: BoxDecoration(
              color: bg, borderRadius: BorderRadius.circular(6)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 6,
                height: 6,
                decoration:
                    BoxDecoration(color: fg, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(text,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                    color: fg)),
          ]),
        );

    Widget pageRow(Map<String, dynamic> p) {
      final w = stepOf(p);
      final place = [p['city'], p['country']]
          .where((x) => x != null && '$x'.isNotEmpty)
          .join(', ');
      final hasEmail = '${p['email'] ?? ''}'.isNotEmpty;
      final line = p['contact_id'] != null && p['ours'] != true;
      final cowork = p['type'] == 'coworking';

      // A square tile in place of a logo: what kind of place it is.
      final tile = Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
            color: cowork ? Brand.logoTealTint : Brand.goldTint,
            borderRadius: BorderRadius.circular(9)),
        child: Icon(
            cowork ? Icons.business_center_outlined : Icons.local_cafe_outlined,
            size: 18,
            color: cowork ? Brand.logoNavy : Brand.goldTextDark),
      );

      // Claimed: the claim emails already went out by themselves (when
      // they claimed, and when the claim was approved), so there is no
      // hello to write. Jonathan, 25 Oct 2026, on Dadai: "hasn't this
      // already been sent out". Writing stays possible, quietly.
      final claimed = p['claimed_at'] != null;
      final actions = <Widget>[
        if (line && hasEmail && p['written_at'] == null && !claimed)
          FilledButton.icon(
              onPressed: () => _openNewPage(p, write: true),
              icon: const Icon(Icons.send_rounded),
              label: const Text('Write the hello')),
        if (line && !hasEmail && !claimed)
          OutlinedButton.icon(
              onPressed: () => _openNewPage(p, write: false),
              icon: const Icon(Icons.alternate_email),
              label: const Text('Add an address')),
        if (line && hasEmail && p['written_at'] != null && !claimed)
          OutlinedButton.icon(
              onPressed: () => _openNewPage(p, write: true),
              icon: const Icon(Icons.forward_to_inbox_outlined),
              label: const Text('Write again')),
        if (line && hasEmail && claimed)
          TextButton(
              onPressed: () => _openNewPage(p, write: true),
              style: TextButton.styleFrom(
                  foregroundColor: Brand.inkSecondary),
              child: const Text('Write to them')),
      ];

      final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('${p['name'] ?? ''}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                          color: Brand.ink)),
                  pill(w.label, w.fg, w.bg),
                ]),
            const SizedBox(height: 3),
            Text(
                [
                  cowork ? 'Coworking space' : 'Cafe',
                  if (place.isNotEmpty) place,
                  'live since ${_when(p['live_at'])}',
                ].join('  ·  '),
                style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
            const SizedBox(height: 8),
            Row(children: [
              Icon(hasEmail ? Icons.mail_outline : Icons.search,
                  size: 14, color: Brand.inkMuted),
              const SizedBox(width: 6),
              Flexible(
                  child: Text(address(p),
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              hasEmail ? FontWeight.w500 : FontWeight.w400,
                          color:
                              hasEmail ? Brand.ink : Brand.inkSecondary))),
            ]),
            if (w.detail.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(w.detail,
                  style: const TextStyle(
                      fontSize: 12, color: Brand.inkSecondary)),
            ],
          ]);

      return LayoutBuilder(builder: (context, box) {
        // Wide: the action sits on the right, as in a CRM list. Narrow
        // (a phone): under the text.
        final wide = box.maxWidth >= 640;
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
          decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Brand.hairline))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            tile,
            const SizedBox(width: 12),
            Expanded(
                child: wide || actions.isEmpty
                    ? info
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                            info,
                            const SizedBox(height: 10),
                            Wrap(spacing: 8, runSpacing: 8, children: actions),
                          ])),
            if (wide && actions.isNotEmpty) ...[
              const SizedBox(width: 16),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Wrap(spacing: 8, runSpacing: 8, children: actions),
              ),
            ],
          ]),
        );
      });
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
      decoration: BoxDecoration(
        color: Brand.surface,
        border: Border.all(color: Brand.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 0, 8, 10),
          child: Text(
              'Each page you approve in Pages comes here once it is live on '
              'nomadwise.io, and gets a line in Outreach (Listed, unclaimed, '
              'stage New). The sync looks on its own website for an email '
              'address. Nothing is sent by itself: you write the hello, and '
              'the numbers show how many go on to claim and sign in.',
              style: TextStyle(
                  fontSize: 12.5, height: 1.4, color: Brand.inkSecondary)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
          child: LayoutBuilder(builder: (context, box) {
            const gap = 6.0;
            final cols = box.maxWidth >= 660 ? steps.length : 3;
            final w = (box.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(spacing: gap, runSpacing: gap, children: [
              for (final x in steps) stat(x, w.floorToDouble()),
            ]);
          }),
        ),
        if (all.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Text(
                'No new page has gone live yet. The next one you approve '
                'appears here once it is published.',
                style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
          ),
        for (final p in all) pageRow(p),
      ]),
    );
  }

  /// In place of a card whose numbers did not come.
  Widget _noNumbers() => !_numbersAsked
      ? const SizedBox.shrink()
      : const Padding(
          padding: EdgeInsets.fromLTRB(8, 4, 8, 14),
          child: Text(
              'The numbers could not be read just now. The list below '
              'still works. Open Outreach again to try once more.',
              style: TextStyle(
                  fontSize: 12.5, height: 1.4, color: Brand.inkSecondary)),
        );

  Widget _signsCard() {
    final p = _path;
    if (p == null) return _noNumbers();
    // Of the looks at a claim page, the ones seen from the space's own
    // area or country (migration 154).
    final local = _pathN('reach', 'claim_looked_local');
    Widget band(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 2),
          child: Text(title.toUpperCase(),
              style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .6,
                  color: Brand.inkMuted)),
        );
    Widget row((String, String, IconData, String, String, String) s) {
      final n = _pathN(s.$1, s.$2);
      final on = _step == s.$2;
      final some = n > 0;
      final know = s.$2 == 'claim_looked' && local > 0
          ? '${s.$5} $local of them '
              '${local == 1 ? 'was' : 'were'} seen from the space\'s own '
              'area or country.'
          : s.$5;
      return Material(
          type: MaterialType.transparency,
          child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: some || on ? () => _showStep(on ? null : s.$2) : null,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          decoration: BoxDecoration(
              color: on ? Brand.logoTealTint : null,
              borderRadius: BorderRadius.circular(8)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 44,
              child: Text('$n',
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                      fontSize: 19,
                      height: 1.1,
                      fontWeight: FontWeight.w800,
                      color: some ? Brand.ink : Brand.inkMuted)),
            ),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(s.$3,
                  size: 18, color: some ? Brand.logoNavy : Brand.inkMuted),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.$4,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: some ? Brand.ink : Brand.inkSecondary)),
                    const SizedBox(height: 2),
                    Text.rich(
                        TextSpan(children: [
                          const TextSpan(
                              text: 'We know: ',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          TextSpan(text: '$know '),
                          const TextSpan(
                              text: 'Next: ',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          TextSpan(text: s.$6),
                        ]),
                        style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            color: Brand.inkSecondary)),
                  ]),
            ),
            if (some)
              const Padding(
                padding: EdgeInsets.only(left: 4, top: 2),
                child: Icon(Icons.chevron_right,
                    size: 20, color: Brand.inkMuted),
              ),
          ]),
        ),
      ));
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
      decoration: BoxDecoration(
        color: Brand.surface,
        border: Border.all(color: Brand.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 0, 8, 2),
          child: Text(
              'Every way a space shows interest, the warmest first. The '
              'number is how many spaces stand there now and still wait '
              'for us. Tap a row to see them. Nothing is sent by itself.',
              style: TextStyle(
                  fontSize: 12.5, height: 1.4, color: Brand.inkSecondary)),
        ),
        band('Before they claim'),
        for (final s in _signs)
          if (s.$1 == 'reach') row(s),
        band('After they claim'),
        for (final s in _signs)
          if (s.$1 == 'owners') row(s),
      ]),
    );
  }

  /// What a claimed space's owner has done in their Owner account, in
  /// one sentence (the "owner" part of a row, migration 148).
  String _ownerLine(Map o) {
    int n(String k) => (o[k] as num?)?.toInt() ?? 0;
    String times(int x) => x == 1 ? 'once' : '$x times';
    if (o['mine'] == false) {
      return 'Set up by us. They have not claimed the page, and there is '
          'no sign of them in their Owner account yet.';
    }
    if (o['accessed'] != true) {
      return 'Owner account: not signed in yet.';
    }
    final parts = <String>[];
    final opens = n('opens');
    if (opens > 0) {
      final days = n('open_days');
      parts.add('opened ${times(opens)}'
          '${days > 1 ? ' over $days days' : ''}'
          '${_when(o['last_open']).isEmpty ? '' : ', last on ${_when(o['last_open'])}'}');
    } else if (_when(o['signed_in_at']).isNotEmpty) {
      parts.add('last signed in ${_when(o['signed_in_at'])}');
    } else {
      parts.add('has been in');
    }
    if (n('did') == 0) {
      parts.add('nothing changed yet');
    } else {
      final did = <String>[
        if (n('submitted') > 0)
          'sent changes ${times(n('submitted'))}'
        else if (n('edits') > 0)
          'started editing, nothing sent',
        if (n('answers') > 0)
          'answered ${n('answers')} ${n('answers') == 1 ? 'question' : 'questions'}',
        if (n('ideas') > 0)
          '${n('ideas')} ${n('ideas') == 1 ? 'idea' : 'ideas'} voted on or suggested',
        if (n('billing') > 0) 'used billing ${times(n('billing'))}',
      ];
      parts.add(did.join(', '));
    }
    if (o['looked'] == true) {
      parts.add(o['checkout'] == true
          ? 'reached the payment page for Plus and did not finish'
          : 'opened the Plus step and did not finish');
    }
    return 'Owner account: ${parts.join('; ')}.';
  }

  /// "How it works": the whole of Outreach on one card, for whoever
  /// opens it next month and has forgotten (Jonathan, 4 Oct 2026).
  static const _help = <(IconData, String, String)>[
    (
      Icons.forum_outlined,
      'What this is',
      'Every cafe, coworking and coliving space we are in conversation '
          'with, in one list. Nothing here sends anything by itself: every '
          'email is read and sent by one of us.'
    ),
    (
      Icons.groups_outlined,
      'Who is in it (the first row of chips)',
      'Wrote to us: they emailed hello@, filled in a form on the site, '
          'or claimed their page.\n'
          'Listed, unclaimed: they have a page on nomadwise.io that nobody '
          'has claimed.\n'
          'Prospects: spaces we found and would like to have.'
    ),
    (
      Icons.linear_scale,
      'Where each one is (the second row)',
      'New: not written to yet.\n'
          'Contacted: we wrote.\n'
          'Replied: they answered.\n'
          'Claimed and Plus: the owner claimed the page themselves, '
          'or has been in their Owner account. These two move by '
          'themselves, and a space that claims is added here if it was '
          'not in the list. Spaces we set up ourselves are under "Set up '
          'by us" until then.\n'
          'Not now, Declined, Unsubscribed: they stepped off, and we keep '
          'the reason so we do not ask again.'
    ),
    (
      Icons.route_outlined,
      'The path (the second card at the top)',
      'The same spaces as steps, with how many stand on each. First, '
          'reaching them: no address yet, ready to write to, written '
          'to, follow-up due, replied. Then, once they have claimed: '
          'signed in to their Owner account, used it, looked at '
          'Plus, on Plus.\n'
          'Tap a step to see its spaces and what can be done next. The '
          'red lines under a step are the spaces stuck there.\n'
          'A claimed space\'s card says what its owner has done in the '
          'Owner account, and how often.'
    ),
    (
      Icons.bolt_outlined,
      'Signs of interest',
      'The first of the three cards at the top. Every way a space shows '
          'interest is a row: they wrote back, began the claim form, made '
          'an account on the map, looked at the claim page, and, after '
          'claiming, never came in, changed nothing, or looked at '
          'Plus. Each row says how many spaces stand there now, what '
          'we know about them, and the one thing to do. Tap a row to see '
          'its spaces.\n'
          'A space leaves a row when we write to it, or when "Done for '
          'now" is pressed on its card.'
    ),
    (
      Icons.table_rows_outlined,
      'The whole picture',
      'Every place we know of, counted once, from the top down: found '
          'and not checked, candidates, in the queue, and live on the '
          'site. The live ones are split into claimed, set up by us and '
          'not claimed, and the unclaimed by how far we have got with '
          'them. Each indented group adds up to the line above it, for '
          'all places, coworking spaces and cafes.\n'
          '"The path" counts lines in Outreach instead, and a space can '
          'have two, so the two do not match one for one.'
    ),
    (
      Icons.visibility_outlined,
      'Looked at the claim page',
      'When someone opens the claim page for a space and leaves without '
          'claiming, the space shows under this step (and in "Next up"), '
          'with when, how often and how far they got. Our own devices '
          'are left out.\n'
          'From its card: Reply (the follow-up template is picked for '
          'you), WhatsApp (the number is yours to type, or looked up on '
          'Google), or Done for now. Writing to them, or Done for now, '
          'takes it off the step until the claim page is opened again.\n'
          'We do not know the visitor was the owner, so the words ask '
          '"if that was you".\n'
          'The card also says roughly where the visitor was: the '
          'space\'s own area, its country, or another country. That '
          'comes from their internet connection and from the time zone '
          'their device\'s clock is set to (a VPN moves the first, not '
          'the second). It is a hint, never proof. The nearer looks '
          'come first in the list.'
    ),
    (
      Icons.storefront_outlined,
      'Set up by us, not claimed yet',
      'Some spaces are on Plus, or have an owner, because we set '
          'them up: booking partners we agreed terms with, and spaces '
          'that paid for a listing the old way. Nobody there has claimed '
          'the page or been in the Owner account, so they are not '
          'counted under the Claimed or Plus chips. They have their '
          'own chip and their own line on the path, and are the ones to '
          'invite to their Owner account. A space leaves this group by '
          'itself when its owner claims the page, or opens the Owner '
          'account.'
    ),
    (
      Icons.science_outlined,
      'Tests (one of us trying things out)',
      'A claim or a form we filled in ourselves is not a real space '
          'talking to us. Mark it from the card\'s menu, "Mark as a '
          'test". It then shows under the Tests chip only, and is left '
          'out of every number here, of the path, of the number beside '
          'Outreach in the menu, and of the Money card\'s claimed and '
          'Plus.\n'
          'Marking a claimed space marks the owner\'s address, so '
          'everything else claimed with it follows. Addresses at '
          'nomadwise.io, our own sign-in addresses and people named '
          'just "Test" are marked by themselves, as they arrive or '
          'claim. "Not a test" in the same menu takes a mark off, and '
          'it stays off. When a space gets a new owner, the space is '
          'no longer a test.'
    ),
    (
      Icons.upload_file_outlined,
      'Getting spaces in',
      'Website forms arrive by themselves.\n'
          'The upload icon (top right) takes whatever you copied: the inbox '
          'file, or rows from a spreadsheet such as space, email, city.\n'
          'In the Listed group, "Bring in listed spaces" adds every '
          'unclaimed page. Missing email addresses are looked up from each '
          'space\'s own website over the next day.\n'
          'The person icon adds one space by hand.'
    ),
    (
      Icons.send_rounded,
      'Writing to a space',
      'Press Reply on its card and pick a template. Their name, space, '
          'claim link and price fill in. Read it and change anything.\n'
          '"Send from here" goes at once from hello@nomadwise.io. Use it to '
          'answer someone who wrote to us.\n'
          '"From my own inbox" gets the email ready to send by hand from '
          'Spark: on a Mac the draft opens there; on Windows, where Spark '
          'cannot be handed an email, you copy the address, subject and '
          'text across. Use it for invitations, then press "I sent it".'
    ),
    (
      Icons.mark_email_read_outlined,
      'When they answer',
      'Replies land in the inbox, not here. Press "They replied" on the '
          'card, or open the three dots and choose "Log what they wrote" to '
          'keep their words. The same menu has notes, a follow-up date and '
          'the stage.\n'
          'Pressed it by mistake? The message at the bottom has an Undo for '
          'a few seconds, and a Replied card has "Did not reply", which '
          'puts it back.'
    ),
    (
      Icons.article_outlined,
      'Templates',
      'The page icon (top right). Tap one to change its name, subject or '
          'words, or press New template. The chips above the email put in '
          'the pieces that fill in per space.'
    ),
    (
      Icons.shield_outlined,
      'The rules built in',
      'No second email to the same space within 30 days, unless you tick '
          '"send anyway".\n'
          'No more than 40 emails a day.\n'
          'Every email carries an unsubscribe line, and nobody who used it '
          'is written to again.'
    ),
  ];

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('How Outreach works'),
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

  Widget _stageChip(String s) {
    final (bg, fg) = switch (s) {
      'new' => (Brand.accentTint, Brand.red),
      'replied' => (Brand.goldTint, Brand.goldTextDark),
      'claimed' || 'verified' => (Brand.successTint, Brand.success),
      'contacted' => (Brand.logoTealTint, Brand.logoNavy),
      _ => (Brand.field, Brand.inkSecondary),
    };
    return _chip(_stageLabel(s).toUpperCase(), bg: bg, fg: fg);
  }

  Widget _card(Map<String, dynamic> c) {
    final id = '${c['id']}';
    final name = '${c['space_name'] ?? ''}'.trim();
    final person = '${c['person_name'] ?? ''}'.trim();
    final email = '${c['email'] ?? ''}'.trim();
    final where = [
      '${c['city'] ?? ''}'.trim(),
      '${c['country'] ?? ''}'.trim(),
    ].where((x) => x.isNotEmpty).join(', ');
    final lastIn = '${c['last_in'] ?? ''}'.trim();
    final open = _expanded.contains(id);
    final onSite = c['on_site'] == true;
    final venueName = '${c['venue_name'] ?? ''}'.trim();
    final tier = '${c['listing_tier'] ?? ''}';
    final notes = '${c['notes'] ?? ''}'.trim();
    final follow = '${c['follow_up_on'] ?? ''}';
    // We set this space up (Verified by us, or an owner put on by
    // hand) and nobody there has claimed it: migration 150.
    final ours = c['owner'] is Map && (c['owner'] as Map)['mine'] == false;
    final source = switch ('${c['source']}') {
      'webflow_form' => 'Website form${c['form_name'] == null ? '' : ': ${c['form_name']}'}',
      'email' => 'Emailed us',
      'prospect' => 'Prospect',
      'listing' => 'Listed',
      'claim' => ours ? 'Set up by us' : 'Claimed their page',
      _ => 'Added by hand',
    };
    final slug = '${c['webflow_slug'] ?? ''}';

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
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(name.isEmpty ? (email.isEmpty ? 'Unknown space' : email) : name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 15.5)),
                if ('${c['kind'] ?? ''}'.isNotEmpty) _chip('${c['kind']}'),
                if (ours)
                  _chip(
                      '${c['stage']}' == 'verified'
                          ? 'PLUS, SET UP BY US'
                          : 'NOT CLAIMED YET',
                      bg: Brand.logoTealTint,
                      fg: Brand.logoNavy)
                else
                  _stageChip('${c['stage']}'),
                if (c['is_test'] == true)
                  _chip('TEST', bg: Brand.goldTint, fg: Brand.goldTextDark),
                if (_topicLabel(c['topic']) != null)
                  _chip(_topicLabel(c['topic'])!.toUpperCase(),
                      bg: c['aside'] == true ? Brand.accentTint : Brand.field,
                      fg: c['aside'] == true ? Brand.red : Brand.inkSecondary),
              ]),
              const SizedBox(height: 3),
              Text(
                  [
                    if (person.isNotEmpty) person,
                    if (email.isNotEmpty) email,
                    if (where.isNotEmpty) where,
                  ].join(' · '),
                  style: const TextStyle(fontSize: 13, color: Brand.inkSecondary)),
              if (c['last_in_at'] == null) _bizChip(c),
              const SizedBox(height: 3),
              Text(
                  '$source'
                  '${c['first_in_at'] != null ? ', first wrote ${_when(c['first_in_at'])}' : ''}'
                  '${c['last_out_at'] != null ? ' · we last wrote ${_when(c['last_out_at'])}' : ''}',
                  style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
              if (venueName.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: InkWell(
                    onTap: onSite && slug.isNotEmpty
                        ? () => launchUrl(
                            Uri.parse('https://www.nomadwise.io/coworking/$slug'))
                        : null,
                    child: Text(
                        '${onSite ? 'On nomadwise.io' : 'On the map'}: $venueName'
                        '${tier == 'verified' ? (ours ? ' (Plus, set up by us)' : ' (Plus)') : tier == 'free' && '${c['listing_owner_email'] ?? ''}'.isNotEmpty ? (ours ? ' (owner put on by us, Claimed)' : ' (Claimed)') : ''}',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: onSite ? Brand.logoNavy : Brand.inkSecondary,
                            decoration: onSite ? TextDecoration.underline : null)),
                  ),
                ),
              // Customers we sent them (migration 193): what a hello can
              // open with.
              if (_customers['${c['venue_id']}'] case final cu?)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    decoration: BoxDecoration(
                        color: Brand.successTint,
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(
                        'We sent them ${cu['sent']} '
                        '${cu['sent'] == 1 ? 'customer' : 'customers'}'
                        '${(cu['booked'] as num? ?? 0) > 0 ? ', ${cu['booked']} booked' : ''}'
                        '${_when(cu['last']).isEmpty ? '' : ' · last ${_when(cu['last'])}'}',
                        style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: Brand.success)),
                  ),
                ),
            ]),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (k) => switch (k) {
              'edit' => _editContact(c),
              'note' => _editNote(c),
              'in' => _logReply(c),
              'test' => _setTest(c),
              'topic' => _pickTopic(c),
              'delete' => _delete(c),
              _ => _setStage(c, k),
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit details')),
              const PopupMenuItem(value: 'note', child: Text('Note and follow-up date')),
              const PopupMenuItem(value: 'in', child: Text('Log what they wrote')),
              const PopupMenuItem(value: 'topic', child: Text('What it was about')),
              const PopupMenuDivider(),
              for (final s in _stages)
                if (s.$1.isNotEmpty && s.$1 != c['stage'] && s.$1 != 'verified')
                  PopupMenuItem(value: s.$1, child: Text('Mark ${s.$2}')),
              const PopupMenuDivider(),
              PopupMenuItem(
                  value: 'test',
                  child: Text(c['is_test'] == true
                      ? 'Not a test'
                      : 'Mark as a test')),
              const PopupMenuItem(value: 'delete', child: Text('Remove')),
            ],
          ),
        ]),
        if (lastIn.isNotEmpty) ...[
          const SizedBox(height: 10),
          InkWell(
            onTap: () => setState(() {
              if (!_expanded.remove(id)) _expanded.add(id);
            }),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: Brand.bg, borderRadius: BorderRadius.circular(8)),
              child: Text(lastIn,
                  maxLines: open ? null : 4,
                  overflow: open ? null : TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, height: 1.4)),
            ),
          ),
        ],
        if (c['owner'] is Map) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
                color: Brand.successTint,
                borderRadius: BorderRadius.circular(8)),
            child: Text(_ownerLine(c['owner'] as Map),
                style: const TextStyle(fontSize: 12.5, height: 1.4)),
          ),
        ],
        if (c['claim_look'] is Map) ...[
          const SizedBox(height: 10),
          _lookBox(c, c['claim_look'] as Map),
        ],
        if (c['signup'] is Map) ...[
          const SizedBox(height: 10),
          _signupBox(c, c['signup'] as Map),
        ],
        if (notes.isNotEmpty || follow.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
              [
                if (follow.isNotEmpty) 'Follow up $follow.',
                if (notes.isNotEmpty) notes,
              ].join(' '),
              style: const TextStyle(
                  fontSize: 12.5,
                  fontStyle: FontStyle.italic,
                  color: Brand.inkSecondary)),
        ],
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 6, children: [
          FilledButton.icon(
            onPressed: () => _reply(c),
            icon: const Icon(Icons.send_rounded, size: 16),
            label: Text(c['last_out_at'] == null ? 'Reply' : 'Write again'),
          ),
          if ('${c['stage']}' == 'contacted')
            OutlinedButton(
                onPressed: () => _setStage(c, 'replied'),
                child: const Text('They replied')),
          if ('${c['stage']}' == 'new' || '${c['stage']}' == 'replied')
            OutlinedButton(
                onPressed: () => _setStage(c, 'not_now'),
                child: const Text('Not now')),
          // For a card marked Replied by mistake: back to where it was
          // before, Contacted if we have written to them, otherwise New.
          if ('${c['stage']}' == 'replied')
            Tooltip(
              message: c['last_out_at'] == null
                  ? 'Marked Replied by mistake: back to New'
                  : 'Marked Replied by mistake: back to Contacted',
              child: TextButton(
                  onPressed: () => _setStage(
                      c, c['last_out_at'] == null ? 'new' : 'contacted'),
                  child: const Text('Did not reply')),
            ),
          TextButton(
              onPressed: () async {
                try {
                  final ms = await _supabase.outreachMessages(id);
                  if (!mounted) return;
                  _showHistory(c, ms);
                } catch (e) {
                  if (mounted) _snack(_plain(e), bad: true);
                }
              },
              child: Text('History (${c['message_count'] ?? 0})')),
        ]),
      ]),
    );
  }

  // ------------------------------------------- looked at the claim page

  static String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 2) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} minutes ago';
    if (d.inHours < 24) return d.inHours == 1 ? 'an hour ago' : '${d.inHours} hours ago';
    if (d.inDays == 1) return 'yesterday';
    if (d.inDays < 14) return '${d.inDays} days ago';
    return 'on ${DateFormat('d MMM').format(at)}';
  }

  static String _lasted(int secs) => secs < 90
      ? '$secs seconds'
      : '${(secs / 60).round()} minutes';

  /// A visit to the claim page that came to nothing, in a sentence.
  String _lookLine(Map l) {
    int n(String k) => (l[k] as num?)?.toInt() ?? 0;
    final at = DateTime.tryParse('${l['last_at'] ?? ''}')?.toLocal();
    final opens = n('opens');
    final visitors = n('visitors');
    final secs = n('secs');
    final far = switch (n('furthest')) {
      3 => 'got as far as choosing a plan',
      2 => 'began filling in their details',
      1 => 'began adding a space',
      _ => 'looked and left',
    };
    final from = '${l['from'] ?? ''}'.trim();
    final sentVia = from.toLowerCase();
    final ref = '${l['referrer'] ?? ''}'.trim();
    final host = (Uri.tryParse(ref)?.host ?? '').replaceFirst('www.', '');
    final device = '${l['device'] ?? ''}'.trim();
    final parts = <String>[
      'Someone opened the claim page'
          '${at == null ? '' : ' ${_ago(at)}'}'
          '${opens > 1 ? ' ($opens times${visitors > 1 ? ', $visitors visitors' : ''})' : ''}',
      '$far${secs >= 5 ? ' after ${_lasted(secs)}' : ''}',
      // (a claim link we sent says so: from=whatsapp, from=email)
      if (sentVia == 'whatsapp')
        'through our WhatsApp message'
      else if (sentVia == 'email')
        'through our email'
      else if (sentVia == 'instagram')
        'through our Instagram message'
      else if (sentVia == 'facebook')
        'through our Facebook message'
      else if (from.startsWith('/'))
        'from nomadwise.io$from'
      else if (host.isNotEmpty)
        'from $host',
      if (device == 'app')
        'in the app'
      else if (device.isNotEmpty)
        'on a $device',
    ];
    return '${parts.join(', ')}. Still unclaimed.';
  }

  Widget _lookBox(Map<String, dynamic> c, Map l) {
    final email = '${c['email'] ?? ''}'.trim().toLowerCase();
    final formEmail = '${l['form_email'] ?? ''}'.trim().toLowerCase();
    final formName = '${l['form_name'] ?? ''}'.trim();
    // Roughly where the visitor was, against the space (migration
    // 154): a hint at whether it was someone from the space.
    final geo = l['geo'];
    final where = geo is Map ? '${geo['words'] ?? ''}'.trim() : '';
    final near = geo is Map ? '${geo['near'] ?? ''}' : '';
    // It followed our own message (migration 156): that says more
    // than where the visitor was.
    final answered = geo is Map && '${geo['via'] ?? ''}'.isNotEmpty;
    final (IconData whereIcon, Color whereColor) = answered
        ? (Icons.mark_chat_read_outlined, Brand.success)
        : switch (near) {
            'near' => (Icons.place, Brand.success),
            'country' => (Icons.public, Brand.goldTextDark),
            'far' => (Icons.flight_takeoff, Brand.inkSecondary),
            _ => (Icons.place_outlined, Brand.inkSecondary),
          };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 2),
      decoration: BoxDecoration(
          color: Brand.goldTint, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_lookLine(l),
            style: const TextStyle(
                fontSize: 12.5, height: 1.4, color: Brand.goldTextDark)),
        if (where.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 4),
            child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1, right: 6),
                    child: Icon(whereIcon, size: 16, color: whereColor),
                  ),
                  Expanded(
                    child: Text(where,
                        style: TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            fontWeight: FontWeight.w700,
                            color: whereColor)),
                  ),
                ]),
          ),
        if (_followUp(c).interest)
          Builder(builder: (_) {
            final due = _followUp(c).due!;
            final ready = !DateTime.now().isBefore(due);
            return Padding(
              padding: const EdgeInsets.only(top: 4, right: 4),
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1, right: 6),
                      child: Icon(
                          ready
                              ? Icons.reply_outlined
                              : Icons.schedule_outlined,
                          size: 16,
                          color: Brand.goldTextDark),
                    ),
                    Expanded(
                      child: Text(
                          ready
                              ? 'A follow-up is due: we wrote once, '
                                  'three days or more ago, and they have '
                                  'not answered. The message is ready.'
                              : 'Best to wait before following up: due '
                                  '${DateFormat('EEE d MMM').format(due.toLocal())}, '
                                  'three days after our message.',
                          style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.4,
                              color: Brand.goldTextDark)),
                    ),
                  ]),
            );
          }),
        if (formEmail.isNotEmpty && formEmail != email)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                'They began the claim form as '
                '${formName.isEmpty ? '' : '$formName, '}$formEmail.',
                style: const TextStyle(
                    fontSize: 12.5, height: 1.4, color: Brand.goldTextDark)),
          ),
        Wrap(spacing: 2, children: [
          TextButton.icon(
              onPressed: () => _whatsApp(c),
              icon: const Icon(Icons.chat_outlined, size: 16),
              label: const Text('WhatsApp')),
          // No number, or a landline: their Instagram or Facebook page
          // is the next best way to reach a cafe (Jonathan, 7 Oct 2026).
          TextButton.icon(
              onPressed: () => _social(c, 'instagram'),
              icon: const Icon(Icons.photo_camera_outlined, size: 16),
              label: const Text('Instagram')),
          TextButton.icon(
              onPressed: () => _social(c, 'facebook'),
              icon: const Icon(Icons.thumb_up_alt_outlined, size: 16),
              label: const Text('Facebook')),
          if (formEmail.isNotEmpty && email.isEmpty)
            TextButton(
                onPressed: () async {
                  try {
                    await _supabase
                        .outreachUpdate('${c['id']}', {'email': formEmail});
                    if (!mounted) return;
                    _snack('Address saved. Press Reply to write to them.');
                    await _load();
                  } catch (e) {
                    if (mounted) _snack(_plain(e), bad: true);
                  }
                },
                child: const Text('Use that address')),
          TextButton(
              onPressed: () async {
                try {
                  await _supabase.outreachLookDone('${c['id']}');
                  if (!mounted) return;
                  _snack('Left until their claim page is opened again.');
                  await _load();
                } catch (e) {
                  if (mounted) _snack(_plain(e), bad: true);
                }
              },
              child: const Text('Done for now')),
        ]),
      ]),
    );
  }

  /// An account on the map that is plainly this space's (migration 154).
  Widget _signupBox(Map<String, dynamic> c, Map u) {
    final email = '${c['email'] ?? ''}'.trim().toLowerCase();
    final theirs = '${u['email'] ?? ''}'.trim().toLowerCase();
    final name = '${u['name'] ?? ''}'.trim();
    final at = DateTime.tryParse('${u['at'] ?? ''}')?.toLocal();
    final how = switch ('${u['how']}') {
      'address' => 'It is the address on the space\'s own website.',
      'website' => 'The address is at the space\'s own website.',
      'domain' => 'The address\'s domain is the space\'s name.',
      _ => 'The account carries the space\'s name.',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 2),
      decoration: BoxDecoration(
          color: Brand.logoTealTint, borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            'An account was made on Nomad Maps'
            '${at == null ? '' : ' ${_ago(at)}'}'
            '${name.isEmpty ? '' : ' as "$name"'}'
            '${theirs.isEmpty ? '' : ' ($theirs)'}. $how '
            'They have not claimed the page.',
            style: const TextStyle(fontSize: 12.5, height: 1.4)),
        Wrap(spacing: 2, children: [
          if (theirs.isNotEmpty && theirs != email)
            TextButton(
                onPressed: () async {
                  try {
                    await _supabase
                        .outreachUpdate('${c['id']}', {'email': theirs});
                    if (!mounted) return;
                    _snack('Address saved. Press Reply to write to them.');
                    await _load();
                  } catch (e) {
                    if (mounted) _snack(_plain(e), bad: true);
                  }
                },
                child: Text(email.isEmpty
                    ? 'Use that address'
                    : 'Use that address instead')),
          TextButton(
              onPressed: () async {
                try {
                  await _supabase.outreachSignupDone('${c['id']}');
                  if (!mounted) return;
                  _snack('Left until another such account is made.');
                  await _load();
                } catch (e) {
                  if (mounted) _snack(_plain(e), bad: true);
                }
              },
              child: const Text('Done for now')),
        ]),
      ]),
    );
  }

  /// A message to the space on Instagram or Facebook, for when there
  /// is no WhatsApp number. Neither lets a message be written from
  /// outside, so this copies the words and opens their page (or a
  /// search for it); the founder pastes and sends there, then presses
  /// "I sent it" so the card moves on. Nothing is sent from here.
  Future<void> _social(Map<String, dynamic> c, String channel) async {
    final id = '${c['id']}';
    final insta = channel == 'instagram';
    final label = insta ? 'Instagram' : 'Facebook';
    final text = TextEditingController();
    bool busy = true;
    bool opened = false;
    bool started = false;
    bool open = true;
    String? problem;
    DateTime? openedAt;

    final spaceName =
        '${c['space_name'] ?? c['venue_name'] ?? ''}'.trim();
    final spaceCity = '${c['city'] ?? c['venue_city'] ?? ''}'.trim();
    Uri? webUri(String raw) {
      final t = raw.trim();
      if (t.isEmpty) return null;
      final u = Uri.tryParse(t.contains('://') ? t : 'https://$t');
      return u != null && u.host.contains('.') ? u : null;
    }

    // Their own page when we hold it, else a search that finds it.
    // We keep Instagram names; a Facebook page is only known when the
    // space gave it as its website, which small cafes often do.
    final siteUri = webUri('${c['website'] ?? ''}');
    final siteHost = (siteUri?.host ?? '').toLowerCase();
    final instaRaw = '${c['instagram'] ?? ''}'.trim();
    final Uri? instaPage = instaRaw.isEmpty
        ? (siteHost.endsWith('instagram.com') ? siteUri : null)
        : instaRaw.contains('instagram.com')
            ? webUri(instaRaw)
            : instaRaw.contains('/')
                ? null
                : Uri.tryParse('https://www.instagram.com/'
                    '${Uri.encodeComponent(instaRaw.replaceAll('@', ''))}');
    final Uri? facebookPage =
        (siteHost.endsWith('facebook.com') || siteHost.endsWith('fb.com'))
            ? siteUri
            : null;
    final Uri? ownPage = insta ? instaPage : facebookPage;
    final searchUri = Uri.https('www.google.com', '/search',
        {'q': '$spaceName $spaceCity $label'.trim()});

    Future<void> fill(void Function(void Function()) setD) async {
      String body;
      try {
        final p = await _supabase.outreachPreview(id, _waKey(c));
        body = '${p['body'] ?? ''}';
      } catch (_) {
        body = 'Hi, this is Jonathan from Nomadwise. Someone opened the '
            'claim page for ${c['space_name'] ?? 'your space'} on our site '
            'recently. If that was you, did you have any questions?';
      }
      // The claim link says where it was sent, so a visit through it
      // is known as an answer to this message.
      text.text = body.replaceAll('from=whatsapp', 'from=$channel');
      if (open) setD(() => busy = false);
    }

    Future<void> copyAndOpen(
        Uri where, void Function(void Function()) setD) async {
      if (text.text.trim().isEmpty) {
        setD(() => problem = 'The message is empty.');
        return;
      }
      // First, while the press still counts as yours: a browser
      // blocks a new tab opened after a wait.
      // The copy is asked for first: a page that has lost the focus
      // to the new tab may be refused it.
      final copy = Clipboard.setData(ClipboardData(text: text.text.trim()));
      launchUrl(where, mode: LaunchMode.externalApplication)
          .catchError((_) => false);
      openedAt ??= DateTime.now();
      try {
        await copy;
        if (open) {
          setD(() {
            opened = true;
            problem = null;
          });
        }
      } catch (_) {
        if (open) {
          setD(() {
            opened = true;
            problem = 'The message could not be copied by itself: select '
                'it above and copy it by hand.';
          });
        }
      }
    }

    final sent = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        if (!started) {
          started = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => fill(setD));
        }
        return AlertDialog(
          title: Text('$label message to ${c['space_name'] ?? 'the space'}'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: text,
                    readOnly: opened,
                    minLines: 3,
                    maxLines: 8,
                    decoration: const InputDecoration(
                        labelText: 'Message', border: OutlineInputBorder())),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(spacing: 2, children: [
                    if (ownPage != null)
                      TextButton.icon(
                          onPressed: busy
                              ? null
                              : () => copyAndOpen(ownPage, setD),
                          icon: const Icon(Icons.open_in_new, size: 16),
                          label: Text('Copy, and open their $label')),
                    TextButton.icon(
                        onPressed:
                            busy ? null : () => copyAndOpen(searchUri, setD),
                        icon: const Icon(Icons.search, size: 16),
                        label: Text(ownPage != null
                            ? 'Copy, and search for it instead'
                            : 'Copy, and find their $label')),
                    if (siteUri != null)
                      TextButton(
                          onPressed: () => launchUrl(siteUri,
                                  mode: LaunchMode.externalApplication)
                              .catchError((_) => false),
                          child: const Text('Their website')),
                  ]),
                ),
                if (problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(problem!,
                        style:
                            const TextStyle(color: Brand.red, fontSize: 13)),
                  ),
                const SizedBox(height: 8),
                Text(
                    opened
                        ? 'The message is copied. On their $label page '
                            'press Message, paste it and send. Then come '
                            'back and press "I sent it" so the card moves '
                            'on.'
                        : '$label does not let a message be written from '
                            'here, so this copies the words and opens '
                            '${ownPage != null ? 'their page' : 'a search for their page'}'
                            '. You paste and send it there; nothing goes '
                            'by itself.',
                    style: const TextStyle(
                        fontSize: 12, height: 1.4, color: Brand.inkMuted)),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(opened ? 'Not sent' : 'Cancel')),
            if (opened)
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        setD(() {
                          busy = true;
                          problem = null;
                        });
                        try {
                          await _supabase.outreachLogMessage(
                              id, text.text.trim(), channel,
                              at: openedAt);
                          if (open && ctx.mounted) Navigator.pop(ctx, true);
                        } catch (e) {
                          if (!open) return;
                          setD(() {
                            busy = false;
                            problem = _plain(e);
                          });
                        }
                      },
                child: const Text('I sent it'),
              ),
          ],
        );
      }),
    );
    open = false;
    if (!mounted) return;
    if (sent == true) {
      _snack('Recorded as sent on $label.');
      await _load();
    }
  }

  /// A WhatsApp message to the space: the number (ours, or Google's
  /// for the place), the words from the template, WhatsApp opened with
  /// both, and "I sent it" so the card moves on. Nothing is sent from
  /// here.
  Future<void> _whatsApp(Map<String, dynamic> c) async {
    final id = '${c['id']}';
    final placeId = '${c['place_id'] ?? ''}'.trim();
    final number = TextEditingController(text: '${c['phone'] ?? ''}'.trim());
    final text = TextEditingController();
    bool busy = true;
    bool opened = false;
    bool started = false;
    bool open = true;
    String? problem;
    // The number the line holds (so a new one is saved once), and
    // whether the one in the box came from Google just now.
    String held = '${c['phone'] ?? ''}'.trim();
    bool fromGoogle = false;
    String googled = '';
    bool changed = false;
    // When WhatsApp was opened with the message: that is when it was
    // sent, not when "I sent it" is pressed afterwards.
    DateTime? openedAt;

    // Where to find a number by hand: the place on Google Maps (its
    // page shows the phone, and often a WhatsApp or website link), a
    // search, and the space's own website and Instagram when we have
    // them. Jonathan, 7 Oct 2026: "prefilled with their likely
    // WhatsApp number, or a Google link where I can then find it".
    final spaceName =
        '${c['space_name'] ?? c['venue_name'] ?? ''}'.trim();
    final spaceCity = '${c['city'] ?? c['venue_city'] ?? ''}'.trim();
    final mapsUri = Uri.https('www.google.com', '/maps/search/', {
      'api': '1',
      'query': '$spaceName $spaceCity'.trim(),
      if (placeId.isNotEmpty) 'query_place_id': placeId,
    });
    final searchUri = Uri.https('www.google.com', '/search',
        {'q': '$spaceName $spaceCity WhatsApp'.trim()});
    Uri? webUri(String raw) {
      final t = raw.trim();
      if (t.isEmpty) return null;
      final u = Uri.tryParse(t.contains('://') ? t : 'https://$t');
      return u != null && u.host.contains('.') ? u : null;
    }

    final siteUri = webUri('${c['website'] ?? ''}');
    final instaRaw = '${c['instagram'] ?? ''}'.trim();
    final instaUri = instaRaw.isEmpty
        ? null
        : instaRaw.contains('instagram.com')
            ? webUri(instaRaw)
            : instaRaw.contains('/')
                ? null
                : Uri.tryParse('https://www.instagram.com/'
                    '${Uri.encodeComponent(instaRaw.replaceAll('@', ''))}');
    void openLink(Uri u) {
      launchUrl(u, mode: LaunchMode.externalApplication)
          .catchError((_) => false);
    }

    // Google's number for the place. Asked by itself the first time
    // the box opens with no number, then kept on the line, so Google
    // is asked once per space and not again.
    Future<void> lookUp(void Function(void Function()) setD,
        {bool byHand = false}) async {
      if (placeId.isEmpty) {
        if (open) setD(() => busy = false);
        return;
      }
      if (open) {
        setD(() {
          busy = true;
          if (byHand) problem = null;
        });
      }
      final live = await _places.details(placeId);
      final ph = (live?.phone ?? '').trim();
      if (!open) return;
      setD(() {
        busy = false;
        if (ph.isNotEmpty) {
          number.text = ph;
          fromGoogle = true;
          googled = ph;
          problem = null;
        } else if (byHand) {
          problem = live == null
              ? 'Google could not be reached just now. Try again.'
              : 'Google has no phone number for this place. Try their '
                  'page on Google Maps or their website, or close this '
                  'and use Instagram or Facebook on the card.';
        }
      });
      // Kept for next time only when the line has no number yet: a
      // number already there is not replaced by a lookup.
      if (ph.isNotEmpty && held.isEmpty) {
        try {
          await _supabase.outreachUpdate(id, {'phone': ph});
          held = ph;
          changed = true;
        } catch (_) {}
      }
    }

    Future<void> fill(void Function(void Function()) setD) async {
      try {
        final p = await _supabase.outreachPreview(id, _waKey(c));
        text.text = '${p['body'] ?? ''}';
      } catch (_) {
        text.text = 'Hi, this is Jonathan from Nomadwise. Someone opened '
            'the claim page for ${c['space_name'] ?? 'your space'} on our '
            'site recently. If that was you, did you have any questions?';
      }
      if (!open) return;
      if (number.text.trim().isEmpty && placeId.isNotEmpty) {
        await lookUp(setD);
      } else {
        setD(() => busy = false);
      }
    }

    Uri? link() {
      final raw = number.text.trim();
      final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
      // WhatsApp needs the country code, and only a "+" says it is
      // there (Google's own numbers have it).
      if (digits.length < 8 || !raw.startsWith('+')) return null;
      return Uri.tryParse('https://wa.me/$digits'
          '?text=${Uri.encodeComponent(text.text.trim())}');
    }

    final sent = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        if (!started) {
          started = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => fill(setD));
        }
        return AlertDialog(
          title: Text('WhatsApp to ${c['space_name'] ?? 'the space'}'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: number,
                    readOnly: opened,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                        labelText: 'Their number, with the country code',
                        hintText: '+62 812 3456 7890',
                        border: OutlineInputBorder())),
                if (fromGoogle && !opened && number.text.trim() == googled)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(top: 6, left: 2),
                      child: Text(
                          'Filled in from Google. Check it on their page '
                          'if you are not sure.',
                          style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: Brand.inkMuted)),
                    ),
                  ),
                if (!opened)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(spacing: 2, children: [
                      if (placeId.isNotEmpty && !fromGoogle)
                        TextButton(
                            onPressed: busy
                                ? null
                                : () => lookUp(setD, byHand: true),
                            child:
                                const Text('Look the number up on Google')),
                      TextButton.icon(
                          onPressed: () => openLink(mapsUri),
                          icon: const Icon(Icons.map_outlined, size: 16),
                          label: const Text('Their page on Google Maps')),
                      TextButton.icon(
                          onPressed: () => openLink(searchUri),
                          icon: const Icon(Icons.search, size: 16),
                          label: const Text('Search for their WhatsApp')),
                      if (siteUri != null)
                        TextButton(
                            onPressed: () => openLink(siteUri),
                            child: const Text('Their website')),
                      if (instaUri != null)
                        TextButton(
                            onPressed: () => openLink(instaUri),
                            child: const Text('Their Instagram')),
                    ]),
                  ),
                const SizedBox(height: 10),
                TextField(
                    controller: text,
                    readOnly: opened,
                    minLines: 3,
                    maxLines: 8,
                    decoration: const InputDecoration(
                        labelText: 'Message', border: OutlineInputBorder())),
                if (problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(problem!,
                        style:
                            const TextStyle(color: Brand.red, fontSize: 13)),
                  ),
                const SizedBox(height: 8),
                Text(
                    opened
                        ? 'WhatsApp should have opened with the message '
                            'written. Send it there, then come back and '
                            'press "I sent it" so the card moves on.'
                        : 'This opens WhatsApp with the message written; '
                            'nothing goes until you press send there. The '
                            'number Google holds is the business line, '
                            'which is often on WhatsApp but not always.',
                    style: const TextStyle(
                        fontSize: 12, height: 1.4, color: Brand.inkMuted)),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: busy && opened
                    ? null
                    : () => Navigator.pop(ctx, false),
                child: Text(opened ? 'Not sent' : 'Cancel')),
            if (opened)
              OutlinedButton(
                  onPressed: () {
                    final u = link();
                    if (u != null) {
                      launchUrl(u, mode: LaunchMode.externalApplication)
                          .catchError((_) => false);
                    }
                  },
                  child: const Text('Open WhatsApp again')),
            FilledButton(
              onPressed: busy
                  ? null
                  : opened
                      ? () async {
                          setD(() {
                            busy = true;
                            problem = null;
                          });
                          try {
                            await _supabase.outreachLogWhatsApp(
                                id, text.text.trim(),
                                at: openedAt);
                            if (open && ctx.mounted) Navigator.pop(ctx, true);
                          } catch (e) {
                            if (!open) return;
                            setD(() {
                              busy = false;
                              problem = _plain(e);
                            });
                          }
                        }
                      : () async {
                          final u = link();
                          if (u == null) {
                            setD(() => problem =
                                'Start the number with + and the country '
                                'code (+62 for Indonesia), with no 0 after '
                                'it.');
                            return;
                          }
                          if (text.text.trim().isEmpty) {
                            setD(() => problem = 'The message is empty.');
                            return;
                          }
                          // First, while the press still counts as
                          // yours: a browser blocks a new tab opened
                          // after a wait.
                          launchUrl(u, mode: LaunchMode.externalApplication)
                              .catchError((_) => false);
                          openedAt ??= DateTime.now();
                          setD(() {
                            opened = true;
                            problem = null;
                          });
                          // The number is kept on the line for next time.
                          final used = number.text.trim();
                          if (used != held) {
                            try {
                              await _supabase
                                  .outreachUpdate(id, {'phone': used});
                              held = used;
                              changed = true;
                            } catch (_) {}
                          }
                        },
              child: Text(opened ? 'I sent it' : 'Open WhatsApp'),
            ),
          ],
        );
      }),
    );
    open = false;
    if (!mounted) return;
    if (sent == true) {
      _snack('Recorded as sent on WhatsApp.');
      await _load();
    } else if (opened || changed) {
      // the number may have been saved: show it on the card
      await _load();
    }
  }

  // ---------------------------------------------------- the whole picture

  static final _thousands = NumberFormat('#,##0', 'en_US');

  /// Every place we know of, each counted once, top down (Jonathan,
  /// 7 Oct 2026: "an overall top down reconciliation... a very clear
  /// funnel or breakdown"). For all places, coworking spaces, and the
  /// cafes and others.
  Widget _wholeCard() {
    final w = _whole;
    if (w == null) return _noNumbers();
    int? one(String k, String col) {
      final m = w[k];
      if (m is! Map) return col == 'all' ? 0 : null;
      if (!m.containsKey(col)) return null;
      return (m[col] as num?)?.toInt() ?? 0;
    }

    // The sum over several keys; null when one of them has no split.
    int? sum(List<String> ks, String col) {
      var t = 0;
      for (final k in ks) {
        final v = one(k, col);
        if (v == null) {
          // a key that is simply absent counts as nothing
          if (w[k] is Map) return null;
          continue;
        }
        t += v;
      }
      return t;
    }

    const unclaimed = [
      'u_replied', 'u_waiting', 'u_ready', 'u_no_email', 'u_stepped', 'u_none',
    ];
    const openLive = ['claimed', 'ours', 'tests', ...unclaimed];
    const live = ['live_closed', ...openLive];
    const known = [
      'found_unchecked', 'candidates', 'map_only', 'queue', ...live,
    ];
    final rows = <(int, String, List<String>, String?)>[
      (0, 'Places we know of', known, null),
      (1, 'Found by the nightly search, not checked yet',
          ['found_unchecked'], null),
      (1, 'Candidates waiting for your yes or no', ['candidates'], null),
      (1, 'On the map only, no page', ['map_only'], null),
      (1, 'Said yes to, page on its way', ['queue'], null),
      (1, 'Live on nomadwise.io', live, null),
      (2, 'Closed for good, page to retire', ['live_closed'], null),
      (2, 'Open', openLive, null),
      (3, 'Claimed by the owner', ['claimed'], 'claimed'),
      (3, 'Set up by us, not claimed yet', ['ours'], 'ours'),
      (3, 'Tests (one of us)', ['tests'], null),
      (3, 'Not claimed', unclaimed, null),
      (4, 'They replied', ['u_replied'], null),
      (4, 'Written to, waiting', ['u_waiting'], null),
      (4, 'Address known, not written to', ['u_ready'], null),
      (4, 'No address yet', ['u_no_email'], null),
      (4, 'Stepped off', ['u_stepped'], null),
      (4, 'Not in Outreach yet', ['u_none'], null),
      (0, 'Also in Outreach, not matched to a place yet',
          ['off_wrote', 'off_prospect'], null),
      (1, 'Wrote to us', ['off_wrote'], null),
      (1, 'Prospects we found', ['off_prospect'], null),
    ];
    final look = one('look', 'all') ?? 0;
    final retired = one('retired', 'all') ?? 0;

    Widget cell(int? v, {bool strong = false}) => SizedBox(
          width: 62,
          child: Text(v == null ? '' : _thousands.format(v),
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: strong ? FontWeight.w800 : FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: v == 0 ? Brand.inkMuted : Brand.ink)),
        );
    Widget head(String t) => SizedBox(
          width: 62,
          child: Text(t,
              textAlign: TextAlign.right,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
              style: const TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .3,
                  color: Brand.inkMuted)),
        );

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
      decoration: BoxDecoration(
        color: Brand.surface,
        border: Border.all(color: Brand.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const SizedBox(width: 8),
          const Expanded(
            child: Text('The whole picture',
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
          ),
          TextButton(
              onPressed: () => setState(() => _wholeOpen = !_wholeOpen),
              child: Text(_wholeOpen ? 'Hide' : 'Show')),
        ]),
        if (_wholeOpen) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text(
                'Every place we know of, each counted once, from the top '
                'down. Each indented group adds up to the line above it.',
                style: TextStyle(
                    fontSize: 12.5, height: 1.4, color: Brand.inkSecondary)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
            child: Row(children: [
              const Expanded(child: SizedBox()),
              head('ALL'),
              head('COWORKING'),
              head('CAFES'),
            ]),
          ),
          for (final r in rows)
            // a line of nothing says nothing, except the totals
            if (r.$1 <= 2 || (sum(r.$3, 'all') ?? 0) > 0)
              InkWell(
                onTap: r.$4 == null
                    ? null
                    : () => _showStep(_step == r.$4 ? null : r.$4),
                child: Container(
                  margin: EdgeInsets.only(top: r.$1 == 0 ? 6 : 0),
                  padding: EdgeInsets.fromLTRB(
                      8.0 + 10 * r.$1, 4, 8, 4),
                  decoration: r.$1 == 0
                      ? const BoxDecoration(
                          border: Border(
                              top: BorderSide(color: Brand.border)))
                      : null,
                  child: Row(children: [
                    Expanded(
                      child: Text(r.$2,
                          style: TextStyle(
                              fontSize: 13,
                              height: 1.3,
                              fontWeight: r.$1 <= 1
                                  ? FontWeight.w800
                                  : r.$1 == 2 || r.$3.length > 1
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                              decoration: r.$4 == null
                                  ? null
                                  : TextDecoration.underline,
                              color: r.$1 >= 4
                                  ? Brand.inkSecondary
                                  : Brand.ink)),
                    ),
                    cell(sum(r.$3, 'all'), strong: r.$1 <= 1),
                    cell(sum(r.$3, 'cw'), strong: r.$1 <= 1),
                    cell(sum(r.$3, 'cafe'), strong: r.$1 <= 1),
                  ]),
                ),
              ),
          if (look > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
              child: InkWell(
                onTap: () => _showStep(
                    _step == 'claim_looked' ? null : 'claim_looked'),
                child: Text(
                    look == 1
                        ? '1 unclaimed space had its claim page opened '
                            'and is still to follow up'
                        : '$look unclaimed spaces had their claim page '
                            'opened and are still to follow up',
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Brand.goldTextDark,
                        decoration: TextDecoration.underline)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
            child: Text(
                'Candidates and places not checked yet are not split by '
                'kind, so the top line shows a total only. "The path" '
                'counts lines in Outreach, not places: a space can '
                'have two lines (its own, and a person who wrote to us), '
                'and places with no live page are in it too, so its '
                'numbers do not match these one for one.'
                '${retired > 0 ? ' $retired retired ${retired == 1 ? 'page is' : 'pages are'} left out.' : ''}',
                style: const TextStyle(
                    fontSize: 12, height: 1.4, color: Brand.inkMuted)),
          ),
        ],
      ]),
    );
  }

  void _showHistory(Map<String, dynamic> c, List<Map<String, dynamic>> ms) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${c['space_name'] ?? c['email']}'),
        content: SizedBox(
          width: 600,
          height: 480,
          child: ms.isEmpty
              ? const Text('Nothing yet.')
              : ListView(children: [
                  for (final m in ms)
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          color: m['direction'] == 'out'
                              ? Brand.logoTealTint
                              : Brand.bg,
                          borderRadius: BorderRadius.circular(8)),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                '${m['direction'] == 'out' ? 'We wrote' : 'They wrote'}'
                                ' · ${_when(m['at'])}'
                                '${m['subject'] != null ? ' · ${m['subject']}' : ''}'
                                '${m['send_error'] != null ? ' · FAILED: ${m['send_error']}' : ''}',
                                style: const TextStyle(
                                    fontSize: 12, color: Brand.inkMuted)),
                            const SizedBox(height: 4),
                            SelectableText('${m['body'] ?? ''}',
                                style: const TextStyle(fontSize: 13, height: 1.4)),
                          ]),
                    ),
                ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    // Compact, CRM-style buttons on this screen (theme.dart).
    return Theme(
      data: controlCentreButtons(Theme.of(context)),
      child: _screen(context, rows),
    );
  }

  Widget _screen(BuildContext context, List<Map<String, dynamic>>? rows) {
    return Scaffold(
      appBar: AppBar(title: const Text('Outreach'), actions: [
        IconButton(
            tooltip: 'Import contacts from the clipboard',
            onPressed: _importClipboard,
            icon: const Icon(Icons.upload_file_outlined)),
        IconButton(
            tooltip: 'Templates',
            onPressed: _editTemplates,
            icon: const Icon(Icons.article_outlined)),
        IconButton(
            tooltip: 'Add a contact',
            onPressed: () => _editContact(null),
            icon: const Icon(Icons.person_add_alt_1_outlined)),
      ]),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, style: const TextStyle(color: Brand.red)),
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
                                'Every space we are talking to, and where each '
                                'one is. Nothing is sent by itself.',
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
                        const SizedBox(height: 8),
                        _viewSwitch(),
                        if (_view == 'new')
                          _newPagesCard()
                        else if (_view == 'signs')
                          _signsCard()
                        else if (_view == 'path')
                          _pathCard()
                        else
                          _wholeCard(),
                        _showingBox(),
                        TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => _load(),
                          decoration: InputDecoration(
                            hintText: 'Search by space, person, email or city',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _search.text.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.clear),
                                    onPressed: () {
                                      _search.clear();
                                      _load();
                                    }),
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 10),
                        // Who: everyone, or one group.
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final g in _groups)
                            _pill(g.$2,
                                count: g.$3.isEmpty ? null : _counts[g.$3] ?? 0,
                                on: _group == g.$1, onTap: () {
                              setState(() {
                                _group = g.$1;
                                _step = null;
                                _rows = null;
                              });
                              _load();
                            }),
                        ]),
                        if (_group == 'listed') ...[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                                color: Brand.logoTealTint,
                                borderRadius: BorderRadius.circular(10)),
                            child: Row(children: [
                              Expanded(
                                child: Text(
                                    'Spaces on nomadwise.io that nobody has '
                                    'claimed. ${_counts['_no_email'] ?? 0} of '
                                    'them have no email address yet; the sync '
                                    'reads each space\'s own website for one.',
                                    style: const TextStyle(
                                        fontSize: 12.5, height: 1.4)),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton(
                                  onPressed: _addListed,
                                  child: const Text('Bring in listed spaces')),
                            ]),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Builder(builder: (context) {
                          void pick(String stage) {
                            setState(() {
                              _stage = stage;
                              _step = null;
                              _rows = null;
                            });
                            _load();
                          }

                          // While a step of the path is showing, no
                          // stage is the chosen one.
                          Widget stagePill((String, String) s) => _pill(s.$2,
                              count: s.$1.isEmpty ? null : _counts[s.$1] ?? 0,
                              on: _step == null && _stage == s.$1,
                              color: Brand.ink,
                              onTap: () => pick(s.$1));
                          final rare = [
                            for (final s in _stages)
                              if (!_mainStages.contains(s.$1) &&
                                  ((_counts[s.$1] ?? 0) > 0 || _stage == s.$1))
                                s,
                          ];
                          final ours = _counts['ours'] ?? 0;
                          final tests = _counts['_tests'] ?? 0;
                          final aside = _counts['_aside'] ?? 0;
                          final moreCount = rare.fold<int>(
                                  0, (a, s) => a + (_counts[s.$1] ?? 0)) +
                              ours +
                              tests +
                              aside;
                          final moreOn = _step == null &&
                              !_mainStages.contains(_stage);
                          final hasMore = rare.isNotEmpty ||
                              ours > 0 ||
                              tests > 0 ||
                              aside > 0 ||
                              moreOn;
                          final open = _moreOpen || moreOn;
                          return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(spacing: 6, runSpacing: 6, children: [
                                  for (final s in _stages)
                                    if (_mainStages.contains(s.$1))
                                      stagePill(s),
                                  // (While one of its stages is chosen the
                                  // row stays open, so no button.)
                                  if (hasMore && !moreOn)
                                    _pill(open ? 'Less' : 'More',
                                        count: open ? null : moreCount,
                                        on: false,
                                        idle: Brand.inkSecondary,
                                        onTap: () => setState(
                                            () => _moreOpen = !open)),
                                ]),
                                if (open && hasMore) ...[
                                  const SizedBox(height: 8),
                                  Wrap(spacing: 6, runSpacing: 6, children: [
                                    for (final s in rare) stagePill(s),
                                    // Spaces we set up and nobody has
                                    // claimed: out of Claimed and Plus.
                                    if (ours > 0 || _stage == 'ours')
                                      _pill('Set up by us',
                                          count: ours,
                                          on: _step == null && _stage == 'ours',
                                          idle: Brand.logoNavy,
                                          onTap: () => pick('ours')),
                                    // Lines marked as tests (one of us):
                                    // here and in no other tab or number.
                                    if (tests > 0 || _stage == 'tests')
                                      _pill('Tests',
                                          count: tests,
                                          on: _step == null && _stage == 'tests',
                                          color: Brand.goldTextDark,
                                          idle: Brand.goldTextDark,
                                          onTap: _showTests),
                                    // Other business, and spaces that asked
                                    // to be removed or are not a fit: out
                                    // of the list, found by searching
                                    // (migration 171).
                                    if (aside > 0 || _stage == 'aside')
                                      _pill('Not for outreach',
                                          count: aside,
                                          on: _step == null && _stage == 'aside',
                                          color: Brand.inkSecondary,
                                          idle: Brand.inkSecondary,
                                          onTap: () => pick('aside')),
                                  ]),
                                ],
                              ]);
                        }),
                        const SizedBox(height: 14),
                        if (rows == null)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(
                                child: CircularProgressIndicator(color: Brand.red)),
                          )
                        else if (rows.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Nobody here.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Brand.inkMuted)),
                          )
                        else ...[
                          for (final c in rows) _card(c),
                          if (rows.length >= 200)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                  _step == null
                                      ? 'Showing the first 200. Search, or '
                                          'pick a stage, to narrow the list.'
                                      : 'Showing the first 200 on this '
                                          'step. Search to narrow the list.',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: 12.5, color: Brand.inkMuted)),
                            ),
                        ],
                      ]),
                ),
              ),
            ),
    );
  }
}

/// nomadmaps.io/?unsubscribe=<token>: the link at the end of every
/// outreach email. One tap, no sign-in, and we never write again.
class UnsubscribeScreen extends StatefulWidget {
  final String token;
  const UnsubscribeScreen({super.key, required this.token});
  @override
  State<UnsubscribeScreen> createState() => _UnsubscribeScreenState();
}

class _UnsubscribeScreenState extends State<UnsubscribeScreen> {
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    SupabaseService().outreachUnsubscribe(widget.token).then((r) {
      if (mounted) setState(() => _result = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Nomadwise')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: r == null
                ? const CircularProgressIndicator(color: Brand.red)
                : Text(
                    r['ok'] == true
                        ? 'Done. We will not email ${r['email'] ?? 'you'} again'
                            '${r['space'] != null ? ' about ${r['space']}' : ''}. '
                            'If you change your mind, write to hello@nomadwise.io.'
                        : 'That link did not match anything, so there is nothing '
                            'to switch off. If you keep getting emails from us, '
                            'reply to one and we stop.',
                    style: const TextStyle(fontSize: 16, height: 1.5)),
          ),
        ),
      ),
    );
  }
}
