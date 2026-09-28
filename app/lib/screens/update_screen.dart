import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/analytics_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';

/// "Something need updating? Let us know", from a nomadwise.io
/// listing page (nomadmaps.io/?update=<slug>). Two doors, told apart at
/// the top: the people who run the space claim it and change it
/// themselves; everyone else tells us what has changed, which lands in
/// the control centre (Owner changes, Suggested updates).
class UpdateScreen extends StatefulWidget {
  final String slug;
  const UpdateScreen({super.key, required this.slug});
  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  final _supabase = SupabaseService();
  Map<String, dynamic>? _venue;
  bool _loading = true;
  bool _sending = false;
  bool _sent = false;
  String? _error;

  final _details = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  // Honeypot: a field people never see; bots fill everything.
  final _website = TextEditingController();
  final Set<String> _kinds = {};
  String? _lastVisit;

  static const _kindOptions = [
    ('closed', 'It has closed'),
    ('temporarily_closed', 'Temporarily closed'),
    ('hours', 'Opening hours'),
    ('wifi', 'Wifi'),
    ('laptops', 'Laptop rules'),
    ('plugs', 'Plug sockets'),
    ('prices', 'Prices'),
    ('photos', 'Photos'),
    ('address', 'Name or address'),
    ('other', 'Something else'),
  ];

  static const _visits = [
    ('today', 'Today'),
    ('this_week', 'This week'),
    ('this_month', 'This month'),
    ('longer', 'Longer ago'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await _supabase.venueBySlug(widget.slug);
    if (!mounted) return;
    setState(() {
      _venue = v;
      _loading = false;
    });
    if (v != null) {
      Analytics.capture('update_opened', {'venue': v['name'], 'slug': widget.slug});
    }
  }

  String get _pageUrl => 'https://www.nomadwise.io/coworking/${widget.slug}';

  String get _kind => SupabaseService.spaceKind('${_venue?['type'] ?? ''}');

  Future<void> _send() async {
    final v = _venue;
    if (v == null) return;
    if (_website.text.isNotEmpty) {
      setState(() => _sent = true); // a bot; nothing is stored
      return;
    }
    if (_kinds.isEmpty && _details.text.trim().isEmpty) {
      setState(() => _error = 'Pick what has changed, or tell us in a few words.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _supabase.submitListingUpdate({
        'venue_id': v['id'],
        'kinds': _kinds.toList(),
        'details': _details.text.trim(),
        'last_visit': _lastVisit,
        'name': _name.text.trim(),
        'email': _email.text.trim(),
      });
      Analytics.capture('update_sent',
          {'venue': v['name'], 'kinds': _kinds.join(',')});
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      final s = '$e';
      final i = s.indexOf(RegExp(r'Thanks, we already|Too many|Tell us|That listing'));
      if (mounted) {
        setState(() => _error = i >= 0
            ? s.substring(i).split('\n').first.replaceAll(RegExp(r'[",}]+$'), '')
            : 'That did not send. Please try again in a moment.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _venue;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(
        title: const Text('Suggest an update'),
        leading: IconButton(
            tooltip: 'Back to the listing',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => launchUrl(Uri.parse(_pageUrl),
                mode: LaunchMode.platformDefault)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: Brand.red))
              : v == null
                  ? _notFound()
                  : _sent
                      ? _thanks(v)
                      : _form(v),
        ),
      ),
    );
  }

  Widget _notFound() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.search_off, size: 40, color: Brand.inkMuted),
          const SizedBox(height: 12),
          const Text('We could not find that listing.',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 6),
          const Text(
              'Go back to the page and try the link again, or email '
              'hello@nomadwise.io with what has changed.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Brand.inkMuted, height: 1.5)),
          const SizedBox(height: 16),
          OutlinedButton(
              onPressed: () => launchUrl(Uri.parse('https://www.nomadwise.io'),
                  mode: LaunchMode.platformDefault),
              child: const Text('Back to Nomadwise')),
        ]),
      );

  Widget _thanks(Map<String, dynamic> v) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
                color: Brand.successTint, shape: BoxShape.circle),
            child: const Icon(Icons.check, size: 34, color: Brand.success),
          ),
          const SizedBox(height: 16),
          const Text('Thank you',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          const SizedBox(height: 8),
          Text(
              'We check every report before we change ${v['name']}, so the '
              'page stays right for the next person.'
              '${_email.text.trim().contains('@') ? ' If we have a question, we will email ${_email.text.trim()}.' : ''}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Brand.inkSecondary, height: 1.5, fontSize: 14)),
          const SizedBox(height: 20),
          OutlinedButton.icon(
              onPressed: () => launchUrl(Uri.parse(_pageUrl),
                  mode: LaunchMode.platformDefault),
              icon: const Icon(Icons.arrow_back, size: 16),
              label: Text('Back to ${v['name']}')),
        ]),
      );

  /// For the people who run the space: they should change it
  /// themselves, from their Owner account, not through a report.
  Widget _ownerDoor(Map<String, dynamic> v) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Brand.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.storefront_outlined, size: 18, color: Brand.ink),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Do you run ${v['name']}?',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
              'Claim your $_kind for free and change the page yourself: '
              'photos, hours, prices and the details nomads look for.',
              style: const TextStyle(
                  fontSize: 13.5, height: 1.45, color: Brand.inkSecondary)),
          const SizedBox(height: 10),
          FilledButton.icon(
              onPressed: () {
                Analytics.capture('update_to_claim', {'venue': v['name']});
                launchUrl(
                    Uri.parse('https://nomadmaps.io/?claim='
                        '${Uri.encodeQueryComponent(widget.slug)}'
                        '&from=${Uri.encodeQueryComponent('/update')}'),
                    webOnlyWindowName: '_self');
              },
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              icon: const Icon(Icons.verified_outlined, size: 18),
              label: Text('Claim my $_kind')),
        ]),
      );

  Widget _chip(String label, bool on, VoidCallback tap) => FilterChip(
        label: Text(label),
        selected: on,
        showCheckmark: false,
        selectedColor: Brand.ink,
        labelStyle: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: on ? Colors.white : Brand.ink),
        onSelected: (_) => tap(),
      );

  Widget _form(Map<String, dynamic> v) {
    final where = [v['neighbourhood'], v['city']]
        .where((x) => x != null && '$x'.isNotEmpty)
        .join(', ');
    return ListView(padding: const EdgeInsets.all(18), children: [
      Text('Something need updating at ${v['name']}?',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
      if (where.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(where,
              style: const TextStyle(color: Brand.inkSecondary, fontSize: 13)),
        ),
      const SizedBox(height: 16),
      _ownerDoor(v),
      const SizedBox(height: 22),
      const Text('Been there? Tell us what has changed',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      const SizedBox(height: 4),
      const Text(
          'Nomads rely on these pages. A quick note from someone who was '
          'there keeps them right.',
          style: TextStyle(
              color: Brand.inkSecondary, fontSize: 13, height: 1.45)),
      const SizedBox(height: 14),
      const Text('What has changed?',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (key, label) in _kindOptions)
          _chip(label, _kinds.contains(key), () {
            setState(() =>
                _kinds.contains(key) ? _kinds.remove(key) : _kinds.add(key));
          }),
      ]),
      const SizedBox(height: 16),
      TextField(
          controller: _details,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
              labelText: 'What is it now?',
              hintText: 'e.g. Now open until 8pm; wifi about 50 Mbps; '
                  'no laptops at weekends',
              alignLabelWithHint: true)),
      const SizedBox(height: 16),
      const Text('When were you last there? (optional)',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (key, label) in _visits)
          _chip(label, _lastVisit == key,
              () => setState(() => _lastVisit = _lastVisit == key ? null : key)),
      ]),
      const SizedBox(height: 16),
      TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Your name (optional)')),
      const SizedBox(height: 12),
      TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
              labelText: 'Your email (optional)',
              helperText: 'Only if we have a question about your report.')),
      Offstage(
          offstage: true,
          child: TextField(controller: _website, autofocus: false)),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_error!,
              style: const TextStyle(color: Brand.red, fontSize: 13)),
        ),
      const SizedBox(height: 18),
      FilledButton.icon(
          onPressed: _sending ? null : _send,
          style: FilledButton.styleFrom(
              backgroundColor: Brand.ink,
              padding: const EdgeInsets.symmetric(vertical: 16)),
          icon: const Icon(Icons.send, size: 18),
          label: Text(_sending ? 'Sending' : 'Send update')),
      const SizedBox(height: 10),
      const Text(
          'We read every report before anything on the page changes.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Brand.inkMuted, fontSize: 11.5)),
      const SizedBox(height: 40),
    ]);
  }
}
