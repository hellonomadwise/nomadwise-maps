import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// One enquiry waiting to be passed on to a space (migration 113): a
/// nomad used Send an enquiry on a page that has no owner yet, or whose
/// owner is on Free. Pass on emails it to the space (their reply goes
/// straight to the nomad) and, if ticked, tells the nomad it went.
class PassOnCard extends StatelessWidget {
  final Map<String, dynamic> e;
  final SupabaseService supabase;

  /// Reloads the control centre after an action.
  final Future<void> Function() onDone;

  /// Opens the space search and returns the chosen space, for an
  /// enquiry whose listing was not recognised.
  final Future<Map<String, dynamic>?> Function(String initial) chooseSpace;

  const PassOnCard({
    super.key,
    required this.e,
    required this.supabase,
    required this.onDone,
    required this.chooseSpace,
  });

  String get _first =>
      (e['name'] ?? '').toString().trim().split(' ').first.isEmpty
          ? 'them'
          : (e['name'] ?? '').toString().trim().split(' ').first;

  bool get _matched => e['venue_id'] != null;

  bool get _verified => e['tier'] == 'verified';

  static String _when(String? ts) {
    final t = ts == null ? null : DateTime.tryParse(ts)?.toLocal();
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    final clock = DateFormat('d MMM, HH:mm').format(t);
    if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago  ·  $clock';
    return clock;
  }

  void _snack(BuildContext context, String text, {bool bad = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  Future<void> _open(String url) async {
    var u = url.trim();
    if (u.isEmpty) return;
    if (!u.startsWith('http')) u = 'https://$u';
    await launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
  }

  // ------------------------------------------------------------ actions

  Future<void> _passOn(BuildContext context) async {
    final suggestions = <String>[
      if ((e['owner_email'] ?? '').toString().contains('@'))
        (e['owner_email'] as String).trim().toLowerCase(),
      for (final s in (e['contact_emails'] as List? ?? const []))
        if ('$s'.contains('@')) '$s'.trim().toLowerCase(),
    ].toSet().toList();
    final ctl = TextEditingController(
        text: suggestions.isEmpty ? '' : suggestions.first);
    var tell = true;
    final website = (e['website'] ?? '').toString();
    final instagram = (e['instagram'] ?? '').toString();
    final checked = e['contact_checked'] == true;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('Pass on to ${e['venue_name'] ?? 'the space'}'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (suggestions.isNotEmpty) ...[
                      Text(
                          (e['owner_email'] ?? '').toString().isNotEmpty
                              ? 'The owner, and addresses from their website:'
                              : 'Found on their website:',
                          style: const TextStyle(
                              fontSize: 12.5, color: Brand.inkSecondary)),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final s in suggestions)
                          ChoiceChip(
                            label: Text(s, style: const TextStyle(fontSize: 12.5)),
                            selected: ctl.text.trim().toLowerCase() == s,
                            showCheckmark: false,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => setD(() => ctl.text = s),
                          ),
                      ]),
                      const SizedBox(height: 12),
                    ] else
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                            checked
                                ? 'No email found on their website. Look on '
                                    'their website or Instagram and paste it below.'
                                : 'Still looking for an email on their website. '
                                    'Check back in a few minutes, or paste one below.',
                            style: const TextStyle(
                                fontSize: 12.5,
                                height: 1.45,
                                color: Brand.goldTextDark)),
                      ),
                    TextField(
                      controller: ctl,
                      keyboardType: TextInputType.emailAddress,
                      onChanged: (_) => setD(() {}),
                      decoration:
                          const InputDecoration(labelText: 'Send it to'),
                    ),
                    if (website.isNotEmpty || instagram.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(spacing: 4, children: [
                        if (website.isNotEmpty)
                          TextButton.icon(
                              onPressed: () => _open(website),
                              icon: const Icon(Icons.language, size: 16),
                              label: const Text('Their website')),
                        if (instagram.isNotEmpty)
                          TextButton.icon(
                              onPressed: () => _open(instagram.startsWith('http')
                                  ? instagram
                                  : 'https://instagram.com/${instagram.replaceAll('@', '')}'),
                              icon: const Icon(Icons.camera_alt_outlined, size: 16),
                              label: const Text('Instagram')),
                      ]),
                    ],
                    const SizedBox(height: 4),
                    CheckboxListTile(
                      value: tell,
                      onChanged: (v) => setD(() => tell = v ?? true),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text('Tell $_first it has been passed on',
                          style: const TextStyle(fontSize: 13.5)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                        _verified
                            ? 'They get the enquiry (their reply goes straight to '
                                '$_first) and a reminder to add an enquiry address, '
                                'so the next ones reach them directly.'
                            : (e['owner_email'] ?? '').toString().isNotEmpty
                            ? 'They get the enquiry (their reply goes straight to '
                                '$_first) and a line about Verified, which sends '
                                'enquiries straight to their inbox.'
                            : 'They get the enquiry (their reply goes straight to '
                                '$_first) and a link to claim their page for free.',
                        style: const TextStyle(
                            fontSize: 12, height: 1.45, color: Brand.inkMuted)),
                  ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton.icon(
                onPressed: ctl.text.contains('@')
                    ? () => Navigator.pop(ctx, true)
                    : null,
                icon: const Icon(Icons.send_rounded, size: 16),
                label: const Text('Pass on')),
          ],
        ),
      ),
    );
    final to = ctl.text.trim();
    if (ok != true || !context.mounted) return;
    try {
      await supabase.passOnEnquiry('${e['id']}', to, tellNomad: tell);
      if (!context.mounted) return;
      _snack(context, 'Passed on to $to${tell ? ', and $_first has been told' : ''}.');
      await onDone();
    } catch (err) {
      if (context.mounted) _snack(context, 'That did not send: $err', bad: true);
    }
  }

  Future<void> _close(BuildContext context, String reason) async {
    var tell = true;
    if (reason == 'unreachable') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: const Text('Can\'t reach the space?'),
            content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      'The enquiry is closed without going to '
                      '${e['venue_name'] ?? 'the space'}.',
                      style: const TextStyle(fontSize: 13.5, height: 1.45)),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: tell,
                    onChanged: (v) => setD(() => tell = v ?? true),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                        'Send $_first their website and Google Maps link, so '
                        'they can contact them directly',
                        style: const TextStyle(fontSize: 13.5)),
                  ),
                ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Close it')),
            ],
          ),
        ),
      );
      if (ok != true || !context.mounted) return;
    }
    try {
      await supabase.closeEnquiry('${e['id']}', reason,
          tellNomad: reason == 'unreachable' && tell);
      if (!context.mounted) return;
      _snack(
          context,
          switch (reason) {
            'handled' => 'Marked as handled.',
            'spam' => 'Marked as spam.',
            _ => tell ? 'Closed, and $_first has their details.' : 'Closed.',
          });
      await onDone();
    } catch (err) {
      if (context.mounted) _snack(context, 'That did not work: $err', bad: true);
    }
  }

  Future<void> _attach(BuildContext context) async {
    final listing = (e['listing_text'] ?? '').toString();
    final picked = await chooseSpace(listing.split(',').first.trim());
    if (picked == null || !context.mounted) return;
    try {
      await supabase.attachEnquiry('${e['id']}', '${picked['id']}');
      if (!context.mounted) return;
      _snack(context, 'Linked to ${picked['name']}.');
      await onDone();
    } catch (err) {
      if (context.mounted) _snack(context, 'That did not work: $err', bad: true);
    }
  }

  // ------------------------------------------------------------- layout

  @override
  Widget build(BuildContext context) {
    final owner = (e['owner_email'] ?? '').toString().isNotEmpty;
    final badge = !_matched
        ? ('Not matched', Brand.goldTextDark)
        : _verified
            ? ('Verified, no enquiry address', Brand.success)
            : owner
                ? ('Free owner', Brand.accent)
                : ('Not claimed', Brand.inkSecondary);
    final title = _matched
        ? '${e['venue_name']}${(e['city'] ?? '').toString().isEmpty ? '' : ', ${e['city']}'}'
        : (e['listing_text'] ?? 'Unknown listing').toString();
    final earlier = (e['earlier'] as num?)?.toInt() ?? 0;
    final phone = (e['phone'] ?? '').toString().trim();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      color: Brand.ink)),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: badge.$2.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(6)),
              child: Text(badge.$1,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: badge.$2)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
              [
                _when(e['created_at']?.toString()),
                if (earlier > 0)
                  '$earlier earlier ${earlier == 1 ? 'enquiry' : 'enquiries'} for this space',
              ].where((s) => s.isNotEmpty).join('  ·  '),
              style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
          const SizedBox(height: 10),
          Text.rich(TextSpan(children: [
            TextSpan(
                text: '${e['name'] ?? 'Someone'}  ',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            TextSpan(text: '${e['email'] ?? ''}${phone.isEmpty ? '' : '  ·  $phone'}'),
          ]),
              style: const TextStyle(fontSize: 13.5, color: Brand.ink)),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: Brand.field, borderRadius: BorderRadius.circular(8)),
            child: Text(
                (e['message'] ?? '').toString().trim().isEmpty
                    ? '(No message)'
                    : (e['message'] ?? '').toString().trim(),
                style: const TextStyle(
                    fontSize: 13.5, height: 1.5, color: Brand.ink)),
          ),
          const SizedBox(height: 12),
          Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (_matched)
                  FilledButton.icon(
                      onPressed: () => _passOn(context),
                      icon: const Icon(Icons.send_rounded, size: 16),
                      label: const Text('Pass on'))
                else
                  FilledButton.icon(
                      onPressed: () => _attach(context),
                      icon: const Icon(Icons.search, size: 16),
                      label: const Text('Choose the space')),
                if (_matched && (e['slug'] ?? '').toString().isNotEmpty)
                  TextButton(
                      onPressed: () => _open(
                          'https://www.nomadwise.io/coworking/${e['slug']}'),
                      child: const Text('Their page')),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (r) => _close(context, r),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'handled', child: Text('Already handled')),
                    if (_matched)
                      const PopupMenuItem(
                          value: 'unreachable',
                          child: Text('Can\'t reach the space')),
                    const PopupMenuItem(value: 'spam', child: Text('Spam')),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Text('More',
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: Brand.inkSecondary)),
                  ),
                ),
              ]),
        ]),
      ),
    );
  }
}
