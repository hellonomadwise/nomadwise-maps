import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// Admin only: what visitors told us has changed at a space, from the
/// "Something need updating?" link on each nomadwise.io page. Open
/// ones by default; fix the page, then mark it done, or dismiss it.
///
/// [embedded]: shown inside Page upgrades, under its own title, so it
/// has no title bar of its own (Jonathan, 20 Oct 2026: what visitors
/// suggest is not an owner's change, it is a page upgrade).
/// [onChanged]: told when one is marked done, dismissed or reopened,
/// so the numbers around it can be read again.
class ListingUpdatesScreen extends StatefulWidget {
  const ListingUpdatesScreen(
      {super.key, this.embedded = false, this.onChanged});
  final bool embedded;
  final VoidCallback? onChanged;
  @override
  State<ListingUpdatesScreen> createState() => _ListingUpdatesScreenState();
}

class _ListingUpdatesScreenState extends State<ListingUpdatesScreen> {
  final _supabase = SupabaseService();
  List<Map<String, dynamic>>? _rows;
  bool _all = false;

  static const _kindLabels = {
    'closed': 'It has closed',
    'temporarily_closed': 'Temporarily closed',
    'hours': 'Opening hours',
    'wifi': 'Wifi',
    'laptops': 'Laptop rules',
    'plugs': 'Plug sockets',
    'prices': 'Prices',
    'photos': 'Photos',
    'address': 'Name or address',
    'other': 'Something else',
    // From "Add a tag" on a listing page (nomadmaps.io/?tag=<slug>).
    'tags': 'Tags to add',
  };
  static const _visitLabels = {
    'today': 'today',
    'this_week': 'this week',
    'this_month': 'this month',
    'longer': 'longer ago',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await _supabase.listingUpdates(openOnly: !_all);
    if (mounted) setState(() => _rows = rows);
  }

  Future<void> _set(Map<String, dynamic> r, String status) async {
    try {
      await _supabase.setListingUpdateStatus('${r['id']}', status);
      await _load();
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Not saved: $e')));
      }
    }
  }

  /// What they told us about, in the words of a reply.
  static String _aboutWords(List kinds) {
    const words = {
      'hours': 'the new opening hours',
      'prices': 'the new prices',
      'wifi': 'the wifi details',
      'closed': 'the closure',
      'temporarily_closed': 'the temporary closure',
      'photos': 'the photos',
      'address': 'the name and address',
      'laptops': 'the laptop rules',
      'plugs': 'the plug sockets',
      'tags': 'the tags',
    };
    if (kinds.length == 1) return words['${kinds.first}'] ?? 'the update';
    return 'the changes';
  }

  /// Answer a suggestion: an email to whoever wrote it, with the link to
  /// their own listing (claim it, or sign in when it is already theirs).
  /// Editable before it goes; sent through Outreach so it is in the
  /// space's history there.
  Future<void> _reply(Map<String, dynamic> r) async {
    Map<String, dynamic> prep;
    try {
      prep = await _supabase.listingUpdateReply('${r['id']}');
    } catch (e) {
      _say(_plain(e), bad: true);
      return;
    }
    if (!mounted) return;
    if (prep['unsubscribed'] == true) {
      _say('They asked us not to email them, so nothing can be sent.',
          bad: true);
      return;
    }
    final first = '${prep['first_name'] ?? ''}'.trim();
    final space = '${prep['space'] ?? r['space_name'] ?? 'your space'}';
    final link = '${prep['link'] ?? ''}';
    final claimed = prep['claimed'] == true;
    final about = _aboutWords((r['kinds'] as List?) ?? const []);
    final subject = TextEditingController(
        text: claimed
            ? 'Updating your page for $space'
            : 'Your page for $space on Nomadwise');
    final body = TextEditingController(
        text: '${first.isEmpty ? 'Hi' : 'Hi $first'},\n\n'
            'Thanks for letting us know about $about.\n\n'
            '${claimed ? 'You can make changes like this yourself whenever '
                'you need to. Sign in here to update your page:' : 'You can '
                'make changes like this yourself. Claim your page here (it is '
                'free), and you can update your hours, prices, photos and more '
                'whenever you need to:'}\n'
            '$link\n\n'
            'Any questions, just reply to this email.\n\n'
            'Kind regards,\nJonathan Heavens\nCofounder - Nomadwise.io');
    final how = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reply to ${first.isEmpty ? space : first}'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('To ${prep['email']}',
                      style: const TextStyle(
                          fontSize: 12.5, color: Brand.inkSecondary)),
                  const SizedBox(height: 10),
                  TextField(
                      controller: subject,
                      decoration: const InputDecoration(labelText: 'Subject')),
                  const SizedBox(height: 10),
                  TextField(
                      controller: body,
                      minLines: 8,
                      maxLines: 16,
                      decoration: const InputDecoration(
                          labelText: 'Message',
                          helperText: 'Change anything before it goes. What '
                              'you send is kept in Outreach for this space.',
                          helperMaxLines: 2,
                          alignLabelWithHint: true)),
                ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'own'),
              child: const Text('Copy, I send it myself')),
          FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, 'send'),
              icon: const Icon(Icons.send_rounded, size: 16),
              label: const Text('Send')),
        ],
      ),
    );
    if (how == null || !mounted) return;
    final cid = '${prep['contact_id']}';
    try {
      if (how == 'send') {
        await _supabase.outreachSend(cid, subject.text, body.text,
            force: true);
      } else {
        await Clipboard.setData(ClipboardData(text: body.text));
        await _supabase.outreachLogSent(cid, subject.text, body.text,
            force: true);
      }
      await _supabase.setListingUpdateNote('${r['id']}',
          'Replied ${DateFormat('d MMM').format(DateTime.now())} with the link to their own listing');
      await _load();
      widget.onChanged?.call();
      _say(how == 'send'
          ? 'Sent to ${prep['email']}. It is in Outreach under $space.'
          : 'Copied. Paste it into your email to ${prep['email']}; it is '
              'noted in Outreach under $space.');
    } catch (e) {
      _say('Not sent: ${_plain(e)}', bad: true);
    }
  }

  static String _plain(Object e) {
    final s = '$e';
    final m = RegExp(r'message: ([^,]+)').firstMatch(s);
    return (m?.group(1) ?? s).replaceAll('PostgrestException(', '').trim();
  }

  void _say(String text, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  void _toggleAll() {
    setState(() {
      _all = !_all;
      _rows = null;
    });
    _load();
  }

  static const _emptyText = 'Nothing waiting. When someone uses "Something '
      'need updating?" or "Add a tag" on a page, it lands here and pings '
      'your phone.';

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (widget.embedded) return _embeddedBody(rows);
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: const Text('Suggested updates'), actions: [
        TextButton(
            onPressed: _toggleAll,
            child: Text(_all ? 'Open only' : 'Show all')),
      ]),
      body: rows == null
          ? const Center(child: CircularProgressIndicator(color: Brand.red))
          : rows.isEmpty
              ? const Center(
                  child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(_emptyText,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Brand.inkMuted, height: 1.5)),
                ))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 30),
                      children: rows.map(_card).toList()),
                ),
    );
  }

  /// Inside Page upgrades: one list, with what it is and the "Show
  /// all" switch at its top instead of in a title bar.
  Widget _embeddedBody(List<Map<String, dynamic>>? rows) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 30),
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(top: 6, right: 8),
                    child: Text(
                        'From visitors, on any page: tags to add, and '
                        'things that have changed (hours, wifi, prices, '
                        'closed). Fix the page, then mark it done, or '
                        'dismiss it.',
                        style: TextStyle(
                            fontSize: 12.5,
                            height: 1.4,
                            color: Brand.inkSecondary)),
                  ),
                ),
                TextButton(
                    onPressed: _toggleAll,
                    child: Text(_all ? 'Open only' : 'Show all')),
              ]),
              const SizedBox(height: 8),
              if (rows == null)
                const Padding(
                  padding: EdgeInsets.all(30),
                  child: Center(
                      child: CircularProgressIndicator(color: Brand.red)),
                )
              else if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 20, 4, 0),
                  child: Text(_emptyText,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Brand.inkMuted, height: 1.5)),
                )
              else
                ...rows.map(_card),
            ]),
      );

  Widget _card(Map<String, dynamic> r) {
    final when = DateTime.tryParse('${r['created_at']}')?.toLocal();
    final kinds = ((r['kinds'] as List?) ?? const [])
        .map((k) => _kindLabels['$k'] ?? '$k')
        .toList();
    final visit = _visitLabels['${r['last_visit']}'];
    final who = [
      if ((r['name'] ?? '').toString().isNotEmpty) r['name'],
      if ((r['email'] ?? '').toString().isNotEmpty) r['email'],
    ].join(', ');
    final status = '${r['status']}';
    final slug = (r['slug'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('${r['space_name'] ?? 'Unknown space'}',
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ),
          if (status != 'open')
            Text(status == 'done' ? 'Done' : 'Dismissed',
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Brand.inkMuted)),
        ]),
        if (when != null)
          Text(DateFormat('d MMM, HH:mm').format(when),
              style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
        if (kinds.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final k in kinds)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: Brand.bg, borderRadius: BorderRadius.circular(20)),
                child: Text(k,
                    style: const TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w600)),
              ),
          ]),
        ],
        if ((r['details'] ?? '').toString().isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableText('${r['details']}',
              style: const TextStyle(fontSize: 13.5, height: 1.45)),
        ],
        const SizedBox(height: 6),
        Text(
            [
              if (visit != null) 'Last there $visit',
              who.isEmpty ? 'No name left' : 'From $who',
            ].join(' · '),
            style: const TextStyle(fontSize: 12, color: Brand.inkSecondary)),
        if ((r['note'] ?? '').toString().trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('${r['note']}',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Brand.success)),
          ),
        Wrap(spacing: 4, children: [
          // Answer them with a link to their own listing, so they can
          // make changes like this themselves (Jonathan, 9 Nov 2026).
          if ((r['email'] ?? '').toString().trim().isNotEmpty &&
              r['venue_id'] != null)
            TextButton.icon(
                onPressed: () => _reply(r),
                icon: const Icon(Icons.reply, size: 16),
                label: const Text('Reply with their own link')),
          if (slug.isNotEmpty)
            TextButton.icon(
                onPressed: () => launchUrl(
                    Uri.parse('https://www.nomadwise.io/coworking/$slug')),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open the page')),
          if (status == 'open') ...[
            TextButton.icon(
                onPressed: () => _set(r, 'done'),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Mark done')),
            TextButton(
                onPressed: () => _set(r, 'dismissed'),
                child: const Text('Dismiss',
                    style: TextStyle(color: Brand.inkMuted))),
          ] else
            TextButton(
                onPressed: () => _set(r, 'open'),
                child: const Text('Reopen')),
        ]),
      ]),
    );
  }
}
