import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Outreach (migration 121): every cafe, coworking or coliving space
/// we are talking to, in one list. Who they are, what they wrote,
/// which stage they are at, and a Reply button that fills one of our
/// templates with their details, sends it from hello@nomadwise.io and
/// logs it. Founders only.
class AdminOutreachScreen extends StatefulWidget {
  const AdminOutreachScreen({super.key});
  @override
  State<AdminOutreachScreen> createState() => _AdminOutreachScreenState();
}

class _AdminOutreachScreenState extends State<AdminOutreachScreen> {
  final _supabase = SupabaseService();
  final _search = TextEditingController();
  List<Map<String, dynamic>>? _rows;
  Map<String, int> _counts = {};
  List<Map<String, dynamic>> _templates = [];
  String _stage = 'new';
  String? _error;
  final Set<String> _expanded = {};

  static const _stages = <(String, String)>[
    ('new', 'New'),
    ('contacted', 'Contacted'),
    ('replied', 'Replied'),
    ('claimed', 'Claimed'),
    ('verified', 'Verified'),
    ('not_now', 'Not now'),
    ('declined', 'Declined'),
    ('unsubscribed', 'Unsubscribed'),
    ('', 'All'),
  ];

  static const _kinds = ['coworking', 'cafe', 'coliving', 'hotel', 'restaurant', 'other'];

  @override
  void initState() {
    super.initState();
    _load();
    _supabase.outreachTemplates().then((t) {
      if (mounted) setState(() => _templates = t);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await _supabase.outreachList(
          stage: _stage, query: _search.text.trim());
      final counts = await _supabase.outreachCounts();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _counts = counts;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _snack(String text, {bool bad = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  String _plain(Object e) {
    final s = '$e';
    final m = RegExp(r'message: ([^,}]+)').firstMatch(s);
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

  Future<void> _setStage(Map<String, dynamic> c, String stage) async {
    try {
      await _supabase.outreachUpdate('${c['id']}', {'stage': stage});
      _snack('${c['space_name'] ?? c['email']}: ${_stageLabel(stage)}.');
      await _load();
    } catch (e) {
      _snack(_plain(e), bad: true);
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

    Widget field(TextEditingController t, String label, {int lines = 1}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
              controller: t,
              maxLines: lines,
              decoration: InputDecoration(
                  labelText: label, border: const OutlineInputBorder())),
        );

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(c == null ? 'Add a contact' : 'Edit contact'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                field(space, 'Space name'),
                Row(children: [
                  Expanded(child: field(person, 'Person')),
                  const SizedBox(width: 10),
                  Expanded(child: field(email, 'Email')),
                ]),
                Row(children: [
                  Expanded(child: field(city, 'City')),
                  const SizedBox(width: 10),
                  Expanded(child: field(country, 'Country')),
                ]),
                Row(children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: DropdownButtonFormField<String>(
                        value: kind,
                        decoration: const InputDecoration(
                            labelText: 'Kind', border: OutlineInputBorder()),
                        items: [
                          for (final k in _kinds)
                            DropdownMenuItem(value: k, child: Text(k)),
                        ],
                        onChanged: (x) => setD(() => kind = x ?? kind),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: field(phone, 'Phone or WhatsApp')),
                ]),
                Row(children: [
                  Expanded(child: field(website, 'Website')),
                  const SizedBox(width: 10),
                  Expanded(child: field(instagram, 'Instagram')),
                ]),
                if (c == null) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: DropdownButtonFormField<String>(
                      value: source,
                      decoration: const InputDecoration(
                          labelText: 'How we know them',
                          border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(
                            value: 'email', child: Text('They emailed us')),
                        DropdownMenuItem(
                            value: 'prospect',
                            child: Text('We found them (prospect)')),
                        DropdownMenuItem(
                            value: 'listing',
                            child: Text('Already listed on nomadwise.io')),
                        DropdownMenuItem(value: 'manual', child: Text('Other')),
                      ],
                      onChanged: (x) => setD(() => source = x ?? source),
                    ),
                  ),
                  field(message, 'What they wrote (optional)', lines: 5),
                ],
                field(notes, 'Notes', lines: 3),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(c == null ? 'Add' : 'Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final fields = <String, dynamic>{
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
    try {
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
      await _load();
    } catch (e) {
      _snack(_plain(e), bad: true);
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

  /// A file of contacts, copied to the clipboard: the inbox backlog, or
  /// a list of prospects. Read straight from the clipboard, so a long
  /// file never has to be pasted into a box, and people's details never
  /// go through the code repository.
  Future<void> _importClipboard() async {
    List<dynamic> list;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final decoded = jsonDecode((data?.text ?? '').trim());
      if (decoded is! List || decoded.isEmpty) throw const FormatException();
      list = decoded;
    } catch (_) {
      _snack(
          'Nothing to import on the clipboard. Open the contacts file, '
          'select all, copy, then press Import again.',
          bad: true);
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Import ${list.length} contacts?'),
        content: const Text(
            'Each one is filed with what they wrote and the stage it is at. '
            'Anyone already here is left as they are. Nothing is sent.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Import')),
        ],
      ),
    );
    if (ok != true) return;
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

  // -------------------------------------------------------------- reply

  Future<void> _reply(Map<String, dynamic> c) async {
    if ('${c['email'] ?? ''}'.isEmpty) {
      _snack('No email address for this contact yet. Edit it first.', bad: true);
      return;
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
    String key = onSite ? 'reply_already_listed' : 'reply_listing';
    if (!_templates.any((t) => t['key'] == key)) key = '${_templates.first['key']}';
    final subject = TextEditingController();
    final body = TextEditingController();
    bool force = false;
    bool loading = true;
    bool started = false;
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
      } catch (e) {
        problem = _plain(e);
      }
      if (open) setD(() => loading = false);
    }

    final sent = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          if (!started) {
            started = true;
            // After this frame: the first fill redraws the dialog, which
            // cannot happen while it is being built.
            WidgetsBinding.instance
                .addPostFrameCallback((_) => fill(key, setD));
          }
          return AlertDialog(
            title: Text('Reply to ${c['person_name'] ?? c['space_name'] ?? c['email']}'),
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
                    decoration: const InputDecoration(
                        labelText: 'Template', border: OutlineInputBorder()),
                    items: [
                      for (final t in _templates)
                        DropdownMenuItem(
                            value: '${t['key']}', child: Text('${t['name']}')),
                    ],
                    onChanged: (k) {
                      if (k == null) return;
                      key = k;
                      fill(k, setD);
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                      controller: subject,
                      decoration: const InputDecoration(
                          labelText: 'Subject', border: OutlineInputBorder())),
                  const SizedBox(height: 10),
                  TextField(
                      controller: body,
                      maxLines: 16,
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
                  const Text(
                      'Sent from hello@nomadwise.io; replies land there. An '
                      'unsubscribe line is added at the end if the email has '
                      'none. Read the words once before you press Send.',
                      style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
                ]),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: loading
                    ? null
                    : () async {
                        setD(() {
                          loading = true;
                          problem = null;
                        });
                        try {
                          await _supabase.outreachSend(
                              '${c['id']}', subject.text, body.text,
                              templateKey: key, force: force);
                          if (ctx.mounted) Navigator.pop(ctx, true);
                        } catch (e) {
                          if (!open) return;
                          setD(() {
                            loading = false;
                            problem = _plain(e);
                          });
                        }
                      },
                child: Text(loading ? 'One moment' : 'Send'),
              ),
            ],
          );
        },
      ),
    );
    open = false;
    if (sent == true) {
      _snack('Sent to ${c['email']}.');
      await _load();
    }
  }

  Future<void> _editTemplates() async {
    try {
      _templates = await _supabase.outreachTemplates();
    } catch (e) {
      _snack(_plain(e), bad: true);
      return;
    }
    if (!mounted) return;
    final t = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Templates'),
        children: [
          for (final t in _templates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, t),
              child: Text('${t['name']}'),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 4),
            child: Text(
                'Placeholders: {first_name} {space} {city} {page_link} '
                '{claim_link} {price_words} {unsubscribe_link} {signoff}. '
                'No em dashes, no promised times, prices with their symbol, '
                '"Owner account" never "members area".',
                style: TextStyle(fontSize: 12, color: Brand.inkMuted)),
          ),
        ],
      ),
    );
    if (t == null || !mounted) return;
    final subject = TextEditingController(text: '${t['subject'] ?? ''}');
    final body = TextEditingController(text: '${t['body'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${t['name']}'),
        content: SizedBox(
          width: 640,
          height: 520,
          child: Column(children: [
            TextField(
                controller: subject,
                decoration: const InputDecoration(
                    labelText: 'Subject', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            Expanded(
              child: TextField(
                  controller: body,
                  maxLines: null,
                  expands: true,
                  style: const TextStyle(fontSize: 13.5, height: 1.4),
                  decoration: const InputDecoration(
                      labelText: 'Email', border: OutlineInputBorder())),
            ),
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
      await _supabase.outreachSaveTemplate('${t['key']}', subject.text, body.text);
      _templates = await _supabase.outreachTemplates();
      _snack('Template saved.');
    } catch (e) {
      _snack(_plain(e), bad: true);
    }
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
    final source = switch ('${c['source']}') {
      'webflow_form' => 'Website form${c['form_name'] == null ? '' : ': ${c['form_name']}'}',
      'email' => 'Emailed us',
      'prospect' => 'Prospect',
      'listing' => 'Listed',
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
                _stageChip('${c['stage']}'),
              ]),
              const SizedBox(height: 3),
              Text(
                  [
                    if (person.isNotEmpty) person,
                    if (email.isNotEmpty) email,
                    if (where.isNotEmpty) where,
                  ].join(' · '),
                  style: const TextStyle(fontSize: 13, color: Brand.inkSecondary)),
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
                        '${tier == 'verified' ? ' (Verified)' : tier == 'free' && '${c['listing_owner_email'] ?? ''}'.isNotEmpty ? ' (claimed, Free)' : ''}',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: onSite ? Brand.logoNavy : Brand.inkSecondary,
                            decoration: onSite ? TextDecoration.underline : null)),
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
              'delete' => _delete(c),
              _ => _setStage(c, k),
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit details')),
              const PopupMenuItem(value: 'note', child: Text('Note and follow-up date')),
              const PopupMenuItem(value: 'in', child: Text('Log what they wrote')),
              const PopupMenuDivider(),
              for (final s in _stages)
                if (s.$1.isNotEmpty && s.$1 != c['stage'] && s.$1 != 'verified')
                  PopupMenuItem(value: s.$1, child: Text('Mark ${s.$2}')),
              const PopupMenuDivider(),
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
                        const Text(
                            'Every space we are talking to: the ones that wrote '
                            'to hello@ or filled in a website form, the ones we '
                            'invite, and where each one is. Reply fills a '
                            'template with their details; you read it, then '
                            'send. Claimed and Verified move on their own.',
                            style: TextStyle(
                                fontSize: 13,
                                height: 1.45,
                                color: Brand.inkSecondary)),
                        const SizedBox(height: 12),
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
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final s in _stages)
                            ChoiceChip(
                              label: Text(
                                  '${s.$2}${s.$1.isEmpty ? '' : ' ${_counts[s.$1] ?? 0}'}'),
                              selected: _stage == s.$1,
                              onSelected: (_) {
                                setState(() {
                                  _stage = s.$1;
                                  _rows = null;
                                });
                                _load();
                              },
                            ),
                        ]),
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
                        else
                          for (final c in rows) _card(c),
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
