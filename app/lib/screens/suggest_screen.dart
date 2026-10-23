import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/supabase_service.dart';
import '../theme.dart';

/// nomadmaps.io/?suggest[&from=<page>]: "Suggest a place" (migration
/// 210). Anyone who knows a good cafe or coworking space that is not on
/// nomadwise.io yet tells us its name, the city and, if they like, a
/// link and why they recommend it. No account, no email. It lands on
/// the Candidates list in Nomad Maps ("Asked to be listed or
/// suggested"), where a founder finds it on Google and queues it, or
/// says why not. The founders' phones are told.
class SuggestScreen extends StatefulWidget {
  /// The nomadwise.io page they came from (for example
  /// /country/portugal), so "Back to nomadwise.io" leads there.
  final String? from;
  const SuggestScreen({super.key, this.from});

  @override
  State<SuggestScreen> createState() => _SuggestScreenState();
}

class _SuggestScreenState extends State<SuggestScreen> {
  final _supabase = SupabaseService();
  final _name = TextEditingController();
  final _city = TextEditingController();
  final _country = TextEditingController();
  final _link = TextEditingController();
  final _note = TextEditingController();
  String? _kind; // 'cafe' or 'coworking'
  bool _busy = false;
  bool _tried = false;
  String? _error;
  String? _thanksFor;

  @override
  void dispose() {
    _name.dispose();
    _city.dispose();
    _country.dispose();
    _link.dispose();
    _note.dispose();
    super.dispose();
  }

  /// Where "Back to nomadwise.io" goes: the page they came from when
  /// it is a nomadwise.io page, otherwise the home page.
  Uri get _back {
    final f = (widget.from ?? '').trim();
    if (f.startsWith('/') && !f.startsWith('//')) {
      return Uri.parse('https://www.nomadwise.io$f');
    }
    return Uri.parse('https://www.nomadwise.io/');
  }

  bool get _ready =>
      _name.text.trim().length >= 2 &&
      _city.text.trim().length >= 2 &&
      _kind != null;

  Future<void> _send() async {
    setState(() => _tried = true);
    if (!_ready || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _supabase.suggestPlace(
          name: _name.text.trim(),
          kind: _kind!,
          city: _city.text.trim(),
          country: _country.text.trim(),
          link: _link.text.trim(),
          note: _note.text.trim(),
          from: widget.from);
      if (!mounted) return;
      setState(() => _thanksFor = _name.text.trim());
    } catch (e) {
      final m = RegExp(r'message: ([^,]+)').firstMatch('$e')?.group(1);
      if (mounted) {
        setState(() => _error = m ?? 'That did not send. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _another() {
    for (final c in [_name, _city, _country, _link, _note]) {
      c.clear();
    }
    setState(() {
      _kind = null;
      _tried = false;
      _error = null;
      _thanksFor = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(title: const Text('Nomadwise')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: _thanksFor != null ? _thanks() : _form(),
        ),
      ),
    );
  }

  Widget _thanks() => ListView(
          padding: const EdgeInsets.fromLTRB(20, 32, 20, 40),
          children: [
            const Icon(Icons.check_circle, color: Brand.success, size: 44),
            const SizedBox(height: 14),
            Text('Thank you for suggesting $_thanksFor',
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w800, height: 1.3)),
            const SizedBox(height: 10),
            const Text(
                'We check every place before it goes on nomadwise.io: that '
                'it is open, and good to work from. If it is, it will get '
                'its own page with WiFi, plug sockets and opening hours.',
                style: TextStyle(
                    fontSize: 15, height: 1.5, color: Brand.inkSecondary)),
            const SizedBox(height: 24),
            Wrap(spacing: 10, runSpacing: 10, children: [
              FilledButton(
                  onPressed: _another,
                  child: const Text('Suggest another place')),
              OutlinedButton(
                  onPressed: () =>
                      launchUrl(_back, webOnlyWindowName: '_self'),
                  child: const Text('Back to nomadwise.io')),
            ]),
          ]);

  InputDecoration _field(String label, {String? hint, String? error}) =>
      InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: error,
          border: const OutlineInputBorder(),
          filled: true,
          fillColor: Colors.white);

  Widget _kindChoice() {
    Widget one(String value, String label, IconData icon) {
      final on = _kind == value;
      return Expanded(
        child: OutlinedButton.icon(
          onPressed: _busy ? null : () => setState(() => _kind = value),
          icon: Icon(on ? Icons.check_circle : icon, size: 19),
          label: Text(label),
          style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              foregroundColor: on ? Brand.red : Brand.ink,
              backgroundColor: on ? Brand.accentTint : Colors.white,
              side: BorderSide(
                  color: on ? Brand.red : Brand.border, width: on ? 1.5 : 1)),
        ),
      );
    }

    return Row(children: [
      one('cafe', 'Cafe', Icons.local_cafe_outlined),
      const SizedBox(width: 10),
      one('coworking', 'Coworking space', Icons.business_center_outlined),
    ]);
  }

  Widget _form() {
    final missingName = _tried && _name.text.trim().length < 2;
    final missingCity = _tried && _city.text.trim().length < 2;
    final missingKind = _tried && _kind == null;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 40), children: [
      const Text('Suggest a place',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      const Text(
          'Know a cafe or coworking space that is good to work from and not '
          'on nomadwise.io yet? Tell us about it and we will take a look.',
          style:
              TextStyle(fontSize: 15, height: 1.5, color: Brand.inkSecondary)),
      const SizedBox(height: 22),
      TextField(
        controller: _name,
        maxLength: 160,
        textCapitalization: TextCapitalization.words,
        onChanged: (_) => setState(() {}),
        decoration: _field('Name of the place',
            error: missingName ? 'Please add its name' : null),
      ),
      const SizedBox(height: 6),
      const Text('What kind of place is it?',
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      _kindChoice(),
      if (missingKind)
        const Padding(
          padding: EdgeInsets.only(top: 6, left: 12),
          child: Text('Please choose one',
              style: TextStyle(fontSize: 12, color: Brand.red)),
        ),
      const SizedBox(height: 18),
      TextField(
        controller: _city,
        maxLength: 120,
        textCapitalization: TextCapitalization.words,
        onChanged: (_) => setState(() {}),
        decoration: _field('City or area',
            hint: 'For example Canggu, or Lisbon',
            error: missingCity ? 'Please add the city or area' : null),
      ),
      const SizedBox(height: 4),
      TextField(
        controller: _country,
        maxLength: 80,
        textCapitalization: TextCapitalization.words,
        decoration: _field('Country (optional)'),
      ),
      const SizedBox(height: 4),
      TextField(
        controller: _link,
        maxLength: 500,
        keyboardType: TextInputType.url,
        decoration: _field('Link (optional)',
            hint: 'Google Maps, its website or Instagram'),
      ),
      const SizedBox(height: 4),
      TextField(
        controller: _note,
        maxLength: 800,
        minLines: 3,
        maxLines: 6,
        decoration: _field('Why do you recommend it? (optional)',
            hint: 'For example: fast WiFi, plenty of plug sockets, quiet '
                'upstairs'),
      ),
      const SizedBox(height: 6),
      const Text(
          'We check every suggestion before anything goes on nomadwise.io. '
          'We do not contact the place in your name.',
          style: TextStyle(fontSize: 12.5, height: 1.45, color: Brand.inkMuted)),
      const SizedBox(height: 14),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(_error!, style: const TextStyle(color: Brand.red)),
        ),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _busy ? null : _send,
          style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16)),
          child: Text(_busy ? 'Sending...' : 'Send suggestion',
              style: const TextStyle(fontSize: 16)),
        ),
      ),
    ]);
  }
}
