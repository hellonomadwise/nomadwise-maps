import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Control centre: Owner activity (migration 283).
///
/// Jonathan, 7 Nov 2026: "learn exactly what each space does ...
/// whenever they login to their owner account ... what works with the
/// owner account and what isn't working", and ask them what they are
/// looking for, "an upwards cycle of making Nomadwise better and better
/// for them".
///
/// Top to bottom: the headline numbers, what owners asked for in their
/// own words (with our answer: planned, done, not now; a done one with
/// a reply shows in their account), which tabs they open and for how
/// long, which parts of My listing they start, save or leave, what
/// else they press, and every owner with their visits step by step.
class AdminOwnerActivityScreen extends StatefulWidget {
  const AdminOwnerActivityScreen({super.key});
  @override
  State<AdminOwnerActivityScreen> createState() =>
      _AdminOwnerActivityScreenState();
}

const _red = Color(0xFFD42F3A);

const _tabNames = {
  'locations': 'All locations',
  'listing': 'My listing',
  'message': 'Promotions and events',
  'membership': 'Plan & billing',
  'badges': 'Website badges',
  'performance': 'Performance',
  'settings': 'Settings',
  'ideas': 'Build next',
  'chat': 'Inbox & support',
};

const _partNames = {
  'photos': 'Photos',
  'tags': 'Tags',
  'about': 'About',
  'prices': 'Prices',
  'coffee': 'Cappuccino price',
  'hours': 'Opening hours',
  'links': 'Links',
  'enquiries': 'Requests',
  'wifi': 'Wi-Fi',
};

const _actionNames = {
  'see_page': 'Opened their live page',
  'period': 'Changed the Performance period',
  'name_menu': 'Opened the name menu',
  'space': 'Switched location',
  'wifi_test': 'Ran the Wi-Fi test',
  'plus_window': 'Saw the Premium window',
  'badge_pack': 'Downloaded a badge pack',
  'badge_copied': 'Copied a badge code',
  'add_location': 'Pressed Add a location',
  'submitted': 'Sent changes for review',
  'saved': 'Saved changes',
  'reopened': 'Marked the space open again',
  'closed_until': 'Marked the space closed',
  'ask_shown': 'We asked: Looking for something?',
  'ask_open': 'Opened Tell us what you need',
  'ask_dismissed': 'Closed it without sending',
  'wish_sent': 'Told us what they need',
  'wish_news_seen': 'Saw a request we had done',
};

const _triggerNames = {
  'menu': 'they opened Tell us what you need',
  'lost': 'asked: they opened 4+ tabs without changing anything',
  'gave_up': 'asked: they left two parts without saving',
  'test': 'test',
};

String _tab(dynamic k) => _tabNames['$k'] ?? '$k';
String _part(dynamic k) {
  final s = '$k';
  if (_partNames.containsKey(s)) return _partNames[s]!;
  return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).replaceAll('_', ' ');
}

String _dur(num? secs) {
  final s = (secs ?? 0).round();
  if (s < 60) return '$s s';
  final m = s ~/ 60;
  if (m < 60) return '$m min';
  return '${m ~/ 60} h ${m % 60} min';
}

String _ago(dynamic iso) {
  final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  if (t == null) return 'never';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 2) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays < 14) return d.inDays == 1 ? '1 day ago' : '${d.inDays} days ago';
  return DateFormat('d MMM').format(t);
}

/// One step, in plain words.
String describe(String kind, Map detail) {
  switch (kind) {
    case 'session_start':
      return 'Came in on a ${detail['device'] ?? 'device'} '
          '(${detail['from'] ?? 'direct'})';
    case 'tab':
      final from = detail['from'];
      return from == null
          ? 'Landed on ${_tab(detail['to'])}'
          : 'Opened ${_tab(detail['to'])}  ·  ${_dur(detail['secs'])} on ${_tab(from)}';
    case 'leave':
      return 'Left or hid the page  ·  ${_dur(detail['secs'])} on ${_tab(detail['from'])}';
    case 'edit_start':
      return 'Started changing ${_part(detail['part'])}';
    case 'edit_save':
      return 'Saved ${_part(detail['part'])}  ·  took ${_dur(detail['secs'])}';
    case 'edit_cancel':
      return 'Cancelled ${_part(detail['part'])} without saving  ·  after ${_dur(detail['secs'])}';
    case 'edit_close':
      return 'Closed ${_part(detail['part'])} without saving';
    case 'period':
      return 'Changed the Performance period to ${detail['days']} days';
  }
  final base = _actionNames[kind] ?? kind.replaceAll('_', ' ');
  final extra = [
    for (final e in detail.entries)
      if (e.key != 'trigger' || kind.startsWith('ask')) '${e.key}: ${e.value}'
  ].join(', ');
  return extra.isEmpty ? base : '$base ($extra)';
}

class _AdminOwnerActivityScreenState extends State<AdminOwnerActivityScreen> {
  final _supabase = SupabaseService();
  int _days = 30;
  bool _team = false;
  Map<String, dynamic>? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await _supabase.adminOwnerActivity(_days, team: _team);
      if (mounted) setState(() => _d = d);
    } catch (e) {
      if (mounted) {
        setState(() {
          _d = {};
          _error = '$e'.contains('admin_owner_activity')
              ? 'Not installed yet: migration 283 has not run. Check the last build on GitHub.'
              : 'Could not load: $e';
        });
      }
    }
  }

  List<Map<String, dynamic>> _list(String k) => [
        for (final x in (_d?[k] as List? ?? const []))
          Map<String, dynamic>.from(x as Map)
      ];

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(
        title: const Text('Owner activity'),
        actions: [
          IconButton(
              tooltip: 'Refresh',
              onPressed: _load,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _controls(),
                            if (_error != null) ...[
                              const SizedBox(height: 16),
                              Text(_error!, style: const TextStyle(color: _red)),
                            ] else ...[
                              const SizedBox(height: 16),
                              _summary(),
                              const SizedBox(height: 24),
                              _wishes(),
                              const SizedBox(height: 24),
                              _tabs(),
                              const SizedBox(height: 24),
                              _edits(),
                              const SizedBox(height: 24),
                              _actions(),
                              const SizedBox(height: 24),
                              _people(),
                            ],
                          ]),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _controls() => Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final n in [7, 30, 90])
            ChoiceChip(
              label: Text('Last $n days'),
              selected: _days == n,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              onSelected: (_) {
                setState(() => _days = n);
                _load();
              },
            ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Include our own visits'),
            selected: _team,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            onSelected: (v) {
              setState(() => _team = v);
              _load();
            },
          ),
        ],
      );

  Widget _card(String title, String help, Widget child) => Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Brand.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(help,
              style: const TextStyle(
                  fontSize: 13, color: Brand.inkSecondary, height: 1.4)),
          const SizedBox(height: 14),
          child,
        ]),
      );

  Widget _stat(String value, String label) => Container(
        width: 170,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Brand.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        ]),
      );

  Widget _summary() {
    final d = _d!;
    final newWishes =
        _list('wishes').where((w) => w['status'] == 'new').length;
    return Wrap(spacing: 12, runSpacing: 12, children: [
      _stat('${d['owners_active'] ?? 0} of ${d['owners_total'] ?? 0}',
          'owners came in'),
      _stat('${d['sessions'] ?? 0}', 'visits'),
      _stat(_dur(d['median_secs'] as num?), 'a typical visit'),
      _stat('${d['minutes'] ?? 0} min', 'time in accounts'),
      _stat('${d['phone_share'] ?? 0}%', 'of visits on a phone'),
      _stat('$newWishes', newWishes == 1 ? 'request to answer' : 'requests to answer'),
    ]);
  }

  // ------------------------------------------------------------ wishes

  Widget _wishes() {
    final list = _list('wishes');
    return _card(
      'What they asked for',
      'In their own words, from "Looking for something?". Mark each one. '
          'Planned shows in their account as "We\'re working on what you '
          'asked for"; Done (with a reply saying where to find it) as "You '
          "asked for this. It's here now.\" Not now stays with us.",
      list.isEmpty
          ? const Text('Nothing yet.', style: TextStyle(color: Brand.inkMuted))
          : Column(children: [
              for (final w in list) _WishRow(key: ValueKey(w['id']), w: w, onSaved: _load),
            ]),
    );
  }

  // ------------------------------------------------------------ tabs

  Widget _tabs() {
    final rows = {for (final t in _list('tabs')) '${t['tab']}': t};
    final active = ((_d?['owners_active'] as num?) ?? 0).toInt();
    final keys = [
      ..._tabNames.keys.where(rows.containsKey),
      ...rows.keys.where((k) => !_tabNames.containsKey(k)),
      ..._tabNames.keys.where((k) => !rows.containsKey(k)),
    ];
    return _card(
      'What they open',
      'How many owners opened each tab, how often, and the time spent there. '
          'A tab nobody opens is a sign it is hidden, unclear or not needed.',
      Column(children: [
        for (final k in keys)
          Builder(builder: (_) {
            final r = rows[k];
            final owners = ((r?['owners'] as num?) ?? 0).toInt();
            final opens = ((r?['opens'] as num?) ?? 0).toInt();
            final secs = (r?['secs'] as num?) ?? 0;
            final share = active == 0 ? 0.0 : owners / active;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                SizedBox(
                    width: 170,
                    child: Text(_tab(k),
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: share.clamp(0, 1).toDouble(),
                      minHeight: 8,
                      backgroundColor: Brand.field,
                      color: owners == 0 ? Brand.inkFaint : Brand.red,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 230,
                  child: Text(
                      owners == 0
                          ? 'Nobody opened this'
                          : '$owners of $active owners · $opens ${opens == 1 ? 'open' : 'opens'} · '
                              '${_dur(opens == 0 ? 0 : secs / opens)} each',
                      style: TextStyle(
                          fontSize: 12.5,
                          color: owners == 0 ? _red : Brand.inkSecondary)),
                ),
              ]),
            );
          }),
      ]),
    );
  }

  // ------------------------------------------------------------ edits

  Widget _edits() {
    final list = _list('edits');
    return _card(
      'What they change in My listing',
      'Each part: how often owners started changing it, saved it, or left '
          'it without saving. Many left and few saved means that part is hard.',
      list.isEmpty
          ? const Text('Nobody has changed anything yet in this period.',
              style: TextStyle(color: Brand.inkMuted))
          : Column(children: [
              for (final e in list)
                Builder(builder: (_) {
                  final started = ((e['started'] as num?) ?? 0).toInt();
                  final saved = ((e['saved'] as num?) ?? 0).toInt();
                  final left = ((e['left'] as num?) ?? 0).toInt();
                  final pct = started == 0 ? 0 : (100 * saved / started).round();
                  final hard = left > saved;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      SizedBox(
                          width: 170,
                          child: Text(_part(e['part']),
                              style: const TextStyle(fontWeight: FontWeight.w600))),
                      Expanded(
                        child: Text(
                            '$started started · $saved saved · $left left without saving'
                            ' · ${e['owners']} owners',
                            style: const TextStyle(
                                fontSize: 13, color: Brand.inkSecondary)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: hard ? Brand.accentTint : Brand.successTint,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('$pct% saved',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: hard ? _red : Brand.success)),
                      ),
                    ]),
                  );
                }),
            ]),
    );
  }

  // ------------------------------------------------------------ actions

  Widget _actions() {
    final list = _list('actions');
    return _card(
      'What else they press',
      'Buttons and moments, with how many owners and how many times.',
      list.isEmpty
          ? const Text('Nothing yet.', style: TextStyle(color: Brand.inkMuted))
          : Column(children: [
              for (final a in list)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(children: [
                    Expanded(
                        child: Text(_actionNames['${a['kind']}'] ??
                            '${a['kind']}'.replaceAll('_', ' '))),
                    Text('${a['owners']} owners · ${a['times']} times',
                        style: const TextStyle(
                            fontSize: 12.5, color: Brand.inkSecondary)),
                  ]),
                ),
            ]),
    );
  }

  // ------------------------------------------------------------ people

  Widget _people() {
    final list = _list('people');
    return _card(
      'Owners',
      'Everyone with a space, most recent first. Tap one to see each visit '
          'step by step.',
      Column(children: [
        for (final p in list)
          Builder(builder: (_) {
            final spaces = [
              for (final s in (p['spaces'] as List? ?? const []))
                '${(s as Map)['name']}'
            ];
            final sessions = ((p['sessions'] as num?) ?? 0).toInt();
            final tabs = (p['tabs'] as List? ?? const []).length;
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => OwnerTimelineScreen(
                      email: '${p['email']}',
                      title: spaces.join(', '),
                      days: _days))),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                child: Row(children: [
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(spaces.join(', '),
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text('${p['email']}',
                              style: const TextStyle(
                                  fontSize: 12.5, color: Brand.inkMuted)),
                        ]),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                        sessions == 0
                            ? 'No visits in this period · last ${_ago(p['last_at'])}'
                            : '$sessions visits · ${_dur(p['secs'] as num?)} · '
                                '$tabs tabs · ${p['saves']} saves'
                                '${((p['wishes'] as num?) ?? 0) > 0 ? ' · ${p['wishes']} asked' : ''}'
                                ' · last ${_ago(p['last_at'])}',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: sessions == 0 ? Brand.inkMuted : Brand.inkSecondary)),
                  ),
                  const Icon(Icons.chevron_right, color: Brand.inkMuted),
                ]),
              ),
            );
          }),
      ]),
    );
  }
}

/// One thing an owner asked for, with our answer.
class _WishRow extends StatefulWidget {
  final Map<String, dynamic> w;
  final VoidCallback onSaved;
  const _WishRow({super.key, required this.w, required this.onSaved});
  @override
  State<_WishRow> createState() => _WishRowState();
}

class _WishRowState extends State<_WishRow> {
  final _supabase = SupabaseService();
  late String _status = '${widget.w['status'] ?? 'new'}';
  late final _reply = TextEditingController(text: '${widget.w['reply'] ?? ''}');
  bool _open = false;
  bool _saving = false;
  String? _note;

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_status == 'done' && _reply.text.trim().isEmpty) {
      setState(() => _note =
          'Add a reply first, so they know where to find it.');
      return;
    }
    setState(() {
      _saving = true;
      _note = null;
    });
    try {
      await _supabase.adminOwnerWishUpdate(
          '${widget.w['id']}', _status, _reply.text);
      if (mounted) {
        setState(() => _note = switch (_status) {
              'done' || 'planned' =>
                'Saved. They will see it next time they open their account.',
              'not_now' => 'Saved. Only you see this; they are not told.',
              _ => 'Saved.',
            });
      }
      widget.onSaved();
    } catch (e) {
      if (mounted) setState(() => _note = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.w;
    final trail = [
      for (final t in (w['trail'] as List? ?? const []))
        Map<String, dynamic>.from(t as Map)
    ];
    final seen = w['owner_seen_status'] != null &&
        w['owner_seen_status'] == w['status'];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _status == 'new' ? const Color(0xFFFFF8F8) : Brand.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Brand.hairline),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('"${w['text']}"',
            style: const TextStyle(fontSize: 15, height: 1.45, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(
            '${w['space'] ?? ''} · ${w['email']} · ${_ago(w['created_at'])} · '
            'on ${_tab(w['tab'])} · ${_triggerNames['${w['trigger']}'] ?? w['trigger'] ?? ''}'
            '${seen ? ' · they saw our answer' : ''}',
            style: const TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
        if (trail.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => setState(() => _open = !_open),
              child: Text(_open ? 'Hide what they did just before' : 'What they did just before'),
            ),
          ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final t in trail)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                      '${_dur(t['secs_ago'] as num?)} before:  '
                      '${describe('${t['kind']}', (t['detail'] as Map?) ?? const {})}',
                      style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
                ),
            ]),
          ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final s in const [
            ('new', 'New'),
            ('planned', 'Planned'),
            ('done', 'Done'),
            ('not_now', 'Not now'),
          ])
            ChoiceChip(
              label: Text(s.$2),
              selected: _status == s.$1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              onSelected: (_) => setState(() {
                _status = s.$1;
                _note = null;
              }),
            ),
        ]),
        const SizedBox(height: 10),
        TextField(
          controller: _reply,
          minLines: 1,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: switch (_status) {
              'done' =>
                'Needed: where to find it, e.g. "Holiday hours are now under Opening hours in My listing."',
              'planned' =>
                "Optional: they'll see \"We're working on what you asked for\" with this note.",
              'not_now' => 'A note for us only. They are not told.',
              _ => 'Choose Planned, Done or Not now first.',
            },
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Brand.border)),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
                backgroundColor: Brand.red,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: Text(_saving ? 'Saving...' : 'Save'),
          ),
          const SizedBox(width: 12),
          if (_note != null)
            Expanded(
                child: Text(_note!,
                    style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary))),
        ]),
      ]),
    );
  }
}

/// One owner's visits, newest first, each step in plain words.
class OwnerTimelineScreen extends StatefulWidget {
  final String email;
  final String title;
  final int days;
  const OwnerTimelineScreen(
      {required this.email, required this.title, required this.days});
  @override
  State<OwnerTimelineScreen> createState() => OwnerTimelineScreenState();
}

class OwnerTimelineScreenState extends State<OwnerTimelineScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _visits;
  String? _error;

  @override
  void initState() {
    super.initState();
    _supabase.adminOwnerTimeline(widget.email, widget.days).then((v) {
      if (mounted) setState(() => _visits = v);
    }).catchError((e) {
      if (mounted) {
        setState(() {
          _visits = [];
          _error = 'Could not load: $e';
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final visits = _visits;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: Text(widget.title.isEmpty ? widget.email : widget.title)),
      body: visits == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(widget.email,
                              style: const TextStyle(color: Brand.inkMuted)),
                          const SizedBox(height: 12),
                          if (_error != null)
                            Text(_error!, style: const TextStyle(color: _red))
                          else if (visits.isEmpty)
                            Text('No visits in the last ${widget.days} days.',
                                style: const TextStyle(color: Brand.inkMuted)),
                          for (final s in visits) _visit(s),
                        ]),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _visit(Map<String, dynamic> s) {
    final start = DateTime.tryParse('${s['started_at']}')?.toLocal();
    final end = DateTime.tryParse('${s['last_at']}')?.toLocal();
    final steps = [
      for (final x in (s['steps'] as List? ?? const []))
        Map<String, dynamic>.from(x as Map)
    ];
    final len = start == null || end == null ? 0 : end.difference(start).inSeconds;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
            start == null
                ? 'Visit'
                : DateFormat('EEE d MMM, HH:mm').format(start),
            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
        Text(
            '${_dur(len)} · ${s['device'] ?? ''}${s['width'] != null ? ' (${s['width']} px wide)' : ''}'
            ' · from ${s['came_from'] ?? 'direct'}${s['team'] == true ? ' · our own visit' : ''}',
            style: const TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
        const SizedBox(height: 10),
        for (final st in steps)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 64,
                child: Text(
                    () {
                      final t = DateTime.tryParse('${st['at']}')?.toLocal();
                      return t == null ? '' : DateFormat('HH:mm:ss').format(t);
                    }(),
                    style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
              ),
              Expanded(
                child: Text(
                    describe('${st['kind']}', (st['detail'] as Map?) ?? const {}) +
                        (st['space'] != null && '${st['kind']}' == 'space'
                            ? ': ${st['space']}'
                            : ''),
                    style: TextStyle(
                        fontSize: 13.5,
                        height: 1.4,
                        color: '${st['kind']}' == 'wish_sent' ||
                                '${st['kind']}' == 'edit_cancel'
                            ? _red
                            : Brand.ink)),
              ),
            ]),
          ),
      ]),
    );
  }
}
