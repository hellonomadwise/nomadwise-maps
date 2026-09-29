import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../services/analytics_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/currencies.dart';
import '../widgets/owner_question_card.dart';
import '../widgets/price.dart';

/// The Owner account at nomadmaps.io/?owner ("Nomadwise for Spaces"
/// to the owner; never "members area").
///
/// Sign in with the email an approved claim recorded on the space (a
/// link by email, or Google). Then: My listing (edit a draft of the
/// page with a live preview), the advert-slot message (Verified), and
/// Membership. Every change is a draft until a founder puts it on the
/// page. No analytics, no perks: decided with Leonie.
class OwnerScreen extends StatefulWidget {
  /// Founders only: open this listing's Owner account (venue id or
  /// page slug) in preview, whoever owns it. Nothing is saved.
  final String? previewKey;
  const OwnerScreen({super.key, this.previewKey});

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

  // ---- founders' preview (?owner&preview=<slug>) ----
  bool get _isPreview => widget.previewKey != null;
  Map<String, dynamic>? _previewBase; // the listing as it is
  // What the owner would see: 'waiting_free' / 'waiting_paid' (claimed,
  // not checked yet: the blurred account), 'free' or 'verified'.
  String _previewAs = 'free';
  int _current = 0;
  _Tab _tab = _Tab.listing;

  // Sign-in form
  final _email = TextEditingController();
  bool _sending = false;
  bool _linkSent = false;

  /// Claims made with this email that we have not approved yet: shown
  /// with where they stand instead of "no space on this account".
  List<Map<String, dynamic>> _pending = [];

  /// The claim made on this device (email, claim id, and when the
  /// owner came back from Stripe), for the "confirming" state.
  Map<String, dynamic>? _lastClaim;

  /// While a payment is being confirmed, the page checks again by
  /// itself every few seconds.
  Timer? _poll;

  // Editor state (one draft per space, rebuilt when the space changes)
  final _description = TextEditingController();
  final _priceDay = TextEditingController();
  final _priceWeek = TextEditingController();
  final _priceMonth = TextEditingController();
  final _priceCoffee = TextEditingController();
  // The prices' currency: the country's own unless the owner changes
  // it. Owners type the amount only; the page gets "€3.60" or "900 LKR".
  String _currency = 'EUR';
  // "Bookmark this page" tip, until the owner says Got it.
  bool _showTip = false;
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
  // Autosave: edits are kept as a draft a few seconds after typing
  // stops, so leaving the page (to Go Verified, say) loses nothing
  // (Leonie's review, 28 Sep).
  Timer? _autoTimer;
  bool _autosaving = false;
  int _editSeq = 0;
  DateTime _lastEdit = DateTime(2000);
  DateTime? _autoSavedAt;

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
    _prefillEmail();
    SharedPreferences.getInstance().then((p) {
      if (mounted) {
        setState(() => _showTip = !(p.getBool('owner_bookmark_tip') ?? false));
      }
    }).catchError((_) {});
    for (final c in [
      _description, _priceDay, _priceWeek, _priceMonth, _priceCoffee,
      _website, _instagram, _whatsapp, _enquiryEmail,
      _mentionTitle, _mentionBody, _mentionCta, _mentionUrl,
      ..._hours.values,
    ]) {
      c.addListener(() {
        _editSeq++;
        _lastEdit = DateTime.now();
        if (!_dirty && mounted) setState(() => _dirty = true);
        if (mounted) setState(() {}); // live preview
      });
    }
    _autoTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_dirty &&
          DateTime.now().difference(_lastEdit) > const Duration(seconds: 2)) {
        _autosave();
      }
    });
  }

  /// Keep the edits as a draft, quietly. Nothing changes on the page;
  /// the editor is not reloaded (that would move the cursor).
  Future<void> _autosave() async {
    if (_isPreview) return;
    final v = _venue;
    if (v == null || !_dirty || _saving || _autosaving) return;
    if (!_supabase.signedIn) return;
    _autosaving = true;
    final seq = _editSeq;
    final data = _collect();
    if (mounted) setState(() {});
    try {
      final res = await _supabase.ownerSaveDraft(v['id'], data, submit: false);
      if (!mounted) return;
      setState(() {
        if (_editSeq == seq) _dirty = false;
        _autoSavedAt = DateTime.now();
        v['draft'] = {
          ...?(v['draft'] is Map
              ? Map<String, dynamic>.from(v['draft'] as Map)
              : null),
          'id': res['id'],
          'status': res['status'],
          'draft': data,
        };
      });
    } catch (_) {
      // Stays "unsaved"; the next tick tries again.
    } finally {
      _autosaving = false;
      if (mounted) setState(() {});
    }
  }

  /// Save now, then go: for links that leave the page.
  Future<void> _saveThenOpen(String url) async {
    if (_isPreview) {
      setState(() => _savedNote = 'Preview: this would open $url');
      return;
    }
    await _autosave();
    await launchUrl(Uri.parse(url), webOnlyWindowName: '_self');
  }

  @override
  void dispose() {
    _auth?.cancel();
    _poll?.cancel();
    _autoTimer?.cancel();
    super.dispose();
  }

  /// The email they claimed with, from the link (?email=) or from the
  /// claim made on this device, so signing in is one tap.
  Future<void> _prefillEmail() async {
    var em = '';
    try {
      em = Uri.base.queryParameters['email'] ?? '';
    } catch (_) {}
    _lastClaim = await SupabaseService.lastClaim();
    if (mounted) setState(() {});
    if (!em.contains('@')) {
      em = '${_lastClaim?['email'] ?? ''}';
    }
    final found = em.trim().toLowerCase();
    if (found.contains('@') && _email.text.trim().isEmpty && mounted) {
      setState(() => _email.text = found);
    }
  }

  Future<void> _load() async {
    if (!_supabase.signedIn) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    if (_isPreview) return _loadPreview();
    try {
      final rows = await _supabase.ownerVenues();
      final pending = await _supabase.ownerPendingClaims();
      if (!mounted) return;
      _watchPayments(pending);
      setState(() {
        _venues = rows;
        _pending = pending;
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

  Future<void> _loadPreview() async {
    try {
      final v = await _supabase.adminOwnerView(widget.previewKey!);
      if (!mounted) return;
      if (v == null) {
        setState(() {
          _loading = false;
          _error = 'No listing found for "${widget.previewKey}".';
        });
        return;
      }
      _previewBase = v;
      _previewAs = v['listing_tier'] == 'verified' ? 'verified' : 'free';
      _applyPreview();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e'.contains('admin only')
              ? 'Only Nomadwise founders can preview Owner accounts. Sign '
                  'in with your founder account.'
              : 'Could not load the preview: $e';
        });
      }
    }
  }

  /// Lay the preview out as the chosen state.
  void _applyPreview() {
    final b = _previewBase;
    if (b == null) return;
    final waiting = _previewAs.startsWith('waiting');
    setState(() {
      _loading = false;
      _error = null;
      _venues = waiting
          ? []
          : [
              {
                ...b,
                'listing_tier': _previewAs == 'verified' ? 'verified' : 'free'
              }
            ];
      _pending = waiting
          ? [
              {
                'claim_id': 'preview',
                'venue_id': b['id'],
                'name': b['name'],
                'type': b['type'],
                'city': b['city'],
                'neighbourhood': b['neighbourhood'],
                'plan': _previewAs == 'waiting_paid' ? 'verified' : 'free',
                'status': _previewAs == 'waiting_paid'
                    ? 'awaiting_approval'
                    : 'free_pending',
                'paid': _previewAs == 'waiting_paid',
              }
            ]
          : [];
      _current = 0;
    });
    if (!waiting) _fillEditor();
  }

  /// The founders' bar above a preview: which state to look at, and
  /// the reminder that nothing here is saved.
  Widget _previewBar() {
    const states = [
      ('waiting_free', 'Claimed free, not checked'),
      ('waiting_paid', 'Paid, not checked'),
      ('free', 'Free listing'),
      ('verified', 'Verified'),
    ];
    return Container(
      width: double.infinity,
      color: Brand.ink,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('FOUNDER PREVIEW. Nothing here is saved. Show as:',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .4)),
            for (final (key, label) in states)
              ChoiceChip(
                label: Text(label),
                selected: _previewAs == key,
                showCheckmark: false,
                selectedColor: Brand.red,
                backgroundColor: Colors.white,
                labelStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _previewAs == key ? Colors.white : Brand.ink),
                onSelected: (_) {
                  _previewAs = key;
                  _applyPreview();
                },
              ),
          ]),
    );
  }

  /// A Verified claim still waiting for its payment: ask for it to be
  /// picked up now (the database lets one request through every two
  /// minutes) and look again every few seconds until it lands.
  void _watchPayments(List<Map<String, dynamic>> pending) {
    final waiting = pending
        .where((c) => c['status'] == 'started' && c['plan'] != 'free')
        .toList();
    if (waiting.isEmpty) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    for (final c in waiting) {
      _supabase.paymentReturned('${c['claim_id']}');
    }
    _poll ??= Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) _load();
    });
  }

  /// This device came back from Stripe for this claim in the last few
  /// hours: the payment is almost certainly on its way.
  bool _justPaid(Map<String, dynamic> c) {
    final lc = _lastClaim;
    if (lc == null || '${lc['claim_id']}' != '${c['claim_id']}') return false;
    final at = DateTime.tryParse('${lc['returned_at'] ?? ''}');
    return at != null && DateTime.now().toUtc().difference(at).inHours < 6;
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
    // The page's own description when nothing newer: the owner edits
    // our words instead of starting from a blank box.
    String firstText(List<dynamic> xs) =>
        xs.map(s).firstWhere((t) => t.trim().isNotEmpty, orElse: () => '');
    _description.text = firstText(
        [d['description'], oc['description'], v['page_description']]);
    final stored = [prices['day'], prices['week'], prices['month'], prices['coffee']]
        .map(s)
        .toList();
    _currency = stored.map(Price.codeIn).firstWhere((c) => c != null,
            orElse: () => null) ??
        Price.forCountry('${v['country'] ?? ''}') ??
        'EUR';
    _priceDay.text = Price.amountOf(stored[0]);
    _priceWeek.text = Price.amountOf(stored[1]);
    _priceMonth.text = Price.amountOf(stored[2]);
    _priceCoffee.text = Price.amountOf(stored[3]);
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
          'day': Price.format(_priceDay.text, _currency),
          'week': Price.format(_priceWeek.text, _currency),
          'month': Price.format(_priceMonth.text, _currency),
          'coffee': Price.format(_priceCoffee.text, _currency),
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
    if (_isPreview) {
      setState(() => _savedNote = 'Preview: nothing is saved. For the '
          'owner this would ${submit ? 'send the changes to you for review' : 'save a draft'}.');
      return;
    }
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
        _autoSavedAt = DateTime.now();
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
    if (_isPreview) {
      setState(() => _savedNote = 'Preview: photos cannot be added here.');
      return;
    }
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
                      _pending = [];
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
        if (_isPreview) {
          if (_previewBase == null) {
            return Center(
                child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error ?? 'Nothing to preview.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Brand.inkSecondary)),
            ));
          }
          return Column(children: [
            _previewBar(),
            Expanded(
                child: _venues.isEmpty
                    ? _pendingView(wide)
                    : _account(wide)),
          ]);
        }
        if (_venues.isEmpty && _pending.isNotEmpty) return _pendingView(wide);
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
          const Text('FOR COWORKING SPACES AND CAFES',
              style: TextStyle(
                  color: Brand.red,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8)),
          const SizedBox(height: 6),
          Text('Business sign-in',
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: wide ? 30 : 24,
                  letterSpacing: -0.5)),
          const SizedBox(height: 8),
          const Text(
              'Manage your listing on Nomadwise: your description, '
              'prices, hours, photos and facts. Sign in with the email your '
              'space was claimed with; no password.',
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
                          onPressed: () => _supabase.signInWithGoogleTo(
                              AppConfig.ownerAccountUrl,
                              loginHint: _email.text.trim()),
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
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('Not claimed your space yet?',
                style: TextStyle(color: Brand.inkMuted, fontSize: 12.5)),
            TextButton(
                onPressed: () => launchUrl(
                    Uri.parse('https://nomadmaps.io/?claim'),
                    webOnlyWindowName: '_self'),
                child: const Text('Claim it for free')),
          ]),
          const Text('Questions: hello@nomadwise.io',
              style: TextStyle(color: Brand.inkMuted, fontSize: 12.5)),
        ]),
      );

  // ------------------------------------------------------ claim pending

  /// Signed in, claim made, not approved yet: the space, where the
  /// claim stands, and the account laid out but locked, so the owner
  /// sees they are almost there.
  Widget _pendingView(bool wide) {
    final c = _pending.first;
    final name = '${c['name'] ?? 'Your space'}';
    final kind = SupabaseService.spaceKind('${c['type'] ?? ''}');
    final verified = c['plan'] != 'free';
    final paid = c['paid'] == true;
    // Back from Stripe, payment not seen yet: it is being confirmed,
    // not "unfinished".
    final confirming =
        c['status'] == 'started' && verified && _justPaid(c);
    final started = c['status'] == 'started' && !confirming;
    final where = [c['neighbourhood'], c['city']]
        .where((x) => x != null && '$x'.isNotEmpty)
        .join(', ');

    final steps = <(String, _Step)>[
      ('Claimed', _Step.done),
      if (verified)
        (
          confirming ? 'Payment confirming' : 'Paid',
          paid ? _Step.done : confirming ? _Step.now : _Step.todo
        ),
      (
        "We check it's you",
        (started || confirming) && verified ? _Step.todo : _Step.now
      ),
      (verified ? 'Verified' : 'Yours to manage', _Step.todo),
    ];

    return _frame(
      wide,
      maxWidth: 1000,
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.storefront_outlined,
              size: 18, color: Brand.inkSecondary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(name,
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          ),
          if (where.isNotEmpty) ...[
            const SizedBox(width: 10),
            Flexible(
              child: Text(where,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Brand.inkSecondary, fontSize: 13.5)),
            ),
          ],
        ]),
        const SizedBox(height: 14),
        _panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                started && verified
                    ? "You've started claiming your $kind"
                    : "You've claimed your $kind, you're almost there",
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            const SizedBox(height: 16),
            _stepsRow(steps, wide),
            const SizedBox(height: 16),
            Text(
                confirming
                    ? 'Your payment is being confirmed with Stripe. This '
                        'page updates by itself as soon as it is; then we '
                        'check you are with the team and Verified goes on.'
                    : started && verified
                    ? 'We have not received a payment yet. If you have just '
                        'paid, it shows here as soon as Stripe confirms it; '
                        'if not, finish your claim below.'
                    : 'We check every claim comes from the business (the '
                        'owner or someone on the team) before handing the '
                        'page over, usually with one quick message to the '
                        "business's own Instagram, WhatsApp or email. We email "
                        'you at ${_supabase.userEmail ?? 'this address'} as '
                        'soon as that is done, and everything below opens.',
                style: const TextStyle(
                    fontSize: 14, height: 1.55, color: Brand.inkSecondary)),
            if (confirming) ...[
              const SizedBox(height: 12),
              const Row(children: [
                SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Brand.goldTextDark)),
                SizedBox(width: 10),
                Text('Checking with Stripe',
                    style: TextStyle(
                        fontSize: 13, color: Brand.goldTextDark)),
              ]),
            ],
            if (started && verified) ...[
              const SizedBox(height: 14),
              FilledButton(
                  onPressed: () => launchUrl(
                      Uri.parse('https://nomadmaps.io/?claim='
                          '${Uri.encodeQueryComponent(name)}'),
                      webOnlyWindowName: '_self'),
                  style: FilledButton.styleFrom(backgroundColor: Brand.red),
                  child: const Text('Finish my claim')),
            ],
            if (c['page_url'] != null) ...[
              const SizedBox(height: 10),
              TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse('${c['page_url']}')),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('See the page as it is today')),
            ],
          ]),
        ),
        const SizedBox(height: 18),
        _lockedAccount(name, wide),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
              onPressed: _load, child: const Text('Check again')),
        ),
      ]),
    );
  }

  Widget _stepsRow(List<(String, _Step)> steps, bool wide) {
    Widget dot(_Step st) => Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: switch (st) {
              _Step.done => Brand.success,
              _Step.now => Brand.goldTint,
              _Step.todo => Brand.field,
            },
            border: st == _Step.now
                ? Border.all(color: Brand.goldTextDark, width: 1.5)
                : null,
          ),
          child: switch (st) {
            _Step.done =>
              const Icon(Icons.check, size: 16, color: Colors.white),
            _Step.now => const Icon(Icons.hourglass_top,
                size: 14, color: Brand.goldTextDark),
            _Step.todo => null,
          },
        );
    final items = [
      for (final (label, st) in steps)
        Row(mainAxisSize: MainAxisSize.min, children: [
          dot(st),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: st == _Step.todo ? FontWeight.w500 : FontWeight.w700,
                  color: st == _Step.todo ? Brand.inkMuted : Brand.ink)),
        ]),
    ];
    return Wrap(
      spacing: wide ? 26 : 16,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: items,
    );
  }

  /// The account as it will be, blurred and locked.
  Widget _lockedAccount(String name, bool wide) {
    Widget field(String label) => Container(
          height: 44,
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: Brand.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Brand.border),
          ),
          child: Text(label,
              style: const TextStyle(color: Brand.inkMuted, fontSize: 13)),
        );
    Widget section(String title, List<String> fields) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 14.5)),
            const SizedBox(height: 8),
            for (final f in fields) field(f),
            const SizedBox(height: 10),
          ],
        );
    final mock = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      section('Your listing details', ['What makes your space special?']),
      section('Photos', ['Add your own photos']),
      section('Passes and prices', ['Day pass', 'Week pass', 'Month pass']),
      section('Opening hours', ['Monday', 'Tuesday', 'Wednesday']),
      section('Your message', ['An event or offer for your page']),
    ]);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(children: [
        Container(
          padding: const EdgeInsets.all(22),
          color: Brand.bg,
          child: IgnorePointer(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 3.5, sigmaY: 3.5),
              child: Opacity(opacity: 0.8, child: mock),
            ),
          ),
        ),
        Positioned.fill(
          child: Center(
            child: Container(
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              constraints: const BoxConstraints(maxWidth: 420),
              decoration: BoxDecoration(
                color: Brand.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Brand.border),
                boxShadow: const [
                  BoxShadow(color: Color(0x14000000), blurRadius: 16)
                ],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.lock_outline, color: Brand.inkSecondary),
                const SizedBox(height: 8),
                Text("Opens as soon as we've confirmed you're with $name",
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14.5)),
                const SizedBox(height: 4),
                const Text(
                    'Your description, photos, prices, hours and your own '
                    'message for the page.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13, height: 1.45, color: Brand.inkSecondary)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

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
    final preview = _tab == _Tab.message && _verified
        ? _messagePreview()
        : _preview();
    // One quick question now and then, above the page preview (not in
    // a founder's preview: those answers would be ours).
    final side = _isPreview
        ? preview
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            OwnerQuestionCard(
                key: ValueKey('q-${v['id']}'), venueId: '${v['id']}'),
            preview,
          ]);
    final body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_showTip && !_isPreview) _bookmarkTip(),
          if (_tab == _Tab.listing || (_tab == _Tab.message && _verified))
            _actionBar(wide),
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
                  'Signed in as\n${_supabase.userEmail ?? ''}\n\n'
                  'You stay signed in on this device. Bookmark '
                  'nomadmaps.io/owner to come straight back.',
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

  /// Once, after signing in: signing in is not needed every time.
  Widget _bookmarkTip() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        decoration: BoxDecoration(
          color: Brand.successTint,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          const Icon(Icons.bookmark_add_outlined, color: Brand.success),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
                'You stay signed in on this device, so next time there is no '
                'link to wait for. Bookmark this page (nomadmaps.io/owner), or '
                'on a phone add it to your home screen, to come straight back.',
                style: TextStyle(fontSize: 13, height: 1.45)),
          ),
          TextButton(
              onPressed: () {
                setState(() => _showTip = false);
                SharedPreferences.getInstance()
                    .then((p) => p.setBool('owner_bookmark_tip', true))
                    .catchError((_) => false);
              },
              child: const Text('Got it')),
        ]),
      );

  /// Save draft and Submit for review, at the top where they are easy
  /// to find, with what has happened to the edits so far.
  Widget _actionBar(bool wide) {
    final err = _savedNote != null &&
        (_savedNote!.startsWith('That') ||
            _savedNote!.startsWith('The ') ||
            _savedNote!.startsWith('Could') ||
            _savedNote!.startsWith('Five'));
    final (IconData icon, Color color, String text) = _saving || _autosaving
        ? (Icons.sync, Brand.inkSecondary, 'Saving your draft')
        : err
            ? (Icons.error_outline, Brand.red, _savedNote!)
            : _dirty
                ? (Icons.edit_outlined, Brand.goldTextDark, 'Unsaved changes')
                : _autoSavedAt != null
                    ? (Icons.cloud_done_outlined, Brand.success,
                        'Draft saved. Nothing changes on your page until '
                            'you submit for review.')
                    : (Icons.info_outline, Brand.inkSecondary,
                        'Edits are saved as a draft as you go. Submit for '
                            'review when you are ready.');
    final buttons = Wrap(spacing: 8, runSpacing: 8, children: [
      OutlinedButton(
          onPressed: _saving ? null : () => _save(submit: false),
          child: const Text('Save draft')),
      FilledButton(
          onPressed: _saving ? null : () => _save(submit: true),
          style: FilledButton.styleFrom(backgroundColor: Brand.red),
          child: Text(_saving ? 'One moment' : 'Submit for review')),
    ]);
    final status = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 17, color: color),
      const SizedBox(width: 8),
      Expanded(
          child: Text(text,
              style: TextStyle(fontSize: 12.5, height: 1.4, color: color))),
    ]);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Brand.border),
      ),
      child: wide
          ? Row(children: [
              Expanded(child: status),
              const SizedBox(width: 12),
              buttons,
            ])
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [status, const SizedBox(height: 8), buttons]),
    );
  }

  InputDecoration _dec(String label, {String? hint}) => InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
      isDense: true);

  /// One price box: the amount only, with the currency shown beside it.
  Widget _priceField(TextEditingController c, String label) => SizedBox(
        width: 200,
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.,kK ]')),
          ],
          decoration: _dec(label, hint: 'Amount').copyWith(
              prefixText: Price.prefixFor(_currency),
              suffixText: Price.suffixFor(_currency)),
        ),
      );

  Future<void> _pickCurrency() async {
    final codes = currencyNames.keys.toList()..sort();
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) {
        var q = '';
        return StatefulBuilder(
          builder: (ctx, set) {
            final rows = codes
                .where((c) =>
                    q.isEmpty ||
                    c.toLowerCase().contains(q) ||
                    Price.name(c).toLowerCase().contains(q))
                .toList();
            return AlertDialog(
              title: const Text('Currency for your prices'),
              content: SizedBox(
                width: 380,
                height: 420,
                child: Column(children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Search, e.g. rupee or LKR'),
                    onChanged: (v) => set(() => q = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(children: [
                      for (final c in rows)
                        ListTile(
                          dense: true,
                          title: Text(Price.name(c)),
                          trailing: Text(c,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                          selected: c == _currency,
                          onTap: () => Navigator.of(ctx).pop(c),
                        ),
                    ]),
                  ),
                ]),
              ),
            );
          },
        );
      },
    );
    if (picked != null && mounted) {
      setState(() {
        _currency = picked;
        _dirty = true;
        _editSeq++;
      });
    }
  }

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
                        'words work best.')
                .copyWith(
                    helperText: 'A line starting with ## is a section '
                        'heading on your page, like "## Working at '
                        '${_venue?['name'] ?? 'your space'}".',
                    helperMaxLines: 2)),
        const SizedBox(height: 14),
        Text(_venue?['type'] == 'cafe' ? 'Prices' : 'Passes and prices',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Prices in ${_currency} (${Price.name(_currency)}).',
              style: const TextStyle(color: Brand.inkMuted, fontSize: 12)),
          TextButton(
              onPressed: _pickCurrency,
              child: const Text('Change currency',
                  style: TextStyle(fontSize: 12))),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 10, runSpacing: 10, children: [
          if (_venue?['type'] != 'cafe') ...[
            _priceField(_priceDay, 'Day pass'),
            _priceField(_priceWeek, 'Week pass'),
            _priceField(_priceMonth, 'Month pass'),
          ],
          _priceField(_priceCoffee, 'Cappuccino'),
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
                    decoration: _dec('Enquiries go to',
                        hint: 'hello@yourspace.com'))),
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
        // Save draft and Submit also sit at the top (the action bar);
        // this one saves scrolling back up after the last field.
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
              onPressed: _saving ? null : () => _save(submit: true),
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              child: Text(_saving ? 'One moment' : 'Submit for review')),
        ),
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
  // The page's own words for the work-friendly facts (its tags).
  static const _siteTags = {
    'power_outlets': 'Enough Plug Sockets',
    'aircon': 'Aircon',
    'comfortable_seating': 'Comfortable Seating',
    'cozy': 'Cozy',
    'quiet_space': 'Quiet Space',
    'good_for_calls': 'Good for Calls',
    'call_room': 'Skype Room',
    'monitor': 'Monitor Available',
    'office_chairs': 'Office Chairs',
    'access_24h': '24 Hour Access',
    'laptops_allowed': 'Laptop Friendly',
  };

  static const _pageRed = Color(0xFFE8464E); // the site's button red
  static const _pageInk = Color(0xFF333333);
  static const _pageTag = Color(0xFFE9E9E9);

  /// The listing page as nomadwise.io draws it (28 Sep screenshots of
  /// Nomio Coworking Lounge), in the order a phone shows it: the main
  /// column, then the sidebar (hours, links, enquiry button, advert).
  Widget _preview() {
    final v = _venue!;
    final area = [v['neighbourhood'], v['city']]
        .where((x) => (x ?? '').toString().isNotEmpty)
        .join(', ');
    final country = (v['country'] ?? '').toString();
    final title = [
      '${v['name']}${country.isNotEmpty ? ' in $country' : ''}',
      if ((v['neighbourhood'] ?? '').toString().isNotEmpty) v['neighbourhood'],
    ].join(' - ');
    final tags = [
      for (final (key, label) in _factLabels)
        if (_facts[key] == true) _siteTags[key] ?? label
    ];
    final photos = _photos.isNotEmpty
        ? _photos
        : List<String>.from((v['google_photos'] ?? const []) as List);
    final prices = [
      if (_priceDay.text.trim().isNotEmpty)
        ('Day pass', Price.format(_priceDay.text, _currency)),
      if (_priceWeek.text.trim().isNotEmpty)
        ('Week pass', Price.format(_priceWeek.text, _currency)),
      if (_priceMonth.text.trim().isNotEmpty)
        ('Month pass', Price.format(_priceMonth.text, _currency)),
      if (_priceCoffee.text.trim().isNotEmpty)
        ('Cappuccino', Price.format(_priceCoffee.text, _currency)),
    ];
    final isCafe = v['type'] == 'cafe';

    Widget stat(IconData icon, String text, {Color color = Brand.inkSecondary}) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 4),
          Text(text,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: _pageInk)),
        ]);

    final main = _pageCard(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 19,
              height: 1.2,
              color: _pageInk)),
      const SizedBox(height: 8),
      Wrap(
          spacing: 12,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (area.isNotEmpty)
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.location_on, size: 15, color: _pageRed),
                Text(area,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _pageRed)),
              ]),
            if (country.isNotEmpty)
              Text(country,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _pageInk)),
            if (_verified)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: const Color(0xFFE4F2EA),
                    borderRadius: BorderRadius.circular(8)),
                child: const Text('Verified',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1F6B41))),
              ),
          ]),
      const SizedBox(height: 8),
      Wrap(spacing: 14, runSpacing: 6, children: [
        if (v['wifi_speed_mbps'] != null)
          stat(Icons.wifi, '${v['wifi_speed_mbps']}Mbps'),
        if (v['google_rating_snapshot'] != null)
          stat(Icons.star, '${v['google_rating_snapshot']} '
              '(${v['google_reviews_snapshot'] ?? 0})',
              color: const Color(0xFFF4B23E)),
        stat(Icons.laptop, isCafe ? 'Cafe' : 'Coworking Space'),
      ]),
      const SizedBox(height: 12),
      _photoGrid(photos),
      const SizedBox(height: 12),
      Wrap(spacing: 6, runSpacing: 6, children: [
        if (_verified) _pageButton('Send an enquiry'),
        _pageButton('See Accommodation options nearby'),
      ]),
      if (tags.isNotEmpty) ...[
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final t in tags)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                  color: _pageTag, borderRadius: BorderRadius.circular(6)),
              child: Text(t,
                  style: const TextStyle(
                      fontSize: 11.5, color: Color(0xFF6B6B6B))),
            ),
        ]),
      ],
      const SizedBox(height: 12),
      const Text('Something need updating? Let us know.',
          style: TextStyle(
              fontSize: 11.5,
              color: _pageRed,
              decoration: TextDecoration.underline,
              decorationColor: _pageRed)),
      const SizedBox(height: 14),
      ..._descriptionBlocks(),
      if (prices.isNotEmpty) ...[
        const SizedBox(height: 10),
        const Text('Prices',
            style: TextStyle(
                fontWeight: FontWeight.w700, fontSize: 15, color: _pageInk)),
        const SizedBox(height: 6),
        for (final (label, val) in prices)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text.rich(TextSpan(children: [
              TextSpan(
                  text: '$label: ',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              TextSpan(text: val.trim()),
            ]), style: const TextStyle(fontSize: 12.5, color: _pageInk)),
          ),
      ],
      const SizedBox(height: 14),
      _mapBlock(v, area),
    ]));

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
        const SizedBox(height: 2),
        const Text(
            'Your page as a phone shows it. On a computer, the hours, '
            'links, enquiry button and advert sit in a column on the right.',
            style: TextStyle(fontSize: 11.5, color: Brand.inkMuted, height: 1.4)),
        const SizedBox(height: 12),
        main,
        const SizedBox(height: 10),
        _sidebar(),
      ]),
    );
  }

  Widget _pageCard(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFEDEDED)),
        ),
        child: child,
      );

  Widget _pageButton(String label, {bool wide = false}) => Container(
        width: wide ? double.infinity : null,
        alignment: wide ? Alignment.center : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
            color: _pageRed, borderRadius: BorderRadius.circular(8)),
        child: Text(label,
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: Colors.white)),
      );

  /// One large photo and four small ones, as on the page.
  Widget _photoGrid(List<String> photos) {
    Widget img(int i) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: i < photos.length
              ? Image.network(photos[i],
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  errorBuilder: (_, __, ___) => Container(color: Brand.field))
              : Container(color: Brand.field),
        );
    if (photos.isEmpty) {
      return Container(
          height: 120,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: Brand.field, borderRadius: BorderRadius.circular(8)),
          child: const Text('No photos yet',
              style: TextStyle(color: Brand.inkMuted)));
    }
    return SizedBox(
      height: 130,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(flex: 2, child: img(0)),
        const SizedBox(width: 4),
        Expanded(
          flex: 2,
          child: Column(children: [
            Expanded(
                child: Row(children: [
              Expanded(child: img(1)),
              const SizedBox(width: 4),
              Expanded(child: img(2)),
            ])),
            const SizedBox(height: 4),
            Expanded(
                child: Row(children: [
              Expanded(child: img(3)),
              const SizedBox(width: 4),
              Expanded(child: img(4)),
            ])),
          ]),
        ),
      ]),
    );
  }

  /// The description as the page sets it: a line starting "## " is a
  /// section heading ("Working at ..."), the rest are paragraphs.
  List<Widget> _descriptionBlocks() {
    final text = _description.text.trim();
    if (text.isEmpty) {
      return const [
        Text('Your description appears here.',
            style: TextStyle(fontSize: 12.5, color: Brand.inkMuted)),
      ];
    }
    return [
      for (final line in text.split('\n').map((l) => l.trim()))
        if (line.isNotEmpty)
          line.startsWith('## ')
              ? Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 4),
                  child: Text(line.substring(3),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          height: 1.25,
                          color: _pageInk)),
                )
              : Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(line,
                      style: const TextStyle(
                          fontSize: 12.5, height: 1.5, color: _pageInk)),
                ),
    ];
  }

  /// The sidebar: opening hours, the round link buttons, the enquiry
  /// button (Verified) and the advert slot.
  Widget _sidebar() {
    Widget circle(IconData icon, Color color) => Container(
          width: 34,
          height: 34,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFE0E0E0))),
          child: Icon(icon, size: 17, color: color),
        );
    final days = [
      for (final day in _days)
        if (_hours[day]!.text.trim().isNotEmpty) day
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _pageCard(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Opening Hours',
            style: TextStyle(
                fontWeight: FontWeight.w700, fontSize: 15, color: _pageInk)),
        const SizedBox(height: 8),
        if (days.isEmpty)
          const Text('Your opening hours appear here.',
              style: TextStyle(fontSize: 12, color: Brand.inkMuted))
        else
          for (final day in days)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(children: [
                SizedBox(
                  width: 90,
                  child: Text(_dayNames[day]!,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _pageInk)),
                ),
                Expanded(
                  child: Text(_hours[day]!.text.trim(),
                      style: const TextStyle(fontSize: 12, color: _pageInk)),
                ),
              ]),
            ),
      ])),
      const SizedBox(height: 10),
      Row(children: [
        if (_website.text.trim().isNotEmpty) circle(Icons.link, _pageInk),
        circle(Icons.location_on, _pageRed),
        if (_instagram.text.trim().isNotEmpty)
          circle(Icons.camera_alt_outlined, const Color(0xFFD62976)),
        if (_instagram.text.trim().isNotEmpty)
          Flexible(
            child: Text(_igShown(_instagram.text),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: Brand.inkMuted)),
          ),
      ]),
      if (_verified) ...[
        const SizedBox(height: 10),
        _pageButton('Send an enquiry', wide: true),
      ],
      const SizedBox(height: 10),
      _advertSlot(),
    ]);
  }

  /// "@handle" however it was typed (a link, with or without the @).
  static String _igShown(String raw) {
    var h = raw.trim();
    final m = RegExp(r'instagram\.com/([^/?#\s]+)', caseSensitive: false)
        .firstMatch(h);
    if (m != null) h = m.group(1)!;
    return '@${h.replaceFirst(RegExp(r'^@+'), '')}';
  }

  /// Where the Google map sits on the page, drawn like it: the place
  /// card top left, the red pin in the middle. Drawn, not loaded (a
  /// real map would cost a Google call on every redraw).
  Widget _mapBlock(Map<String, dynamic> v, String area) => Container(
        height: 150,
        decoration: BoxDecoration(
          color: const Color(0xFFE3F1E6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Stack(children: [
          Positioned(
            left: 8,
            top: 8,
            right: 60,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: Brand.shadowResting),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${v['name']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5, fontWeight: FontWeight.w700)),
                    if (area.isNotEmpty)
                      Text(area,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 10.5, color: Brand.inkSecondary)),
                  ]),
            ),
          ),
          const Align(
            alignment: Alignment(0, 0.35),
            child: Icon(Icons.location_on, color: Color(0xFFD93025), size: 30),
          ),
          const Positioned(
            bottom: 6,
            left: 0,
            right: 0,
            child: Text('Google map',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10.5, color: Brand.inkMuted)),
          ),
        ]),
      );

  /// The advert slot as it shows today: a Verified page's own message
  /// when one is written, else the partner advert.
  Widget _advertSlot() {
    if (_verified && _mentionTitle.text.trim().isNotEmpty) {
      return _mentionCard();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF4A5A66),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Advert',
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
        const SizedBox(height: 4),
        Text(
            _verified
                ? 'Your own event or offer replaces this advert. Write it '
                    'under Your message.'
                : 'A partner advert shows here. Verified pages show their '
                    'own event or offer instead.',
            style: const TextStyle(
                fontSize: 12, height: 1.4, color: Color(0xFFDCE3E8))),
      ]),
    );
  }

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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
                color: const Color(0xFF1F6B41),
                borderRadius: BorderRadius.circular(9)),
            child: Text(
                _mentionCta.text.trim().isEmpty
                    ? 'Find out more'
                    : _mentionCta.text.trim(),
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
          ),
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
              'opens up, along with the Verified badge, a place above '
              'every free listing and a "Send an enquiry" button that '
              'emails you directly.',
              style: TextStyle(
                  fontSize: 13.5, height: 1.5, color: Brand.inkSecondary)),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: () => _saveThenOpen('https://nomadmaps.io/?claim='
                  '${Uri.encodeComponent('${_venue?['webflow_slug'] ?? _venue?['name'] ?? ''}')}'),
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              child: const Text('Go Verified')),
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
        // Save draft and Submit also sit at the top (the action bar);
        // this one saves scrolling back up after the last field.
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
              onPressed: _saving ? null : () => _save(submit: true),
              style: FilledButton.styleFrom(backgroundColor: Brand.red),
              child: Text(_saving ? 'One moment' : 'Submit for review')),
        ),
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
          const Text(
              'Your message takes the advert\'s place at the foot of your '
              'page\'s sidebar: on the right on a computer, after the '
              'details on a phone.',
              style: TextStyle(color: Brand.inkMuted, fontSize: 12, height: 1.4)),
          const SizedBox(height: 12),
          if (_mentionTitle.text.trim().isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Brand.successTint,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                    'Write a headline and your message replaces the advert '
                    'below.',
                    style: TextStyle(fontSize: 12.5, color: Brand.success)),
              ),
            ),
          _sidebar(),
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
      'A "Send an enquiry" button that emails you directly, no commission',
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
              onPressed: () => _saveThenOpen(
                  'https://nomadmaps.io/?claim=${Uri.encodeComponent('${v['webflow_slug'] ?? v['name']}')}'),
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

enum _Step { done, now, todo }
