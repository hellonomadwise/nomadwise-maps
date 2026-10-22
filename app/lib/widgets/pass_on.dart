import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';
import 'enquiry_review.dart';

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
          title: Text('Step 1 of 2: send to ${e['venue_name'] ?? 'the space'}'),
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
                icon: const Icon(Icons.visibility_outlined, size: 16),
                label: const Text('Check the emails')),
          ],
        ),
      ),
    );
    final to = ctl.text.trim();
    if (ok != true || !context.mounted) return;
    // Every email shown as it will arrive, editable, before anything
    // is sent (migration 194).
    final r = await Navigator.of(context).push<EnquiryReviewResult>(
        MaterialPageRoute(
            builder: (_) => EnquiryReviewScreen(
                supabase: supabase,
                targets: [
                  EnquiryTarget('${e['id']}', '${e['venue_name'] ?? 'the space'}', to)
                ],
                tellCustomer: tell,
                customerName: '${e['name'] ?? ''}')));
    if (r == null || !context.mounted) return;
    _snack(
        context,
        r.passed == 0
            ? 'That did not send. Please try again.'
            : 'Passed on to ${e['venue_name'] ?? 'the space'}'
                '${r.customerTold ? ', and $_first has been told' : ''}'
                '${r.customerSkipped ? '. The email to $_first did not go: write to them by hand' : ''}.',
        bad: r.passed == 0 || r.customerSkipped);
    await onDone();
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
                ? ('Claimed', Brand.accent)
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
                      icon: const Icon(Icons.rate_review_outlined, size: 16),
                      label: const Text('Review and send'))
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
          if (_matched)
          // Nothing goes out from here (Jonathan, 22 Oct 2026: "it looks
          // like it will do an action that is irreversible").
            const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
                'Nothing is sent yet. Next you choose the addresses, then see '
                'every email as it will arrive, and only Send sends them.',
                style: TextStyle(
                    fontSize: 12, height: 1.4, color: Brand.inkMuted)),
          ),
        ]),
      ),
    );
  }
}

/// The addresses to suggest for a space: the owner's, then the ones
/// found on its website.
List<String> passOnSuggestions(Map<String, dynamic> e) => <String>[
      if ((e['owner_email'] ?? '').toString().contains('@'))
        (e['owner_email'] as String).trim().toLowerCase(),
      for (final s in (e['contact_emails'] as List? ?? const []))
        if ('$s'.contains('@')) '$s'.trim().toLowerCase(),
    ].toSet().toList();

/// Several enquiries from the same person, as one card (migration 193;
/// Jonathan, 21 Oct 2026: Ellie, a team of two, asked six spaces in Ho
/// Chi Minh City in one evening). One press passes it on to every
/// space that has an address, and the person gets ONE email listing
/// them all, instead of one each.
class PassOnGroupCard extends StatelessWidget {
  /// The waiting enquiries from this person, oldest first.
  final List<Map<String, dynamic>> items;
  final SupabaseService supabase;
  final Future<void> Function() onDone;
  final Future<Map<String, dynamic>?> Function(String initial) chooseSpace;

  const PassOnGroupCard({
    super.key,
    required this.items,
    required this.supabase,
    required this.onDone,
    required this.chooseSpace,
  });

  Map<String, dynamic> get _first => items.first;

  String get _firstName {
    final n = (_first['name'] ?? '').toString().trim().split(' ').first;
    return n.isEmpty || n == 'Someone' ? 'them' : n;
  }

  void _snack(BuildContext context, String text, {bool bad = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text), backgroundColor: bad ? Brand.red : null));
  }

  static (String, Color) _badge(Map<String, dynamic> e) => e['venue_id'] == null
      ? ('Not matched', Brand.goldTextDark)
      : e['tier'] == 'verified'
          ? ('Verified', Brand.success)
          : (e['owner_email'] ?? '').toString().isNotEmpty
              ? ('Claimed', Brand.accent)
              : ('Not claimed', Brand.inkSecondary);

  Future<void> _passOnAll(BuildContext context) async {
    final matched = items.where((e) => e['venue_id'] != null).toList();
    final ctls = [
      for (final e in matched)
        TextEditingController(
            text: passOnSuggestions(e).isEmpty ? '' : passOnSuggestions(e).first)
    ];
    final include = [for (final c in ctls) c.text.contains('@')];
    var tell = true;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final n = [
          for (var i = 0; i < matched.length; i++)
            if (include[i] && ctls[i].text.contains('@')) i
        ].length;
        return AlertDialog(
          title: const Text('Step 1 of 2: who it goes to'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                        'Each space gets the enquiry on its own (their reply goes '
                        'straight to the customer), with a free claim link, or a '
                        'line about Verified if they have claimed.',
                        style: TextStyle(
                            fontSize: 12.5,
                            height: 1.45,
                            color: Brand.inkSecondary)),
                    const SizedBox(height: 10),
                    for (var i = 0; i < matched.length; i++) ...[
                      Row(children: [
                        Checkbox(
                            value: include[i],
                            onChanged: (v) =>
                                setD(() => include[i] = v ?? false)),
                        Expanded(
                          child: Text('${matched[i]['venue_name'] ?? 'A space'}',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w700)),
                        ),
                      ]),
                      Padding(
                        padding: const EdgeInsets.only(left: 12, bottom: 10),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TextField(
                                controller: ctls[i],
                                keyboardType: TextInputType.emailAddress,
                                onChanged: (_) => setD(() {
                                  if (ctls[i].text.contains('@')) {
                                    include[i] = true;
                                  }
                                }),
                                decoration: InputDecoration(
                                    isDense: true,
                                    labelText: 'Send it to',
                                    helperText: passOnSuggestions(matched[i])
                                            .isEmpty
                                        ? (matched[i]['contact_checked'] == true
                                            ? 'No email on their website: paste one, or leave it out'
                                            : 'Still looking on their website: paste one, or leave it out')
                                        : null),
                              ),
                              if (passOnSuggestions(matched[i]).length > 1)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Wrap(spacing: 6, runSpacing: 6, children: [
                                    for (final s in passOnSuggestions(matched[i]))
                                      ChoiceChip(
                                        label: Text(s,
                                            style: const TextStyle(fontSize: 12)),
                                        selected:
                                            ctls[i].text.trim().toLowerCase() == s,
                                        showCheckmark: false,
                                        visualDensity: VisualDensity.compact,
                                        onSelected: (_) => setD(() {
                                          ctls[i].text = s;
                                          include[i] = true;
                                        }),
                                      ),
                                  ]),
                                ),
                            ]),
                      ),
                    ],
                    if (matched.length < items.length)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                            '${items.length - matched.length} not matched to a '
                            'space yet: choose the space on the card first.',
                            style: const TextStyle(
                                fontSize: 12.5, color: Brand.goldTextDark)),
                      ),
                    CheckboxListTile(
                      value: tell,
                      onChanged: (v) => setD(() => tell = v ?? true),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(
                          'Tell $_firstName once, with the list of spaces it went to',
                          style: const TextStyle(fontSize: 13.5)),
                    ),
                  ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton.icon(
                onPressed: n > 0 ? () => Navigator.pop(ctx, true) : null,
                icon: const Icon(Icons.visibility_outlined, size: 16),
                label: Text(n == 1
                    ? 'Check the email (1 space)'
                    : 'Check the emails ($n spaces)')),
          ],
        );
      }),
    );
    final targets = <EnquiryTarget>[
      for (var i = 0; i < matched.length; i++)
        if (include[i] && ctls[i].text.contains('@'))
          EnquiryTarget('${matched[i]['id']}',
              '${matched[i]['venue_name'] ?? 'A space'}', ctls[i].text.trim())
    ];
    for (final c in ctls) {
      c.dispose();
    }
    if (ok != true || !context.mounted || targets.isEmpty) return;
    // Every email shown as it will arrive, editable, before anything
    // is sent (migration 194).
    final r = await Navigator.of(context).push<EnquiryReviewResult>(
        MaterialPageRoute(
            builder: (_) => EnquiryReviewScreen(
                supabase: supabase,
                targets: targets,
                tellCustomer: tell,
                customerName: '${_first['name'] ?? ''}')));
    if (r == null || !context.mounted) return;
    _snack(
        context,
        [
          'Passed on to ${r.passed} ${r.passed == 1 ? 'space' : 'spaces'}',
          if (r.customerTold) '$_firstName has one email with the list',
          if (r.customerSkipped)
            'the email to $_firstName did not go: write to them by hand',
          if (r.failed.isNotEmpty) 'not sent to ${r.failed.join(', ')}',
        ].join('. ') + '.',
        bad: r.failed.isNotEmpty || r.customerSkipped);
    await onDone();
  }

  Future<void> _closeAll(BuildContext context, String reason) async {
    var n = 0;
    for (final e in items) {
      try {
        await supabase.closeEnquiry('${e['id']}', reason);
        n++;
      } catch (_) {}
    }
    if (!context.mounted) return;
    _snack(context,
        reason == 'spam' ? '$n marked as spam.' : '$n marked as handled.');
    await onDone();
  }

  Future<void> _attach(BuildContext context, Map<String, dynamic> e) async {
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

  @override
  Widget build(BuildContext context) {
    final phone = (_first['phone'] ?? '').toString().trim();
    final messages = items
        .map((e) => (e['message'] ?? '').toString().trim())
        .where((m) => m.isNotEmpty)
        .toSet()
        .toList();
    final cities = items
        .map((e) => (e['city'] ?? '').toString().trim())
        .where((c) => c.isNotEmpty)
        .toSet()
        .join(', ');
    final latest = items
        .map((e) => '${e['created_at'] ?? ''}')
        .reduce((a, b) => a.compareTo(b) >= 0 ? a : b);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1.5,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(
                  '${_first['name'] ?? 'Someone'} asked ${items.length} spaces'
                  '${cities.isEmpty ? '' : ' in $cities'}',
                  style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      color: Brand.ink)),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: Brand.violet.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(6)),
              child: const Text('One customer',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Brand.violet)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(PassOnCard._when(latest),
              style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
          const SizedBox(height: 10),
          Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: '${_first['name'] ?? 'Someone'}  ',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                TextSpan(
                    text:
                        '${_first['email'] ?? ''}${phone.isEmpty ? '' : '  ·  $phone'}'),
              ]),
              style: const TextStyle(fontSize: 13.5, color: Brand.ink)),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: Brand.field, borderRadius: BorderRadius.circular(8)),
            child: Text(
                messages.isEmpty
                    ? '(No message)'
                    : messages.first +
                        (messages.length > 1
                            ? '\n\n(${messages.length - 1} of the others are worded a '
                                'little differently; each space gets its own.)'
                            : ''),
                style: const TextStyle(
                    fontSize: 13.5, height: 1.5, color: Brand.ink)),
          ),
          const SizedBox(height: 10),
          for (final e in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                const Icon(Icons.storefront_outlined,
                    size: 16, color: Brand.inkMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      e['venue_id'] == null
                          ? (e['listing_text'] ?? 'Unknown listing').toString()
                          : '${e['venue_name']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5)),
                ),
                if (e['venue_id'] == null)
                  TextButton(
                      onPressed: () => _attach(context, e),
                      child: const Text('Choose the space'))
                else
                  Text(_badge(e).$1,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: _badge(e).$2)),
              ]),
            ),
          const SizedBox(height: 6),
          Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                    onPressed: items.any((e) => e['venue_id'] != null)
                        ? () => _passOnAll(context)
                        : null,
                    icon: const Icon(Icons.rate_review_outlined, size: 16),
                    label: const Text('Review and send to all')),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (r) => _closeAll(context, r),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'handled', child: Text('All already handled')),
                    PopupMenuItem(value: 'spam', child: Text('All spam')),
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
          // Nothing goes out from here (Jonathan, 22 Oct 2026: "it looks
          // like it will do an action that is irreversible").
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
                'Nothing is sent yet. Next you choose the addresses, then see '
                'every email as it will arrive, and only Send sends them.',
                style: TextStyle(
                    fontSize: 12, height: 1.4, color: Brand.inkMuted)),
          ),
        ]),
      ),
    );
  }
}
