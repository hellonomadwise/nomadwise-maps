import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Admin only: the whole back and forth with one space's owner,
/// newest first. Claims, approval, each submission of changes, notes
/// sent back, changes put on the page, visitors' suggested updates and
/// every email we sent, each one opening to its full text.
class SpaceTrailScreen extends StatefulWidget {
  final String venueId;
  final String name;
  const SpaceTrailScreen({super.key, required this.venueId, required this.name});
  @override
  State<SpaceTrailScreen> createState() => _SpaceTrailScreenState();
}

class _SpaceTrailScreenState extends State<SpaceTrailScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _rows;
  String? _error;
  final Set<int> _open = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _supabase.adminSpaceTrail(widget.venueId);
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
          _error = '$e'.contains('admin_space_trail')
              ? 'The history is not installed yet: migration 101 has not '
                  'run. Check the last build on GitHub.'
              : 'Could not load the history: $e';
        });
      }
    }
  }

  static (IconData, Color) _look(String kind) => switch (kind) {
        'claim' => (Icons.flag_outlined, Brand.ink),
        'approved' => (Icons.verified_outlined, Brand.success),
        'draft_submitted' => (Icons.edit_note, Brand.accent),
        'draft_declined' => (Icons.reply, Brand.goldTextDark),
        'draft_applied' => (Icons.check_circle_outline, Brand.success),
        'email' => (Icons.mail_outline, Brand.inkSecondary),
        'suggested' => (Icons.lightbulb_outline, Brand.goldTextDark),
        _ => (Icons.circle_outlined, Brand.inkMuted),
      };

  /// What an owner submitted, as readable lines.
  static String _draftText(Map d) {
    String s(dynamic x) => (x ?? '').toString().trim();
    final lines = <String>[];
    if (s(d['description']).isNotEmpty) lines.add('Description:\n${s(d['description'])}');
    final p = (d['prices'] is Map) ? d['prices'] as Map : const {};
    final prices = [
      if (s(p['day']).isNotEmpty) 'Day pass ${s(p['day'])}',
      if (s(p['week']).isNotEmpty) 'Week pass ${s(p['week'])}',
      if (s(p['month']).isNotEmpty) 'Month pass ${s(p['month'])}',
      if (s(p['coffee']).isNotEmpty) 'Cappuccino ${s(p['coffee'])}',
    ];
    if (prices.isNotEmpty) lines.add('Prices: ${prices.join(', ')}');
    final h = (d['hours'] is Map) ? d['hours'] as Map : const {};
    if (h.isNotEmpty) {
      lines.add('Hours: ${h.entries.map((e) => '${e.key} ${e.value}').join(', ')}');
    }
    final f = (d['facts'] is Map) ? d['facts'] as Map : const {};
    final on = f.entries.where((e) => e.value == true).map((e) => e.key).toList();
    if (on.isNotEmpty) lines.add('Facts: ${on.join(', ').replaceAll('_', ' ')}');
    for (final k in ['website', 'instagram', 'whatsapp', 'enquiry_email']) {
      if (s(d[k]).isNotEmpty) lines.add('${k.replaceAll('_', ' ')}: ${s(d[k])}');
    }
    final photos = (d['photos'] is List) ? (d['photos'] as List).length : 0;
    if (photos > 0) lines.add('Photos: $photos');
    final m = (d['mention'] is Map) ? d['mention'] as Map : const {};
    if (s(m['title']).isNotEmpty) {
      lines.add('Message: ${s(m['kind'])}, "${s(m['title'])}" ${s(m['body'])}');
    }
    return lines.join('\n\n');
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: Text('History: ${widget.name}')),
      body: rows == null
          ? const Center(child: CircularProgressIndicator(color: Brand.red))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 48),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(_error!,
                                    style: const TextStyle(color: Brand.red)),
                              ),
                            if (_error == null && rows.isEmpty)
                              const Padding(
                                padding: EdgeInsets.all(24),
                                child: Text('Nothing yet for this space.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Brand.inkMuted)),
                              ),
                            for (var i = 0; i < rows.length; i++) _item(i, rows[i]),
                            const SizedBox(height: 12),
                            const Text(
                                'Owners\' replies to our emails go to '
                                'hello@nomadwise.io, so they are in that inbox '
                                'rather than here. Email text is kept from 29 Sep '
                                '2026; older emails show their subject only.',
                                style: TextStyle(
                                    fontSize: 12, color: Brand.inkMuted, height: 1.45)),
                          ]),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _item(int i, Map<String, dynamic> r) {
    final kind = '${r['kind']}';
    final (icon, color) = _look(kind);
    final when = DateTime.tryParse('${r['at']}')?.toLocal();
    final draft = r['draft'] is Map ? _draftText(r['draft'] as Map) : '';
    final text = [
      if ((r['text'] ?? '').toString().trim().isNotEmpty) '${r['text']}'.trim(),
      if (draft.isNotEmpty) draft,
    ].join('\n\n');
    final open = _open.contains(i);
    final link = (r['link'] ?? '').toString();
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 36,
        child: Column(children: [
          const SizedBox(height: 14),
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
                color: color.withValues(alpha: .12), shape: BoxShape.circle),
            child: Icon(icon, size: 17, color: color),
          ),
        ]),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: Brand.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Brand.border),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: text.isEmpty
                ? null
                : () => setState(() => open ? _open.remove(i) : _open.add(i)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text('${r['title'] ?? ''}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                      ),
                      if (when != null)
                        Text(DateFormat('d MMM, HH:mm').format(when),
                            style: const TextStyle(
                                fontSize: 12, color: Brand.inkMuted)),
                    ]),
                    if ((r['detail'] ?? '').toString().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text('${r['detail']}',
                            style: const TextStyle(
                                fontSize: 12.5, color: Brand.inkSecondary)),
                      ),
                    if (text.isNotEmpty && !open)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, height: 1.45, color: Brand.inkSecondary)),
                      ),
                    if (open) ...[
                      const SizedBox(height: 10),
                      SelectableText(text,
                          style: const TextStyle(fontSize: 13.5, height: 1.55)),
                      if (link.startsWith('http'))
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: TextButton.icon(
                              onPressed: () => launchUrl(Uri.parse(link)),
                              icon: const Icon(Icons.open_in_new, size: 15),
                              label: const Text('Open the button\'s link')),
                        ),
                    ],
                    if (text.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(open ? 'Show less' : 'Show all',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Brand.accent)),
                      ),
                  ]),
            ),
          ),
        ),
      ),
    ]);
  }
}
