import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/analytics_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/email_typo_hint.dart';

/// "Something need updating? Let us know", from a nomadwise.io
/// listing page (nomadmaps.io/?update=<slug>). Two doors, told apart at
/// the top: the people who run the space claim it and change it
/// themselves; everyone else tells us what has changed, which lands in
/// the control centre (Owner changes, Suggested updates).
///
/// With [tags] (nomadmaps.io/?tag=<slug>, the "Add a tag" button on a
/// listing page; Jonathan, 20 Oct 2026): it asks who you are first. The
/// people who run the space go to claiming it; someone who has worked
/// from it picks what the place has, which lands in the same Suggested
/// updates list as "Tags to add".
class UpdateScreen extends StatefulWidget {
  final String slug;
  final bool tags;
  const UpdateScreen({super.key, required this.slug, this.tags = false});
  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  /// Space either side of the 580 px column (set from the window width).
  double _side = 0;
  EdgeInsets get _listPadding =>
      EdgeInsets.fromLTRB(18 + _side, 18, 18 + _side, 18);
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

  // "Add a tag": false while asking who you are; true once a visitor
  // has said they have been there. The tags they picked.
  bool _visitor = false;
  final Set<String> _tags = {};

  /// The details the listing pages show as tags, in the site's words.
  static const _tagOptions = [
    'Fast WiFi',
    'Enough plug sockets',
    'Comfortable seating',
    'Office chairs',
    'Monitors available',
    'Quiet room or phone booth',
    'Good for video calls',
    'Aircon',
    'Low background music',
    'No traffic noise',
    'Cozy',
    'Day passes',
    'Meeting rooms',
    '24-hour access',
    'Good coffee',
    'Vegan friendly',
    'Gluten-free options',
    'Outdoor space',
    'Instagrammable',
  ];

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
      Analytics.capture(widget.tags ? 'tag_opened' : 'update_opened',
          {'venue': v['name'], 'slug': widget.slug});
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
    if (widget.tags && _tags.isEmpty && _details.text.trim().isEmpty) {
      setState(() => _error = 'Pick what it has, or tell us in a few words.');
      return;
    }
    if (!widget.tags && _kinds.isEmpty && _details.text.trim().isEmpty) {
      setState(() => _error = 'Pick what has changed, or tell us in a few words.');
      return;
    }
    // Tags travel as one report, kind "tags", the picked tags written
    // out first so the control centre and the phone ping show them.
    final note = _details.text.trim();
    final details = widget.tags
        ? [
            if (_tags.isNotEmpty)
              'Tags: ${_tagOptions.where(_tags.contains).join(', ')}',
            if (note.isNotEmpty) note,
          ].join('\n\n')
        : note;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _supabase.submitListingUpdate({
        'venue_id': v['id'],
        'kinds': widget.tags ? const ['tags'] : _kinds.toList(),
        'details': details,
        'last_visit': _lastVisit,
        'name': _name.text.trim(),
        'email': _email.text.trim(),
      });
      Analytics.capture(widget.tags ? 'tag_sent' : 'update_sent', {
        'venue': v['name'],
        'kinds': widget.tags ? _tags.join(',') : _kinds.join(','),
      });
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
        title: Text(widget.tags ? 'Add a tag' : 'Suggest an update'),
        leading: IconButton(
            tooltip: 'Back to the listing',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => launchUrl(Uri.parse(_pageUrl),
                mode: LaunchMode.platformDefault)),
      ),
      // The scrolling list spans the whole window, with the 580 px
      // column kept by its side padding, so the mouse wheel scrolls the
      // page wherever the pointer is (Leonie, 27 Oct 2026: it only
      // scrolled over the text, not the grey sides).
      body: LayoutBuilder(builder: (context, box) {
        _side = box.maxWidth > 580 ? (box.maxWidth - 580) / 2 : 0;
        Widget narrow(Widget w) => Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 580), child: w));
        return _loading
            ? const Center(child: CircularProgressIndicator(color: Brand.red))
            : v == null
                ? narrow(_notFound())
                : _sent
                    ? narrow(_thanks(v))
                    : !widget.tags
                        ? _form(v)
                        : _visitor
                            ? _tagForm(v)
                            : _whoAreYou(v);
      }),
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
                        '&from=${Uri.encodeQueryComponent(widget.tags ? '/tag' : '/update')}'),
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

  void _toClaim(Map<String, dynamic> v) {
    Analytics.capture('tag_to_claim', {'venue': v['name']});
    launchUrl(
        Uri.parse('https://nomadmaps.io/?claim='
            '${Uri.encodeQueryComponent(widget.slug)}'
            '&from=${Uri.encodeQueryComponent('/tag')}'),
        webOnlyWindowName: '_self');
  }

  /// One of the two answers to "who are you?", as a large tappable card.
  Widget _door(
          {required IconData icon,
          required String title,
          required String text,
          required VoidCallback onTap}) =>
      Material(
        color: Brand.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Brand.border)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
            child: Row(children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                    color: Brand.bg, borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 21, color: Brand.ink),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 15)),
                      const SizedBox(height: 3),
                      Text(text,
                          style: const TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: Brand.inkSecondary)),
                    ]),
              ),
              const Icon(Icons.chevron_right, color: Brand.inkMuted),
            ]),
          ),
        ),
      );

  /// "Add a tag", first step: who are you?
  Widget _whoAreYou(Map<String, dynamic> v) {
    final name = '${v['name']}';
    return ListView(padding: _listPadding, children: [
      Text('Add a tag to $name',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
      const SizedBox(height: 6),
      const Text('Tags tell nomads what a place has: plug sockets, a quiet '
          'room, aircon and more. Which describes you?',
          style: TextStyle(
              color: Brand.inkSecondary, fontSize: 13.5, height: 1.45)),
      const SizedBox(height: 18),
      _door(
          icon: Icons.storefront_outlined,
          title: 'I run $name',
          text: 'Claim your $_kind for free and add the tags yourself, '
              'with your photos, hours and prices.',
          onTap: () => _toClaim(v)),
      const SizedBox(height: 10),
      _door(
          icon: Icons.laptop_mac_outlined,
          title: 'I have worked from here',
          text: 'Tell us what it has, so the page is right for the next '
              'person. It takes a minute.',
          onTap: () {
            Analytics.capture('tag_visitor', {'venue': v['name']});
            setState(() => _visitor = true);
          }),
    ]);
  }

  /// "Add a tag", second step for someone who has been there.
  Widget _tagForm(Map<String, dynamic> v) {
    return ListView(padding: _listPadding, children: [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
            onPressed: () => setState(() {
                  _visitor = false;
                  _error = null;
                }),
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('Back')),
      ),
      Text('What does ${v['name']} have?',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
      const SizedBox(height: 4),
      const Text('Pick everything you saw there.',
          style: TextStyle(color: Brand.inkSecondary, fontSize: 13)),
      const SizedBox(height: 14),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final tag in _tagOptions)
          _chip(tag, _tags.contains(tag), () {
            setState(() =>
                _tags.contains(tag) ? _tags.remove(tag) : _tags.add(tag));
          }),
      ]),
      const SizedBox(height: 16),
      TextField(
          controller: _details,
          minLines: 2,
          maxLines: 6,
          decoration: const InputDecoration(
              labelText: 'Anything else? (optional)',
              hintText: 'e.g. WiFi about 80 Mbps; quiet in the mornings; '
                  'standing desks upstairs',
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
              helperText: 'Only if we have a question about what you sent.')),
      EmailTypoHint(controller: _email),
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
          label: Text(_sending ? 'Sending' : 'Send tags')),
      const SizedBox(height: 10),
      const Text('We check every tag before it goes on the page.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Brand.inkMuted, fontSize: 11.5)),
      const SizedBox(height: 40),
    ]);
  }

  Widget _form(Map<String, dynamic> v) {
    final where = [v['neighbourhood'], v['city']]
        .where((x) => x != null && '$x'.isNotEmpty)
        .join(', ');
    return ListView(padding: _listPadding, children: [
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
      EmailTypoHint(controller: _email),
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
