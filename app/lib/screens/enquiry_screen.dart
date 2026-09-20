import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/analytics_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';

/// The Request a booking form. A nomad arrives here from a Verified
/// listing on nomadwise.io (nomadmaps.io/?enquire=<slug>), fills in a
/// few lines, and the request goes to the space's own inbox with a
/// copy to Nomadwise. No account, no payment, one screen.
class EnquiryScreen extends StatefulWidget {
  final String slug;
  const EnquiryScreen({super.key, required this.slug});
  @override
  State<EnquiryScreen> createState() => _EnquiryScreenState();
}

class _EnquiryScreenState extends State<EnquiryScreen> {
  final _supabase = SupabaseService();
  Map<String, dynamic>? _venue;
  bool _loading = true;
  bool _sending = false;
  bool _sent = false;
  String? _error;

  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _dates = TextEditingController();
  final _people = TextEditingController();
  final _message = TextEditingController();
  // Honeypot: a field people never see; bots fill everything.
  final _website = TextEditingController();
  String _want = 'day_pass';

  static const _wants = [
    ('day_pass', 'A day pass'),
    ('desk_month', 'A desk for a month or longer'),
    ('event', 'A meeting or event'),
    ('other', 'Something else'),
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
      Analytics.capture('enquiry_opened',
          {'venue': v['name'], 'slug': widget.slug});
    }
  }

  String get _pageUrl => 'https://www.nomadwise.io/coworking/${widget.slug}';

  Future<void> _send() async {
    final v = _venue;
    if (v == null) return;
    if (_website.text.isNotEmpty) {
      // A bot. Pretend it worked; nothing is stored.
      setState(() => _sent = true);
      return;
    }
    final name = _name.text.trim();
    final email = _email.text.trim();
    if (name.isEmpty || !email.contains('@') || email.length < 5) {
      setState(() => _error = 'Your name and a working email are needed so '
          '${v['name']} can reply.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _supabase.sendEnquiry({
        'venue_id': v['id'],
        'name': name,
        'email': email,
        'phone': _phone.text.trim().isEmpty ? null : _phone.text.trim(),
        'want': _want,
        'dates': _dates.text.trim().isEmpty ? null : _dates.text.trim(),
        'people': int.tryParse(_people.text.trim()),
        'message':
            _message.text.trim().isEmpty ? null : _message.text.trim(),
        'source': 'nomadwise',
      });
      Analytics.capture('enquiry_sent', {'venue': v['name'], 'want': _want});
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'That did not send. ${_plain(e)}');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  static String _plain(Object e) {
    final s = '$e';
    // The database's own limits speak plainly; hide the rest.
    if (s.contains('Too many') || s.contains('a lot of requests')) {
      final i = s.indexOf(RegExp(r'Too many|This listing'));
      return s.substring(i).split('\n').first;
    }
    return 'Please try again in a moment.';
  }

  @override
  Widget build(BuildContext context) {
    final v = _venue;
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(
        title: const Text('Request a booking'),
        leading: IconButton(
            tooltip: 'Back to the listing',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => launchUrl(Uri.parse(_pageUrl),
                mode: LaunchMode.platformDefault)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: Brand.red))
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
              'Go back to nomadwise.io and try the button again, or email '
              'hello@nomadwise.io and we will pass your request on.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Brand.inkMuted, height: 1.5)),
          const SizedBox(height: 16),
          OutlinedButton(
              onPressed: () => launchUrl(Uri.parse('https://www.nomadwise.io'),
                  mode: LaunchMode.platformDefault),
              child: const Text('Back to nomadwise.io')),
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
            child: const Icon(Icons.mark_email_read_outlined,
                size: 34, color: Brand.success),
          ),
          const SizedBox(height: 16),
          Text('Sent to ${v['name']}',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          const SizedBox(height: 8),
          Text(
              'They have your request and will reply to ${_email.text.trim()} '
              'directly. Most spaces answer within a day or two.',
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

  Widget _form(Map<String, dynamic> v) {
    final where = [v['neighbourhood'], v['city']]
        .where((x) => x != null && '$x'.isNotEmpty)
        .join(', ');
    return ListView(padding: const EdgeInsets.all(18), children: [
      Text(v['name'] ?? '',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
      if (where.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(where,
              style:
                  const TextStyle(color: Brand.inkSecondary, fontSize: 13)),
        ),
      const SizedBox(height: 8),
      const Text(
          'Tell the space what you are after and they will reply to you '
          'by email. Nothing is booked or charged here.',
          style: TextStyle(
              color: Brand.inkSecondary, fontSize: 13, height: 1.45)),
      const SizedBox(height: 18),
      const Text('What are you after?',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _wants
            .map((w) => ChoiceChip(
                  label: Text(w.$2),
                  selected: _want == w.$1,
                  showCheckmark: false,
                  selectedColor: Brand.ink,
                  labelStyle: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: _want == w.$1 ? Colors.white : Brand.ink),
                  onSelected: (_) => setState(() => _want = w.$1),
                ))
            .toList(),
      ),
      const SizedBox(height: 16),
      TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Your name')),
      const SizedBox(height: 12),
      TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
              labelText: 'Your email', helperText: 'They reply here.')),
      const SizedBox(height: 12),
      TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
              labelText: 'Phone or WhatsApp (optional)')),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
            flex: 3,
            child: TextField(
                controller: _dates,
                decoration: const InputDecoration(
                    labelText: 'Dates',
                    hintText: 'e.g. 3 to 7 November'))),
        const SizedBox(width: 10),
        Expanded(
            flex: 2,
            child: TextField(
                controller: _people,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'People'))),
      ]),
      const SizedBox(height: 12),
      TextField(
          controller: _message,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
              labelText: 'Anything else (optional)',
              hintText: 'Quiet desk, meeting room, a call booth, parking...',
              alignLabelWithHint: true)),
      // Honeypot, kept out of sight and out of the tab order.
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
              backgroundColor: Brand.red,
              padding: const EdgeInsets.symmetric(vertical: 16)),
          icon: const Icon(Icons.send, size: 18),
          label: Text(_sending ? 'Sending' : 'Send request')),
      const SizedBox(height: 10),
      const Text(
          'Your details go to this space and to Nomadwise, and to no one '
          'else.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Brand.inkMuted, fontSize: 11.5)),
      const SizedBox(height: 40),
    ]);
  }
}
