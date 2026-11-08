import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import 'admin_outreach_screen.dart';
import 'admin_owner_activity_screen.dart';
import 'owner_screen.dart';
import 'space_trail_screen.dart';

/// Control centre: Spaces, one overview per space (migration 285).
///
/// Jonathan, 8 Nov 2026: "a crm style where I can easily pull up the
/// overview on a space as quickly and easy as possible, and have a full
/// overview, and status on where they are at in terms of if claimed,
/// not reached out to yet, claimed but dormant, and all the info
/// available".
///
/// [AdminSpacesScreen] lists every page live on nomadwise.io with its
/// status: type a few letters to find one. [SpaceProfileScreen] is the
/// space's overview: where they are, plan, numbers, every way in, their
/// use of the Owner account, what they asked for, Outreach and every
/// message, claims, with buttons to their page, their Owner account (as
/// they see it), Outreach and the full history.

const _red = Color(0xFFD42F3A);

/// Status: (label, text colour, background).
const _statuses = <String, (String, Color, Color)>{
  'claimed_active': ('Claimed · active', Brand.success, Brand.successTint),
  'claimed_dormant': ('Claimed · dormant', Brand.goldTextDark, Brand.goldTint),
  'claimed_never': ('Claimed · never logged in', Brand.goldTextDark, Brand.goldTint),
  'ours': ('Premium by us · not claimed', Brand.ink, Brand.field),
  'replied': ('They wrote back: answer them', _red, Brand.accentTint),
  'looked': ('Opened claim page', _red, Brand.accentTint),
  'written': ('Written to · waiting', Brand.inkSecondary, Brand.field),
  'not_reached': ('Not reached yet', Brand.ink, Brand.field),
  'no_way_in': ('No way in yet', Brand.inkMuted, Brand.field),
  // What really happened (Jonathan, 8 Nov 2026: "which one said no ...
  // and which ones just didn't respond"). Put aside is our choice, not
  // their answer.
  'put_aside': ('Put aside by us', Brand.inkSecondary, Brand.field),
  'declined': ('Said no', Brand.inkMuted, Brand.field),
  'unsubscribed': ('Unsubscribed', Brand.inkMuted, Brand.field),
  'bounced': ('Email bounced', Brand.inkMuted, Brand.field),
  'not_for_outreach': ('Not for outreach', Brand.inkMuted, Brand.field),
  'closed': ('Closed on Google', Brand.inkMuted, Brand.field),
  'not_live': ('Not on the site', Brand.inkMuted, Brand.field),
};

Widget _chip(String text, Color fg, Color bg) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(text,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
    );

Widget statusChip(Object? status) {
  final s = _statuses['$status'] ?? ('$status', Brand.inkSecondary, Brand.field);
  return _chip(s.$1, s.$2, s.$3);
}

String _ago(Object? iso) {
  final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  if (t == null) return '';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 2) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays == 1) return 'yesterday';
  if (d.inDays < 30) return '${d.inDays} days ago';
  return 'on ${DateFormat('d MMM yyyy').format(t)}';
}

String _date(Object? iso) {
  final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  return t == null ? '' : DateFormat('d MMM yyyy').format(t);
}

Future<void> openSpaceProfile(BuildContext context, String venueId, String name) async {
  await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SpaceProfileScreen(venueId: venueId, name: name)));
}

// ====================================================================
// The list

class AdminSpacesScreen extends StatefulWidget {
  const AdminSpacesScreen({super.key});
  @override
  State<AdminSpacesScreen> createState() => _AdminSpacesScreenState();
}

class _AdminSpacesScreenState extends State<AdminSpacesScreen> {
  final _supabase = SupabaseService();
  final _search = TextEditingController();
  List<Map<String, dynamic>>? _rows;
  String? _error;
  String _q = '';
  String _status = '';
  String _kind = '';
  int _shown = 60;

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
    try {
      final rows = await _supabase.adminSpaces();
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
          _error = '$e'.contains('admin_spaces')
              ? 'Not installed yet: migration 285 has not run. Check the last build on GitHub.'
              : 'Could not load: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: const Text('Spaces'), actions: [
        IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
      ]),
      body: rows == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000),
                      child: _error != null
                          ? Text(_error!, style: const TextStyle(color: _red))
                          : _body(rows),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _body(List<Map<String, dynamic>> all) {
    final words =
        _q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    String hay(Map<String, dynamic> r) => [
          r['name'], r['city'], r['country'], r['email'], r['owner_email'], r['owner_name'],
          r['phone'], r['instagram'], r['facebook'], r['website'],
        ].where((x) => x != null).join(' ').toLowerCase();
    final byKind = all.where((r) => _kind.isEmpty || '${r['kind']}' == _kind).toList();
    final counts = <String, int>{};
    for (final r in byKind) {
      counts['${r['status']}'] = (counts['${r['status']}'] ?? 0) + 1;
    }
    final list = byKind.where((r) {
      if (_status.isNotEmpty && '${r['status']}' != _status) return false;
      if (words.isEmpty) return true;
      final h = hay(r);
      return words.every(h.contains);
    }).toList();

    // On a phone (Jonathan, 8 Nov 2026): no keyboard popping up on
    // opening, status and type as two short lists on one line, tighter
    // rows.
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _search,
        autofocus: !narrow,
        onChanged: (v) => setState(() {
          _q = v;
          _shown = 60;
        }),
        decoration: InputDecoration(
          hintText: 'Find a space: name, place, email, owner, phone, Instagram or Facebook',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _q.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                        _search.clear();
                        _q = '';
                      })),
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Brand.border)),
        ),
      ),
      const SizedBox(height: 12),
      if (narrow)
        Row(children: [
          Expanded(
            child: _dropdown(
              _status.isEmpty
                  ? 'Everyone (${byKind.length})'
                  : '${_statuses[_status]?.$1 ?? _status} (${counts[_status] ?? 0})',
              [
                ('', 'Everyone (${byKind.length})'),
                for (final e in _statuses.entries)
                  if ((counts[e.key] ?? 0) > 0) (e.key, '${e.value.$1} (${counts[e.key]})'),
              ],
              (k) => setState(() => _status = k),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _dropdown(
              switch (_kind) { 'coworking' => 'Coworking', 'cafe' => 'Cafes', _ => 'All types' },
              const [('', 'All types'), ('coworking', 'Coworking'), ('cafe', 'Cafes')],
              (k) => setState(() => _kind = k),
            ),
          ),
        ]),
      if (!narrow) ...[
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final k in const [('', 'All types'), ('coworking', 'Coworking'), ('cafe', 'Cafes')])
          ChoiceChip(
            label: Text(k.$2),
            selected: _kind == k.$1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            onSelected: (_) => setState(() => _kind = k.$1),
          ),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        ChoiceChip(
          label: Text('Everyone (${byKind.length})'),
          selected: _status.isEmpty,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          onSelected: (_) => setState(() => _status = ''),
        ),
        for (final e in _statuses.entries)
          if ((counts[e.key] ?? 0) > 0)
            ChoiceChip(
              label: Text('${e.value.$1} (${counts[e.key]})'),
              selected: _status == e.key,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              onSelected: (_) => setState(() => _status = _status == e.key ? '' : e.key),
            ),
      ]),
      ],
      SizedBox(height: narrow ? 10 : 14),
      Text(
          list.isEmpty
              ? 'Nothing matches.'
              : '${list.length} ${list.length == 1 ? 'space' : 'spaces'}, most visited first',
          style: const TextStyle(fontSize: 13, color: Brand.inkSecondary)),
      const SizedBox(height: 8),
      if (list.isNotEmpty)
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Brand.border),
          ),
          child: Column(children: [
            for (final (i, r) in list.take(_shown).indexed) ...[
              if (i > 0) const Divider(height: 1, color: Brand.hairline),
              narrow ? _rowNarrow(r) : _row(r),
            ],
          ]),
        ),
      if (list.length > _shown)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => _shown += 100),
            child: Text('Show more (${list.length - _shown} left)'),
          ),
        ),
    ]);
  }

  /// A short list that opens from a button, for the phone's one-line
  /// filters.
  Widget _dropdown(String label, List<(String, String)> items, void Function(String) pick) =>
      PopupMenuButton<String>(
        onSelected: pick,
        position: PopupMenuPosition.under,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        itemBuilder: (_) => [
          for (final it in items) PopupMenuItem(value: it.$1, child: Text(it.$2)),
        ],
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFCBD2D9)),
          ),
          child: Row(children: [
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            ),
            const Icon(Icons.expand_more, size: 18, color: Brand.inkSecondary),
          ]),
        ),
      );

  /// A space on a phone: its name, then a coloured dot with its status
  /// and place on one line.
  Widget _rowNarrow(Map<String, dynamic> r) {
    final st = _statuses['${r['status']}'] ?? ('${r['status']}', Brand.inkSecondary, Brand.field);
    final place = '${r['city'] ?? ''}'.trim().isNotEmpty
        ? '${r['city']}'.trim()
        : '${r['country'] ?? ''}'.trim();
    final color = st.$2 == Brand.inkMuted ? Brand.inkSecondary : st.$2;
    return InkWell(
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => SpaceProfileScreen(venueId: '${r['id']}', name: '${r['name']}')));
        _load();
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${r['name']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: '● ${st.$1}', style: TextStyle(color: color)),
                  TextSpan(
                      text: [
                        if (place.isNotEmpty) place,
                        if (r['plan'] == 'premium') 'Premium',
                      ].map((x) => ' · $x').join(),
                      style: const TextStyle(color: Brand.inkMuted)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5),
              ),
            ]),
          ),
          const Icon(Icons.chevron_right, color: Brand.inkMuted),
        ]),
      ),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final place = [
      if ('${r['city'] ?? ''}'.trim().isNotEmpty) '${r['city']}'.trim(),
      if ('${r['country'] ?? ''}'.trim().isNotEmpty) '${r['country']}'.trim(),
    ].join(', ');
    final claimed = r['owner_email'] != null;
    final sub = [
      r['kind'] == 'cafe' ? 'Cafe' : 'Coworking',
      if (place.isNotEmpty) place,
      '${r['views'] ?? 0} views in 90 days',
      if (claimed && r['owner_seen_at'] != null) 'in ${_ago(r['owner_seen_at'])}',
      if (!claimed && r['written_at'] != null) 'written to ${_ago(r['written_at'])}',
    ].join(' · ');
    return InkWell(
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => SpaceProfileScreen(venueId: '${r['id']}', name: '${r['name']}')));
        _load();
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 11, 10, 11),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${r['name']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                statusChip(r['status']),
                if (r['plan'] == 'premium') _chip('Premium', Brand.success, Brand.successTint),
              ]),
            ]),
          ),
          const Icon(Icons.chevron_right, color: Brand.inkMuted),
        ]),
      ),
    );
  }
}

// ====================================================================
// One space

class SpaceProfileScreen extends StatefulWidget {
  final String venueId;
  final String name;
  const SpaceProfileScreen({super.key, required this.venueId, required this.name});
  @override
  State<SpaceProfileScreen> createState() => _SpaceProfileScreenState();
}

class _SpaceProfileScreenState extends State<SpaceProfileScreen> {
  final _supabase = SupabaseService();
  Map<String, dynamic>? _p;
  String? _error;
  final Set<int> _openMsg = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await _supabase.adminSpaceProfile(widget.venueId);
      if (mounted) {
        setState(() {
          _p = p;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _p = {};
          _error = '$e'.contains('admin_space_profile')
              ? 'Not installed yet: migration 285 has not run. Check the last build on GitHub.'
              : 'Could not load: $e';
        });
      }
    }
  }

  List<Map<String, dynamic>> _list(String k) => [
        for (final x in (_p?[k] as List? ?? const [])) Map<String, dynamic>.from(x as Map)
      ];

  Future<void> _go(Uri u) =>
      launchUrl(u, mode: LaunchMode.externalApplication).catchError((_) => false);

  Future<void> _push(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: Text(widget.name), actions: [
        IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
      ]),
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: _error != null
                          ? Text(_error!, style: const TextStyle(color: _red))
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _header(p),
                                _where(p),
                                _numbers(p),
                                _waysIn(p),
                                if (p['owner'] is Map) _owner(p),
                                if (_list('wishes').isNotEmpty) _wishes(),
                                _outreach(p),
                                if (_list('claims').isNotEmpty) _claims(),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _card(String title, List<Widget> children, {Widget? trailing}) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Brand.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
                child: Text(title,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
            if (trailing != null) trailing,
          ]),
          const SizedBox(height: 10),
          ...children,
        ]),
      );

  Widget _fact(String label, String value) => value.trim().isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 150,
                child: Text(label,
                    style: const TextStyle(fontSize: 13, color: Brand.inkMuted))),
            Expanded(child: Text(value, style: const TextStyle(fontSize: 14, height: 1.35))),
          ]),
        );

  Widget _header(Map<String, dynamic> p) {
    final place = [
      '${p['neighbourhood'] ?? ''}'.trim(),
      '${p['city'] ?? ''}'.trim(),
      '${p['country'] ?? ''}'.trim(),
    ].where((x) => x.isNotEmpty).join(', ');
    final slug = '${p['slug'] ?? ''}'.trim();
    final owner = '${p['owner_email'] ?? ''}'.trim();
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${p['name'] ?? widget.name}',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text('${p['kind'] == 'cafe' ? 'Cafe' : 'Coworking'}${place.isEmpty ? '' : ' · $place'}',
            style: const TextStyle(fontSize: 14, color: Brand.inkSecondary)),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          statusChip(p['status']),
          p['plan'] == 'premium'
              ? _chip('Premium${p['paying'] == true ? ' · paying' : ''}', Brand.success, Brand.successTint)
              : _chip('Free', Brand.inkSecondary, Brand.field),
          if (p['assigned_to'] != null)
            _chip('With ${p['assigned_to']}', Brand.inkSecondary, Brand.field),
        ]),
        const SizedBox(height: 12),
        _nowBox(_now(p)),
        const SizedBox(height: 12),
        // Three buttons the same width (Jonathan, 8 Nov 2026, mock-up E):
        // the main one, their page, and More for the rest.
        Row(children: [
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Brand.red,
                  minimumSize: const Size(0, 46),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  shape: shape),
              onPressed: () => owner.isNotEmpty
                  ? _push(OwnerScreen(previewKey: widget.venueId))
                  : _push(AdminOutreachScreen(initialQuery: '${p['name']}')),
              child: Text(owner.isNotEmpty ? 'Owner account' : 'Write to them',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 46),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  shape: shape),
              onPressed: slug.isEmpty
                  ? null
                  : () => _go(Uri.parse('https://www.nomadwise.io/coworking/$slug')),
              child: const Text('Their page', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: PopupMenuButton<String>(
              tooltip: 'More',
              position: PopupMenuPosition.under,
              shape: shape,
              onSelected: (k) => switch (k) {
                'outreach' => _push(AdminOutreachScreen(initialQuery: '${p['name']}')),
                'account' => _push(OwnerScreen(previewKey: widget.venueId)),
                'visits' => _push(OwnerTimelineScreen(email: owner, title: '${p['name']}', days: 90)),
                _ => _push(SpaceTrailScreen(venueId: widget.venueId, name: '${p['name']}')),
              },
              itemBuilder: (_) => [
                if (owner.isNotEmpty) const PopupMenuItem(value: 'outreach', child: Text('Outreach')),
                if (owner.isEmpty)
                  const PopupMenuItem(value: 'account', child: Text('Their Owner account')),
                if (owner.isNotEmpty) const PopupMenuItem(value: 'visits', child: Text('Their visits')),
                const PopupMenuItem(value: 'history', child: Text('Full history')),
              ],
              child: Container(
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFCBD2D9)),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('More', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  Icon(Icons.expand_more, size: 18),
                ]),
              ),
            ),
          ),
        ]),
      ]),
    );
  }

  /// NOW: what is going on and whether anything needs doing, at the top.
  Widget _nowBox((String, bool) now) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: now.$2 ? Brand.goldTint : Brand.bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(now.$2 ? Icons.arrow_forward : Icons.check,
              size: 18, color: now.$2 ? Brand.goldTextDark : Brand.success),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(now.$2 ? 'NOW: SOMETHING TO DO' : 'NOW: NOTHING TO DO',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .6,
                      color: now.$2 ? Brand.goldTextDark : Brand.success)),
              const SizedBox(height: 3),
              Text(now.$1, style: const TextStyle(fontSize: 14, height: 1.45)),
            ]),
          ),
        ]),
      );

  /// Where they are, in a sentence, and the main facts.
  Widget _where(Map<String, dynamic> p) {
    final who = [
      '${p['owner_name'] ?? ''}'.trim(),
      if ('${p['owner_email'] ?? ''}'.trim().isNotEmpty) '(${p['owner_email']})',
    ].where((x) => x.isNotEmpty).join(' ');
    final ways = [
      if (p['email'] != null) 'email',
      if (p['phone'] != null) 'WhatsApp',
      if (p['form'] != null) 'their contact form',
      if (p['instagram'] != null) 'Instagram',
      if (p['facebook'] != null) 'Facebook',
    ];
    final sentence = switch ('${p['status']}') {
      'claimed_active' => 'Claimed by $who. In their Owner account ${_ago(p['owner_seen_at'])}.',
      'claimed_dormant' =>
        'Claimed by $who. Last in their Owner account ${_ago(p['owner_seen_at'])}: dormant.',
      'claimed_never' => 'Claimed by $who, but has never opened their Owner account.',
      'ours' => 'Premium, set up by us. Nobody has claimed it yet.',
      'replied' => 'They wrote back ${_ago(p['replied_at'])} and are waiting for our answer. '
          'Answer them, then move the card on in Outreach.',
      'looked' => 'Someone opened their claim page ${_ago(p['looked_at'])} and stopped. '
          'Ask if they have any questions.',
      'written' => 'Written to ${_ago(p['written_at'])}, no answer yet.',
      'not_reached' => ways.isEmpty
          ? 'Not reached yet. They have a website: find an address on it.'
          : 'Not reached yet. Ways in: ${ways.join(', ')}.',
      'no_way_in' => 'No way in yet: no email, phone, Instagram, Facebook or website.',
      'put_aside' => 'Put aside by us${_date(p['stage_at']).isEmpty ? '' : ' on ${_date(p['stage_at'])}'}'
          '${p['written_at'] == null ? ', before anyone wrote to them' : ''}. '
          'This is not their answer: they have not said no. '
          '${ways.isEmpty ? '' : 'Ways in now: ${ways.join(', ')}. '}'
          'To write to them, open Outreach and press Bring back.',
      'declined' => 'They said no${_date(p['stage_at']).isEmpty ? '' : ' (marked ${_date(p['stage_at'])})'}. '
          'Their messages are under Outreach below.',
      'unsubscribed' => 'They asked us not to write'
          '${_date(p['unsubscribed_at'] ?? p['stage_at']).isEmpty ? '' : ' on ${_date(p['unsubscribed_at'] ?? p['stage_at'])}'}. '
          'We never write to them again.',
      'bounced' => 'Our email bounced: the address did not work. Find another way in.',
      'not_for_outreach' => 'Set aside as not for outreach'
          '${'${p['aside_reason'] ?? ''}'.isEmpty ? '' : ': ${p['aside_reason']}'}.',
      'closed' => 'Google lists this place as closed for good. Check it in Quality.',
      _ => 'Not on the site.',
    };
    final page = p['page'] is Map ? p['page'] as Map : null;
    final draft = p['draft'] is Map ? p['draft'] as Map : null;
    final claims = _list('claims');
    return _card('Where they are', [
      Text(sentence, style: const TextStyle(fontSize: 15, height: 1.45, fontWeight: FontWeight.w600)),
      const SizedBox(height: 10),
      _fact('On nomadwise.io since', _date(p['listed_at'])),
      _fact('Claimed', claims.isEmpty ? '' : _date(claims.first['approved_at'] ?? claims.first['at'])),
      _fact('Plan', p['plan'] == 'premium'
          ? 'Premium${p['paying'] == true ? ', paying' : ', not paying (set up by us)'}'
              '${p['renews_at'] != null ? ', renews ${_date(p['renews_at'])}' : ''}'
          : 'Free'),
      _fact('Page complete', page == null ? '' : '${page['done']} of ${page['total']} parts'),
      _fact('Changes', draft == null
          ? ''
          : switch ('${draft['status']}') {
              'submitted' => 'Waiting for our review since ${_date(draft['submitted_at'] ?? draft['at'])}',
              'declined' => 'Sent back ${_date(draft['at'])}',
              'applied' => 'Last changes put on ${_date(draft['at'])}',
              _ => 'Draft saved ${_date(draft['at'])}',
            }),
      _fact('Closed until', _date(p['closed_until'])),
    ]);
  }

  Widget _numbers(Map<String, dynamic> p) {
    final n = p['numbers'] is Map ? Map<String, dynamic>.from(p['numbers'] as Map) : {};
    final stats = <(String, String)>[
      ('${n['views_30'] ?? 0}', 'page views, 30 days'),
      ('${n['views_90'] ?? 0}', 'page views, 90 days'),
      ('${n['google_30'] ?? 0}', 'shown in Google, 30 days'),
      ('${n['requests_30'] ?? 0}', 'requests, 30 days (${n['requests_all'] ?? 0} in all)'),
      if (p['rating'] != null) ('${p['rating']}', 'Google, ${p['reviews'] ?? 0} reviews'),
    ];
    // A compact strip: three across on a phone (mock-up E).
    return _card('Numbers', [
      LayoutBuilder(builder: (context, box) {
        final narrow = box.maxWidth < 520;
        final w = narrow ? (box.maxWidth - 16) / 3 : 150.0;
        return Wrap(spacing: 8, runSpacing: 8, children: [
          for (final st in stats)
            Container(
              width: w,
              padding: EdgeInsets.all(narrow ? 10 : 12),
              decoration: BoxDecoration(color: Brand.bg, borderRadius: BorderRadius.circular(8)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(st.$1,
                    style: TextStyle(fontSize: narrow ? 18 : 20, fontWeight: FontWeight.w800)),
                Text(st.$2,
                    style: TextStyle(fontSize: narrow ? 11.5 : 12, color: Brand.inkSecondary)),
              ]),
            ),
        ]);
      }),
    ]);
  }

  Widget _waysIn(Map<String, dynamic> p) {
    Widget way(IconData icon, String label, String value, Uri? link) => InkWell(
          onTap: link == null ? null : () => _go(link),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
            child: Row(children: [
              Icon(icon, size: 18, color: Brand.inkSecondary),
              const SizedBox(width: 10),
              SizedBox(
                  width: 120,
                  child: Text(label, style: const TextStyle(fontSize: 13, color: Brand.inkMuted))),
              Expanded(
                child: Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14,
                        color: link == null ? Brand.ink : _red,
                        fontWeight: link == null ? FontWeight.w400 : FontWeight.w600)),
              ),
            ]),
          ),
        );
    Uri? web(Object? raw) {
      final t = '${raw ?? ''}'.trim();
      if (t.isEmpty) return null;
      if (!t.contains('/') && !t.contains('.')) {
        return Uri.tryParse('https://www.instagram.com/${t.replaceAll('@', '')}');
      }
      return Uri.tryParse(t.contains('://') ? t : 'https://$t');
    }

    String short(Object? raw) =>
        '${raw ?? ''}'.trim().replaceFirst(RegExp(r'^https?://(www\.)?'), '');
    final emails = <String>{
      if (p['email'] != null) '${p['email']}',
      for (final e in (p['contact_emails'] as List? ?? const [])) '$e',
    }.toList();
    final phone = '${p['phone'] ?? ''}'.trim();
    final rows = <Widget>[
      if ('${p['owner_email'] ?? ''}'.isNotEmpty)
        way(Icons.person_outline, 'Owner', '${p['owner_name'] ?? ''} ${p['owner_email']}'.trim(),
            Uri(scheme: 'mailto', path: '${p['owner_email']}')),
      if ('${p['enquiry_email'] ?? ''}'.isNotEmpty && p['enquiry_email'] != p['owner_email'])
        way(Icons.inbox_outlined, 'Requests go to', '${p['enquiry_email']}',
            Uri(scheme: 'mailto', path: '${p['enquiry_email']}')),
      for (final e in emails)
        way(Icons.mail_outline, 'Email', e, Uri(scheme: 'mailto', path: e)),
      if (phone.isNotEmpty)
        way(Icons.chat_outlined, 'WhatsApp', phone,
            Uri.tryParse('https://wa.me/${phone.replaceAll(RegExp(r'[^0-9]'), '')}')),
      if (p['form'] != null) way(Icons.assignment_outlined, 'Contact form', short(p['form']), web(p['form'])),
      if (p['instagram'] != null)
        way(Icons.photo_camera_outlined, 'Instagram', short(p['instagram']), web(p['instagram'])),
      if (p['facebook'] != null)
        way(Icons.thumb_up_alt_outlined, 'Facebook', short(p['facebook']), web(p['facebook'])),
      if ('${p['website'] ?? ''}'.trim().isNotEmpty)
        way(Icons.language, 'Website', short(p['website']), web(p['website'])),
    ];
    return _card('Ways in', rows.isEmpty
        ? [const Text('Nothing known yet.', style: TextStyle(color: Brand.inkMuted))]
        : rows);
  }

  Widget _owner(Map<String, dynamic> p) {
    final o = Map<String, dynamic>.from(p['owner'] as Map);
    final recent = [
      for (final x in (o['recent'] as List? ?? const [])) Map<String, dynamic>.from(x as Map)
    ];
    return _card('Their Owner account', [
      _fact('Days they came in', '${o['days_in'] ?? 0}'),
      _fact('First in', _date(o['first_in'])),
      _fact('Last in', o['last_in'] == null ? 'Never' : _ago(o['last_in'])),
      _fact('Visits, 30 days', '${o['visits_30'] ?? 0}'),
      _fact('Parts saved, 30 days', '${o['saves_30'] ?? 0}'),
      if (recent.isNotEmpty) ...[
        const SizedBox(height: 10),
        const Text('Latest steps',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Brand.inkMuted)),
        const SizedBox(height: 4),
        for (final s in recent)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
                '${_ago(s['at'])}:  ${describe('${s['kind']}', (s['detail'] as Map?) ?? const {})}',
                style: const TextStyle(fontSize: 13, color: Brand.inkSecondary, height: 1.4)),
          ),
      ],
    ]);
  }

  Widget _wishes() => _card('What they asked for', [
        for (final w in _list('wishes'))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('"${w['text']}"',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.4)),
              Text(
                  '${_ago(w['at'])} · ${switch ('${w['status']}') {
                    'planned' => 'Planned',
                    'done' => 'Done',
                    'not_now' => 'Not now',
                    _ => 'New',
                  }}${'${w['reply'] ?? ''}'.isNotEmpty ? ' · our reply: ${w['reply']}' : ''}',
                  style: const TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
            ]),
          ),
      ]);

  /// What our outreach means right now, and whether anything needs doing
  /// (Jonathan, 8 Nov 2026: "what does that mean right now ... Do I need
  /// to do anything? Do I not need to do anything?"). Nothing is sent by
  /// itself: a follow-up only happens when one of us sends it.
  (String, bool) _now(Map<String, dynamic> p) {
    final contacts = _list('contacts');
    final msgs = _list('messages');
    final out = DateTime.tryParse('${p['written_at'] ?? ''}')?.toLocal();
    final inn = DateTime.tryParse('${p['replied_at'] ?? ''}')?.toLocal();
    final looked = DateTime.tryParse('${p['looked_at'] ?? ''}')?.toLocal();
    final follow = DateTime.tryParse(
        '${contacts.map((c) => c['follow_up_on']).firstWhere((x) => x != null, orElse: () => '')}');
    final lastOut = msgs.firstWhere((m) => m['direction'] == 'out', orElse: () => {});
    final via = '${lastOut['subject'] ?? ''}';
    final channel = const {'WhatsApp', 'Instagram', 'Facebook', 'Contact form'}.contains(via)
        ? ' on $via'
        : ' by email';
    final status = '${p['status']}';
    if (status.startsWith('claimed')) {
      return ('They have claimed their page: no outreach needed. Help them get the most from it.', false);
    }
    if (out == null) {
      return ('Nobody has written to them yet.${status == 'not_reached' ? ' Their next step is in the Claim plan.' : ''}', status == 'not_reached');
    }
    final days = DateTime.now().difference(out).inDays;
    final when = days == 0 ? 'today' : days == 1 ? 'yesterday' : '$days days ago';
    if (inn != null && inn.isAfter(out)) {
      return ('They wrote back ${_ago(p['replied_at'])}. Next: answer them, then log your answer in Outreach.', true);
    }
    if (looked != null && looked.isAfter(out)) {
      return ('We wrote $when$channel, and since then someone opened their claim page but did not '
          'finish. Next: a short note asking if they have any questions (Outreach has it ready).', true);
    }
    if (follow != null) {
      final due = !follow.isAfter(DateTime.now());
      return (due
          ? 'We wrote $when$channel. No answer yet, and the follow-up date (${_date(follow.toIso8601String())}) '
              'has come. Next: send the follow-up.'
          : 'We wrote $when$channel. No answer yet. A follow-up is planned for '
              '${_date(follow.toIso8601String())}: nothing to do until then.', due);
    }
    if (days < 7) {
      return ('We wrote $when$channel. No answer yet. Nothing to do for now: give them a week.', false);
    }
    return ('We wrote $when$channel and have had no answer. No follow-up is planned, and nothing '
        'is sent by itself. Next: one short nudge$channel, or leave it. (In Outreach, '
        '"Note and follow-up date" lets you plan one.)', true);
  }

  Widget _outreach(Map<String, dynamic> p) {
    final contacts = _list('contacts');
    final msgs = _list('messages');
    return _card('Outreach', [
      if (contacts.isEmpty)
        const Text('No Outreach card yet.', style: TextStyle(color: Brand.inkMuted)),
      for (final c in contacts) ...[
        _fact('Stage', '${c['stage'] ?? ''}'.replaceAll('_', ' ')),
        _fact('Person', '${c['person'] ?? ''}'),
        _fact('Last written to', _date(c['written_at'])),
        _fact('Last reply', _date(c['replied_at'])),
        _fact('Follow up on', _date(c['follow_up_on'])),
        _fact('With', '${c['assigned_to'] ?? ''}'),
        _fact('Notes', '${c['notes'] ?? ''}'),
        if (contacts.length > 1) const Divider(color: Brand.hairline),
      ],
      if (msgs.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text('Messages (${msgs.length}${msgs.length == 40 ? '+' : ''})',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Brand.inkMuted)),
        const SizedBox(height: 4),
        for (final (i, m) in msgs.indexed)
          InkWell(
            onTap: () => setState(() => _openMsg.contains(i) ? _openMsg.remove(i) : _openMsg.add(i)),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(m['direction'] == 'in' ? Icons.call_received : Icons.call_made,
                    size: 16, color: m['direction'] == 'in' ? _red : Brand.inkMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                        '${m['direction'] == 'in' ? 'They wrote' : 'We sent'} · ${_date(m['at'])}'
                        '${'${m['subject'] ?? ''}'.isNotEmpty ? ' · ${m['subject']}' : ''}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    Text('${m['body'] ?? ''}',
                        maxLines: _openMsg.contains(i) ? null : 2,
                        overflow: _openMsg.contains(i) ? null : TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: Brand.inkSecondary, height: 1.4)),
                  ]),
                ),
              ]),
            ),
          ),
      ],
    ]);
  }

  Widget _claims() => _card('Claims', [
        for (final c in _list('claims'))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
                '${_date(c['at'])}: ${c['owner_name'] ?? ''}'
                '${'${c['owner_role'] ?? ''}'.isNotEmpty ? ' (${c['owner_role']})' : ''}, '
                '${c['owner_email'] ?? ''}, ${c['plan'] ?? ''}'
                '${c['approved_at'] != null ? ', approved ${_date(c['approved_at'])}' : ', not approved yet'}',
                style: const TextStyle(fontSize: 13.5, height: 1.4)),
          ),
      ]);
}
