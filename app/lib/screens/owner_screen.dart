import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../services/analytics_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';

/// The Owner account at nomadmaps.io/?owner ("Nomadwise for Spaces"
/// to the owner; never "members area").
///
/// Sign in with the email an approved claim recorded on the space (a
/// link by email, or Google). Then: My listing (edit a draft of the
/// page with a live preview), the advert-slot message (Verified), and
/// Membership. Every change is a draft until a founder puts it on the
/// page. No analytics, no perks: decided with Leonie.
class OwnerScreen extends StatefulWidget {
  const OwnerScreen({super.key});

  @override
  State<OwnerScreen> createState() => _OwnerScreenState();
}

const double _wideAt = 960;

enum _Tab { listing, message, membership }

class _OwnerScreenState extends State<OwnerScreen> {
  final _supabase = SupabaseService();
  StreamSubscription? _auth;

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _venues = [];
  int _current = 0;
  _Tab _tab = _Tab.listing;

  // Sign-in form
  final _email = TextEditingController();
  bool _sending = false;
  bool _linkSent = false;

  // Editor state (one draft per space, rebuilt when the space changes)
  final _description = TextEditingController();
  final _priceDay = TextEditingController();
  final _priceWeek = TextEditingController();
  final _priceMonth = TextEditingController();
  final _priceCoffee = TextEditingController();
  final _website = TextEditingController();
  final _instagram = TextEditingController();
  final _whatsapp = TextEditingController();
  final _enquiryEmail = TextEditingController();
  final _hours = {for (final d in _days) d: TextEditingController()};
  final _facts = <String, bool?>{};
  List<String> _photos = [];
  final _mentionTitle = TextEditingController();
  final _mentionBody = TextEditingController();
  final _mentionCta = TextEditingController();
  final _mentionUrl = TextEditingController();
  String _mentionKind = 'Event';
  bool _dirty = false;
  bool _saving = false;
  String? _savedNote;

  static const _days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  static const _dayNames = {
    'mon': 'Monday',
    'tue': 'Tuesday',
    'wed': 'Wednesday',
    'thu': 'Thursday',
    'fri': 'Friday',
    'sat': 'Saturday',
    'sun': 'Sunday',
  };
  static const _factLabels = [
    ('laptops_allowed', 'Laptops welcome'),
    ('power_outlets', 'Plug sockets on most tables'),
    ('good_for_calls', 'Good for calls'),
    ('quiet_space', 'Quiet area'),
    ('comfortable_seating', 'Comfortable seating'),
    ('aircon', 'Aircon'),
    ('access_24h', '24 hour access'),
    ('call_room', 'Call room or booth'),
    ('monitor', 'Monitors available'),
    ('office_chairs', 'Office chairs'),
    ('cozy', 'Cozy'),
  ];

  Map<String, dynamic>? get _venue =>
      _venues.isEmpty ? null : _venues[_current.clamp(0, _venues.length - 1)];
  bool get _verified => _venue?['listing_tier'] == 'verified';
  Map<String, dynamic>? get _draft => (_venue?['draft'] is Map)
      ? Map<String, dynamic>.from(_venue!['draft'] as Map)
      : null;

  @override
  void initState() {
    super.initState();
    _auth = _supabase.authChanges.listen((_) => _load());
    _load();
    for (final c in [
      _description, _priceDay, _priceWeek, _priceMonth, _priceCoffee,
      _website, _instagram, _whatsapp, _enquiryEmail,
      _mentionTitle, _mentionBody, _mentionCta, _mentionUrl,
      ..._hours.values,
    ]) {
      c.addListener(() {
        if (!_dirty && mounted) setState(() => _dirty = true);
        if (mounted) setState(() {}); // live preview
      });
    }
  }

  @override
  void dispose() {
    _auth?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_supabase.signedIn) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final rows = await _supabase.ownerVenues();
      if (!mounted) return;
      setState(() {
        _venues = rows;
        _loading = false;
        _error = null;
        if (_current >= rows.length) _current = 0;
      });
      _fillEditor();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load your spaces: $e';
        });
      }
    }
  }

  /// The editor starts from the draft if there is one, else from what
  /// is on the page today.
  void _fillEditor() {
    final v = _venue;
    if (v == null) return;
    final draft = _draft;
    final d = (draft != null && draft['status'] != 'applied')
        ? Map<String, dynamic>.from(draft['draft'] as Map? ?? {})
        : <String, dynamic>{};
    final oc = Map<String, dynamic>.from(v['owner_content'] as Map? ?? {});
    String s(dynamic x) => (x ?? '').toString();
    final prices = Map<String, dynamic>.from(
        (d['prices'] ?? oc['prices'] ?? {}) as Map);
    _description.text = s(d['description'] ?? oc['description']);
    _priceDay.text = s(prices['day']);
    _priceWeek.text = s(prices['week']);
    _priceMonth.text = s(prices['month']);
    _priceCoffee.text = s(prices['coffee']);
    _website.text = s(d['website'] ?? v['website']);
    _instagram.text = s(d['instagram'] ?? v['instagram']);
    _whatsapp.text = s(d['whatsapp'] ?? oc['whatsapp']);
    _enquiryEmail.text = s(d['enquiry_email'] ?? v['listing_enquiry_email']);
    final hours = Map<String, dynamic>.from(
        (d['hours'] ?? v['opening_hours'] ?? {}) as Map);
    for (final day in _days) {
      _hours[day]!.text = s(hours[day]);
    }
    final facts = Map<String, dynamic>.from(
        (d['facts'] ?? v['facts'] ?? {}) as Map);
    _facts.clear();
    for (final (key, _) in _factLabels) {
      _facts[key] = facts[key] as bool?;
    }
    _photos = List<String>.from(
        (d['photos'] ?? oc['photos'] ?? const []) as List);
    final m = Map<String, dynamic>.from(
        (d['mention'] ?? oc['mention'] ?? {}) as Map);
    _mentionKind = ['Event', 'Offer', 'Announcement'].contains(m['kind'])
        ? m['kind']
        : 'Event';
    _mentionTitle.text = s(m['title']);
    _mentionBody.text = s(m['body']);
    _mentionCta.text = s(m['cta']);
    _mentionUrl.text = s(m['url']);
    _dirty = false;
    if (mounted) setState(() {});
  }

  Map<String, dynamic> _collect() => {
        'description': _description.text.trim(),
        'prices': {
          'day': _priceDay.text.trim(),
          'week': _priceWeek.text.trim(),
          'month': _priceMonth.text.trim(),
          'coffee': _priceCoffee.text.trim(),
        },
        'hours': {
          for (final day in _days)
            if (_hours[day]!.text.trim().isNotEmpty)
              day: _hours[day]!.text.trim()
        },
        'facts': {
          for (final e in _facts.entries)
            if (e.value != null) e.key: e.value
        },
        'website': _website.text.trim(),
        'instagram': _instagram.text.trim(),
        'whatsapp': _whatsapp.text.trim(),
        'enquiry_email': _enquiryEmail.text.trim(),
        'photos': _photos,
        if (_verified)
          'mention': {
            'kind': _mentionKind,
            'title': _mentionTitle.text.trim(),
            'body': _mentionBody.text.trim(),
            'cta': _mentionCta.text.trim(),
            'url': _mentionUrl.text.trim(),
          },
      };

  Future<void> _save({required bool submit}) async {
    final v = _venue;
    if (v == null) return;
    final url = _mentionUrl.text.trim();
    if (submit && _verified && _mentionTitle.text.trim().isNotEmpty &&
        url.isNotEmpty && !url.startsWith('http')) {
      setState(() => _savedNote =
          'The message link needs to start with https://');
      return;
    }
    setState(() {
      _saving = true;
      _savedNote = null;
    });
    try {
      await _supabase.ownerSaveDraft(v['id'], _collect(), submit: submit);
      Analytics.capture(submit ? 'owner_submitted' : 'owner_saved',
          {'space': v['name']});
      await _load();
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _savedNote = submit
            ? 'Sent for review. We read every change before it goes on '
                'the page, usually within a day or two.'
            : 'Draft saved. Nothing changes on the page until you submit.';
      });
    } catch (e) {
      if (mounted) setState(() => _savedNote = 'That did not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addPhotos() async {
    if (_photos.length >= 5) {
      setState(() => _savedNote = 'Five photos is the limit for a page.');
      return;
    }
    try {
      final picked = await ImagePicker().pickMultiImage(
          maxWidth: 1600, maxHeight: 1600, imageQuality: 85);
      if (picked.isEmpty) return;
      setState(() => _saving = true);
      for (final x in picked.take(5 - _photos.length)) {
        final bytes = await x.readAsBytes();
        final ext = x.name.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
        final link = await _supabase.ownerUploadPhoto(bytes, ext);
        _photos.add(link);
      }
      _dirty = true;
    } catch (e) {
      _savedNote = 'Could not add the photo: $e';
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---------------------------------------------------------------- sign in

  Future<void> _sendLink() async {
    final email = _email.text.trim().toLowerCase();
    if (!email.contains('@') || email.length < 5) {
      setState(() => _error = 'A working email address is needed.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _supabase.sendSignInLink(email);
      if (mounted) setState(() => _linkSent = true);
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            'The link could not be sent just now. Try again in a minute, '
            'or sign in with Google below.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(
        titleSpacing: 20,
        title: Row(children: [
          const Text('nomadwise',
              style: TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 20, color: Brand.red)),
          const SizedBox(width: 8),
          Text('for spaces',
              style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: Brand.inkSecondary)),
        ]),
        actions: [
          if (_supabase.signedIn)
            TextButton(
                onPressed: () async {
                  await _supabase.signOut();
                  if (mounted) {
                    setState(() {
                      _venues = [];
                      _linkSent = false;
                    });
                  }
                },
                child: const Text('Sign out')),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= _wideAt;
        if (_loading) {
          return const Center(
              child: CircularProgressIndicator(color: Brand.red));
        }
        if (!_supabase.signedIn) return _signIn(wide);
        if (_venues.isEmpty) return _noSpaces(wide);
        return _account(wide);
      }),
    );
  }

  Widget _frame(bool wide, Widget child, {double maxWidth = 1100}) =>
      SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(wide ? 28 : 16, wide ? 22 : 12,
            wide ? 28 : 16, 40),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth), child: child),
        ),
      );

  Widget _panel({required Widget child, Color? tint, double pad = 22}) =>
      Container(
        padding: EdgeInsets.all(pad),
        decoration: BoxDecoration(
          color: tint ?? Brand.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Brand.border),
        ),
        child: child,
      );

  Widget _signIn(bool wide) => _frame(
        wide,
        maxWidth: 520,
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: wide ? 60 : 16),
          Text('Owner account',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: wide ? 30 : 24,
                  letterSpacing: -0.5)),
          const SizedBox(height: 8),
          const Text(
              'Manage your listing on nomadwise.io: your description, '
              'prices, hours, photos and facts. Sign in with the email you '
              'used to claim your space; no password.',
              style: TextStyle(
                  color: Brand.inkSecondary, fontSize: 14.5, height: 1.5)),
          const SizedBox(height: 22),
          _panel(
            child: _linkSent
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                        const Icon(Icons.mark_email_read_outlined,
                            color: Brand.success, size: 30),
                        const SizedBox(height: 10),
                        const Text('Check your inbox',
                            style: TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 17)),
                        const SizedBox(height: 6),
                        Text(
                            'We sent a sign-in link to ${_email.text.trim()}. '
                            'Open it on this device and you are in. It can '
                            'take a minute; check spam if it does not show.',
                            style: const TextStyle(
                                fontSize: 13.5,
                                height: 1.5,
                                color: Brand.inkSecondary)),
                        const SizedBox(height: 12),
                        TextButton(
                            onPressed: () => setState(() => _linkSent = false),
                            child: const Text('Use a different email')),
                      ])
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                        TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(
                              labelText: 'Your email',
                              hintText: 'you@yourspace.com',
                              border: OutlineInputBorder()),
                          onSubmitted: (_) => _sendLink(),
                        ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(_error!,
                                style: const TextStyle(
                                    color: Brand.red, fontSize: 13)),
                          ),
                        const SizedBox(height: 14),
                        FilledButton(
                          onPressed: _sending ? null : _sendLink,
                          style: FilledButton.styleFrom(
                              backgroundColor: Brand.red,
                              minimumSize: const Size.fromHeight(50)),
                          child: Text(
                              _sending ? 'One moment' : 'Email me a sign-in link',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 15)),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: () => _supabase
                              .signInWithGoogleTo(AppConfig.ownerAccountUrl),
                          style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(46)),
                          icon: const Icon(Icons.login, size: 18),
                          label: const Text('Continue with Google'),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                            'Google works when your space was claimed with a '
                            'Google address. Otherwise use the email link.',
                            style: TextStyle(
                                color: Brand.inkMuted, fontSize: 12)),
                      ]),
          ),
          const SizedBox(height: 18),
          Text(
              'Not claimed your space yet? Start at nomadmaps.io/claim. '
              'Questions: hello@nomadwise.io',
              style: TextStyle(color: Brand.inkMuted, fontSize: 12.5)),
        ]),
      );

  Widget _noSpaces(bool wide) => _frame(
        wide,
        maxWidth: 520,
        _panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('No space on this account yet',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(height: 8),
            Text(
                'You are signed in as ${_supabase.userEmail ?? ''}. A space '
                'appears here once a claim made with this email has been '
                'approved. If you claimed with a different address, sign '
                'out and use that one. If you have not claimed yet, the '
                'claim form takes two minutes.',
                style: const TextStyle(
                    fontSize: 13.5, height: 1.5, color: Brand.inkSecondary)),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(
                  onPressed: () => launchUrl(
                      Uri.parse('https://nomadmaps.io/?claim'),
                      webOnlyWindowName: '_self'),
                  style: FilledButton.styleFrom(backgroundColor: Brand.red),
                  child: const Text('Claim my space')),
              OutlinedButton(
                  onPressed: _load, child: const Text('Check again')),
            ]),
          ]),
        ),
      );

  // ---------------------------------------------------------------- account

  Widget _account(bool wide) {
    final v = _venue!;
    final nav = _nav(wide);
    // Every tab has the same shape: the main panel on the left, the
    // page preview on the right, so switching tabs never moves the
    // furniture.
    final main = switch (_tab) {
      _Tab.listing => _listingTab(wide),
      _Tab.message => _messageTab(wide),
      _Tab.membership => _membershipTab(wide),
    };
    final side = _tab == _Tab.message && _verified
        ? _messagePreview()
        : _preview();
    final body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statusBanner(),
          if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: main),
              const SizedBox(width: 18),
              Expanded(flex: 2, child: side),
            ])
          else ...[
            main,
            const SizedBox(height: 16),
            side,
          ],
        ]);
    return _frame(
      wide,
      maxWidth: 1180,
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.storefront_outlined,
              size: 18, color: Brand.inkSecondary),
          const SizedBox(width: 8),
          if (_venues.length > 1)
            DropdownButton<int>(
              value: _current,
              underline: const SizedBox.shrink(),
              items: [
                for (var i = 0; i < _venues.length; i++)
                  DropdownMenuItem(
                      value: i,
                      child: Text('${_venues[i]['name']}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15)))
              ],
              onChanged: (i) {
                if (i == null) return;
                setState(() => _current = i);
                _fillEditor();
              },
            )
          else
            Text('${v['name']}',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(width: 8),
          _chip(_verified ? 'Verified' : 'Free listing',
              _verified ? Brand.success : Brand.inkSecondary),
          const Spacer(),
          if (v['webflow_slug'] != null)
            TextButton.icon(
                onPressed: () => launchUrl(
                    Uri.parse(
                        'https://www.nomadwise.io/coworking/${v['webflow_slug']}'),
                    mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new, size: 15),
                label: const Text('See my page')),
        ]),
        const SizedBox(height: 14),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 210, child: nav),
            const SizedBox(width: 20),
            Expanded(child: body),
          ])
        else ...[
          nav,
          const SizedBox(height: 14),
          body,
        ],
      ]),
    );
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(8)),
        child: Text(text,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w800, color: color)),
      );

  Widget _nav(bool wide) {
    final items = [
      (_Tab.listing, Icons.edit_note_outlined, 'My listing'),
      (_Tab.message, Icons.campaign_outlined, 'Your message'),
      (_Tab.membership, Icons.workspace_premium_outlined, 'Membership'),
    ];
    Widget tile((_Tab, IconData, String) it) {
      final on = _tab == it.$1;
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _tab = it.$1),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
              color: on ? Brand.accentTint : Colors.transparent,
              borderRadius: BorderRadius.circular(12)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(it.$2, size: 19, color: on ? Brand.red : Brand.inkSecondary),
            const SizedBox(width: 10),
            Text(it.$3,
                style: TextStyle(
                    fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                    color: on ? Brand.red : Brand.ink,
                    fontSize: 14)),
          ]),
        ),
      );
    }

    if (!wide) {
      return Wrap(spacing: 6, children: items.map(tile).toList());
    }
    return _panel(
      pad: 10,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...items.map(tile),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                  'Signed in as\n${_supabase.userEmail ?? ''}',
                  style: const TextStyle(
                      fontSize: 11.5, color: Brand.inkMuted, height: 1.4)),
            ),
            const SizedBox(height: 6),
          ]),
    );
  }

  // --------------------------------------------------------------- listing

  Widget _statusBanner() {
    final d = _draft;
    if (d == null) return const SizedBox.shrink();
    final status = d['status'];
    final (Color color, IconData icon, String text) = switch (status) {
      'submitted' => (
          Brand.goldTextDark,
          Icons.hourglass_top,
          'Your changes are with us for review. You can keep editing; '
              'submitting again replaces what we have.'
        ),
      'declined' => (
          Brand.red,
          Icons.undo,
          'We sent your last changes back'
              '${(d['review_note'] ?? '').toString().isNotEmpty ? ': ${d['review_note']}' : '.'}'
              ' Edit and submit again when ready.'
        ),
      'applied' => (
          Brand.success,
          Icons.check_circle_outline,
          'Your last changes are on the page.'
        ),
      _ => (
          Brand.inkSecondary,
          Icons.edit_outlined,
          'You have a saved draft that has not been submitted.'
        ),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, height: 1.45, color: color))),
      ]),
    );
  }

  InputDecoration _dec(String label, {String? hint}) => InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
      isDense: true);

  Widget _listingTab(bool wide) {
    final editor = _panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Your listing details',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        const SizedBox(height: 4),
        const Text(
            'What nomads read before they choose you. We read every change '
            'before it goes on the page: facts and photos are yours, the '
            'tone stays honest.',
            style: TextStyle(
                color: Brand.inkSecondary, fontSize: 12.5, height: 1.45)),
        const SizedBox(height: 18),
        TextField(
            controller: _description,
            minLines: 4,
            maxLines: 10,
            maxLength: 3000,
            decoration: _dec('What makes your space special?',
                hint: 'The workspace, the atmosphere, the people. Plain '
                    'words work best.')),
        const SizedBox(height: 14),
        Text(_venue?['type'] == 'cafe' ? 'Prices' : 'Passes and prices',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: [
          if (_venue?['type'] != 'cafe') ...[
            SizedBox(
                width: 200,
                child: TextField(
                    controller: _priceDay,
                    decoration: _dec('Day pass', hint: 'e.g. 15 EUR'))),
            SizedBox(
                width: 200,
                child: TextField(
                    controller: _priceWeek,
                    decoration: _dec('Week pass', hint: 'e.g. 60 EUR'))),
            SizedBox(
                width: 200,
                child: TextField(
                    controller: _priceMonth,
                    decoration: _dec('Month pass', hint: 'e.g. 180 EUR'))),
          ],
          SizedBox(
              width: 200,
              child: TextField(
                  controller: _priceCoffee,
                  decoration: _dec('Cappuccino', hint: 'e.g. 3.50 EUR'))),
        ]),
        const SizedBox(height: 18),
        const Text('Opening hours',
            style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Text('Write times like 8:00 AM - 6:00 PM, or Closed. Leave a '
            'day blank to keep what Google shows.',
            style: TextStyle(color: Brand.inkMuted, fontSize: 12)),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (final day in _days)
            SizedBox(
                width: 200,
                child: TextField(
                    controller: _hours[day],
                    decoration: _dec(_dayNames[day]!))),
        ]),
        const SizedBox(height: 18),
        const Text('Work-friendly facts',
            style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Wrap(spacing: 4, runSpacing: 0, children: [
          for (final (key, label) in _factLabels)
            SizedBox(
              width: 250,
              child: CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(label, style: const TextStyle(fontSize: 13.5)),
                value: _facts[key] == true,
                onChanged: (x) => setState(() {
                  _facts[key] = x == true;
                  _dirty = true;
                }),
              ),
            ),
        ]),
        const SizedBox(height: 14),
        const Text('Photos', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Text('Up to five of your own. They replace the Google photos '
            'on your page once approved.',
            style: TextStyle(color: Brand.inkMuted, fontSize: 12)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final p in _photos)
            Stack(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(p,
                    width: 110, height: 82, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                        width: 110,
                        height: 82,
                        color: Brand.field,
                        child: const Icon(Icons.broken_image_outlined))),
              ),
              Positioned(
                right: 2,
                top: 2,
                child: InkWell(
                  onTap: () => setState(() {
                    _photos.remove(p);
                    _dirty = true;
                  }),
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(
                        color: Colors.black54, shape: BoxShape.circle),
                    child: const Icon(Icons.close,
                        size: 14, color: Colors.white),
                  ),
                ),
              ),
            ]),
          OutlinedButton.icon(
              onPressed: _saving ? null : _addPhotos,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: const Text('Add photos')),
        ]),
        const SizedBox(height: 18),
        const Text('Contact', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: [
          SizedBox(
              width: 260,
              child: TextField(
                  controller: _website,
                  decoration: _dec('Website', hint: 'yourspace.com'))),
          SizedBox(
              width: 260,
              child: TextField(
                  controller: _instagram,
                  decoration: _dec('Instagram', hint: '@yourspace'))),
          SizedBox(
              width: 260,
              child: TextField(
                  controller: _whatsapp,
                  decoration: _dec('WhatsApp number',
                      hint: '+351 900 000 000'))),
          if (_verified)
            SizedBox(
                width: 260,
                child: TextField(
                    controller: _enquiryEmail,
                    decoration: _dec('Booking requests go to',
                        hint: 'bookings@yourspace.com'))),
        ]),
        const SizedBox(height: 22),
        if (_savedNote != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(_savedNote!,
                style: TextStyle(
                    fontSize: 13,
                    color: _savedNote!.startsWith('That') ||
                            _savedNote!.startsWith('The ') ||
                            _savedNote!.startsWith('Could')
                        ? Brand.red
                        : Brand.success)),
          ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(
              onPressed: _saving ? null : () => _save(submit: false),
              child: const Text('Save draft')),
          FilledButton(
              onPressed: _saving ? null : () => _save(submit: true),
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              child: Text(_saving ? 'One moment' : 'Submit for review')),
        ]),
        const SizedBox(height: 8),
        const Text(
            'Ratings, reviews and WiFi tests come from Google and from '
            'nomads; they stay as they are.',
            style: TextStyle(color: Brand.inkMuted, fontSize: 12)),
      ]),
    );
    return editor;
  }

  /// A plain picture of what the page will show, updated as they type.
  Widget _preview() {
    final v = _venue!;
    final where = [v['neighbourhood'], v['city']]
        .where((x) => (x ?? '').toString().isNotEmpty)
        .join(', ');
    final on = [
      for (final (key, label) in _factLabels)
        if (_facts[key] == true) label
    ];
    final photos = _photos.isNotEmpty
        ? _photos
        : List<String>.from((v['google_photos'] ?? const []) as List);
    final prices = [
      if (_priceDay.text.trim().isNotEmpty) ('Day pass', _priceDay.text),
      if (_priceWeek.text.trim().isNotEmpty) ('Week pass', _priceWeek.text),
      if (_priceMonth.text.trim().isNotEmpty) ('Month pass', _priceMonth.text),
      if (_priceCoffee.text.trim().isNotEmpty) ('Cappuccino', _priceCoffee.text),
    ];
    return _panel(
      tint: Brand.bg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Page preview',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const Spacer(),
          if (_dirty)
            const Text('Unsaved edits',
                style: TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
        ]),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: photos.isEmpty
              ? Container(
                  height: 150,
                  color: Brand.field,
                  alignment: Alignment.center,
                  child: const Text('No photo yet',
                      style: TextStyle(color: Brand.inkMuted)))
              : Image.network(photos.first,
                  height: 150,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      Container(height: 150, color: Brand.field)),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: Text('${v['name']}',
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 18)),
          ),
          if (_verified) _chip('Verified', Brand.success),
        ]),
        if (where.isNotEmpty)
          Text(where,
              style: const TextStyle(fontSize: 12.5, color: Brand.inkSecondary)),
        if (v['google_rating_snapshot'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                '★ ${v['google_rating_snapshot']} (${v['google_reviews_snapshot'] ?? 0})'
                '${v['wifi_speed_mbps'] != null ? '  ·  WiFi ${v['wifi_speed_mbps']} Mbps' : ''}',
                style: const TextStyle(
                    fontSize: 12.5, color: Brand.goldTextDark)),
          ),
        const SizedBox(height: 10),
        Text(
            _description.text.trim().isEmpty
                ? 'Your description appears here.'
                : _description.text.trim(),
            style: TextStyle(
                fontSize: 13.5,
                height: 1.5,
                color: _description.text.trim().isEmpty
                    ? Brand.inkMuted
                    : Brand.ink)),
        if (on.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final f in on)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                    color: Brand.successTint,
                    borderRadius: BorderRadius.circular(8)),
                child: Text(f,
                    style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Brand.success)),
              ),
          ]),
        ],
        if (prices.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final (label, val) in prices)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 13, color: Brand.inkSecondary)),
                const Spacer(),
                Text(val.trim(),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ]),
            ),
        ],
        const SizedBox(height: 12),
        for (final day in _days)
          if (_hours[day]!.text.trim().isNotEmpty)
            Row(children: [
              Text(_dayNames[day]!,
                  style: const TextStyle(
                      fontSize: 12.5, color: Brand.inkSecondary)),
              const Spacer(),
              Text(_hours[day]!.text.trim(),
                  style: const TextStyle(fontSize: 12.5)),
            ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (_verified)
            _fakeButton('Request a booking', filled: true)
          else
            _fakeButton('Contact the space', filled: true),
          if (_website.text.trim().isNotEmpty) _fakeButton('Website'),
          if (_whatsapp.text.trim().isNotEmpty) _fakeButton('WhatsApp'),
        ]),
        if (_verified && _mentionTitle.text.trim().isNotEmpty) ...[
          const SizedBox(height: 14),
          _mentionCard(),
        ],
      ]),
    );
  }

  Widget _fakeButton(String label, {bool filled = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: filled ? Brand.red : Colors.transparent,
            border: Border.all(color: filled ? Brand.red : Brand.border),
            borderRadius: BorderRadius.circular(8)),
        child: Text(label,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: filled ? Colors.white : Brand.ink)),
      );

  Widget _mentionCard() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Brand.successTint,
            borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('FROM ${(_venue?['name'] ?? '').toString().toUpperCase()}',
              style: const TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 1,
                  fontWeight: FontWeight.w800,
                  color: Brand.success)),
          const SizedBox(height: 4),
          Text(_mentionKind,
              style: const TextStyle(fontSize: 11.5, color: Brand.inkSecondary)),
          const SizedBox(height: 4),
          Text(_mentionTitle.text.trim(),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          if (_mentionBody.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_mentionBody.text.trim(),
                  style: const TextStyle(fontSize: 13, height: 1.45)),
            ),
          const SizedBox(height: 10),
          _fakeButton(
              _mentionCta.text.trim().isEmpty
                  ? 'Find out more'
                  : _mentionCta.text.trim(),
              filled: true),
        ]),
      );

  // --------------------------------------------------------------- message

  Widget _messageTab(bool wide) {
    if (!_verified) {
      return _panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Your message, in place of an advert',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 8),
          const Text(
              'Verified pages carry the space\'s own event, offer or '
              'announcement where nomadwise.io would otherwise show an '
              'advert. Yours shows the advert. Go Verified and this tab '
              'opens up, along with the badge, a place above every free '
              'listing, booking requests to your inbox and your own photos '
              'and words.',
              style: TextStyle(
                  fontSize: 13.5, height: 1.5, color: Brand.inkSecondary)),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: () => launchUrl(
                  Uri.parse('https://nomadmaps.io/?claim'),
                  webOnlyWindowName: '_self'),
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              child: const Text('Go Verified, 99 EUR a year')),
        ]),
      );
    }
    final editor = _panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Your message, in place of an advert',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
        const SizedBox(height: 4),
        const Text(
            'An event, an offer or an announcement. It replaces the advert '
            'slot on your page. Other placements on the site stay. We read '
            'it before it goes on, like everything else.',
            style: TextStyle(
                color: Brand.inkSecondary, fontSize: 12.5, height: 1.45)),
        const SizedBox(height: 18),
        Wrap(spacing: 10, runSpacing: 10, children: [
          SizedBox(
            width: 220,
            child: DropdownButtonFormField<String>(
              value: _mentionKind,
              decoration: _dec('Kind'),
              items: const [
                DropdownMenuItem(value: 'Event', child: Text('Event')),
                DropdownMenuItem(value: 'Offer', child: Text('Offer')),
                DropdownMenuItem(
                    value: 'Announcement', child: Text('Announcement')),
              ],
              onChanged: (x) => setState(() {
                _mentionKind = x ?? 'Event';
                _dirty = true;
              }),
            ),
          ),
          SizedBox(
              width: 220,
              child: TextField(
                  controller: _mentionCta,
                  maxLength: 40,
                  decoration: _dec('Button label',
                      hint: 'See our next event'))),
        ]),
        const SizedBox(height: 10),
        TextField(
            controller: _mentionTitle,
            maxLength: 90,
            decoration: _dec('Headline',
                hint: 'Join our Friday community lunch')),
        const SizedBox(height: 10),
        TextField(
            controller: _mentionBody,
            minLines: 2,
            maxLines: 5,
            maxLength: 300,
            decoration: _dec('Message',
                hint: 'Meet other remote workers over a relaxed lunch at '
                    'our space. Everyone is welcome.')),
        const SizedBox(height: 10),
        TextField(
            controller: _mentionUrl,
            decoration:
                _dec('Link', hint: 'https://yourspace.com/events')),
        const SizedBox(height: 16),
        if (_savedNote != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(_savedNote!,
                style: const TextStyle(fontSize: 13, color: Brand.inkSecondary)),
          ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton(
              onPressed: _saving ? null : () => _save(submit: false),
              child: const Text('Save draft')),
          FilledButton(
              onPressed: _saving ? null : () => _save(submit: true),
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              child: Text(_saving ? 'One moment' : 'Submit for review')),
        ]),
        const SizedBox(height: 8),
        const Text('To take the message down, clear the headline and submit.',
            style: TextStyle(color: Brand.inkMuted, fontSize: 12)),
      ]),
    );
    return editor;
  }

  Widget _messagePreview() => _panel(
        tint: Brand.bg,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('What nomads see',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 4),
          const Text('In the advert slot on your page.',
              style: TextStyle(color: Brand.inkMuted, fontSize: 12)),
          const SizedBox(height: 12),
          if (_mentionTitle.text.trim().isEmpty)
            const Text('Write a headline and it appears here.',
                style: TextStyle(color: Brand.inkMuted, fontSize: 13))
          else
            _mentionCard(),
        ]),
      );

  // ------------------------------------------------------------ membership

  Widget _membershipTab(bool wide) {
    final v = _venue!;
    String date(dynamic x) {
      final d = DateTime.tryParse('$x');
      if (d == null) return '';
      const m = [
        'January', 'February', 'March', 'April', 'May', 'June', 'July',
        'August', 'September', 'October', 'November', 'December'
      ];
      return '${d.day} ${m[d.month - 1]} ${d.year}';
    }

    final rows = const [
      'The Verified badge on your page and in every list you appear in',
      'A place above every free listing in your city and area',
      'Booking requests sent straight to your inbox, no commission',
      'Your own photos, description and prices instead of Google\'s',
      'Your event or offer in the advert slot on your page',
    ];
    return _panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(_verified ? 'Your Verified membership' : 'Your free listing',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(width: 10),
          _chip(_verified ? 'Active' : 'Free',
              _verified ? Brand.success : Brand.inkSecondary),
        ]),
        const SizedBox(height: 14),
        if (_verified) ...[
          Text(
              'Verified since ${date(v['listing_paid_at'])}. Renews on '
              '${date(v['listing_renews_at'])} at 99 EUR, billed once a year '
              'through Stripe.',
              style: const TextStyle(fontSize: 13.5, height: 1.5)),
          const SizedBox(height: 14),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.check, size: 16, color: Brand.success),
                const SizedBox(width: 8),
                Expanded(child: Text(r, style: const TextStyle(fontSize: 13.5))),
              ]),
            ),
          const SizedBox(height: 14),
          const Text(
              'Cancel any time; the listing stays and goes back to the free '
              'plan at the end of the paid year. Your card and receipts are '
              'managed by Stripe.',
              style: TextStyle(
                  fontSize: 13, height: 1.5, color: Brand.inkSecondary)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (AppConfig.stripePortalLink.isNotEmpty)
              OutlinedButton.icon(
                  onPressed: () => launchUrl(
                      Uri.parse(AppConfig.stripePortalLink),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.credit_card, size: 18),
                  label: const Text('Manage billing'))
            else
              const Text(
                  'To change your card or cancel renewal, use the link in '
                  'your Stripe receipt, or email hello@nomadwise.io.',
                  style: TextStyle(fontSize: 13, color: Brand.inkSecondary)),
          ]),
        ] else ...[
          const Text(
              'Your page is on nomadwise.io for free and stays free. As its '
              'owner you can correct the facts and add your description, '
              'prices, hours and photos from My listing.',
              style: TextStyle(fontSize: 13.5, height: 1.5)),
          const SizedBox(height: 14),
          const Text('Verified, 99 EUR a year, adds:',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.check, size: 16, color: Brand.success),
                const SizedBox(width: 8),
                Expanded(child: Text(r, style: const TextStyle(fontSize: 13.5))),
              ]),
            ),
          const SizedBox(height: 14),
          FilledButton(
              onPressed: () => launchUrl(
                  Uri.parse(
                      'https://nomadmaps.io/?claim=${Uri.encodeComponent('${v['webflow_slug'] ?? v['name']}')}'),
                  webOnlyWindowName: '_self'),
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              child: const Text('Go Verified')),
          const SizedBox(height: 8),
          const Text('Billed once a year. Cancel any time.',
              style: TextStyle(color: Brand.inkMuted, fontSize: 12)),
        ],
      ]),
    );
  }
}
