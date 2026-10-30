import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../services/analytics_service.dart';
import '../services/places_service.dart';
import '../services/supabase_service.dart';
import '../services/ua_stub.dart' if (dart.library.html) '../services/ua_web.dart'
    as ua;
import '../theme.dart';
import '../widgets/phone_field.dart';
import '../widgets/pricing_picker.dart';
import '../widgets/pricing_plans.dart';
import '../widgets/email_typo_hint.dart';

/// Claim your space: the owner's way in.
///
/// nomadmaps.io/?claim (or ?claim=<name> to arrive with the search box
/// already filled from a listing page). The owner finds their space,
/// says who they are, and pays. The Stripe link carries the claim's id,
/// so the payment always knows whose it is and nothing ever lands as
/// "space not named".
///
/// Deliberately no account and no password: paying is the proof, and
/// the details that make a page good are collected afterwards, when
/// the owner is already a customer rather than a visitor being asked
/// to fill in a long form.
///
/// Owners read this on a laptop at their desk as often as on a phone,
/// so every step lays out in two columns above [_wideAt] and stacks
/// below it.
class ClaimScreen extends StatefulWidget {
  /// A name or page slug to search for straight away, from
  /// ?claim=<name or slug>.
  final String? seed;

  /// The nomadwise.io page the link was on, from &from=/coworking/<slug>,
  /// so the phone ping can say where the visitor came from.
  final String? from;

  /// The owner's email, when a founder sent the link (&email=).
  final String? email;

  /// From the pricing page (&plan=premium|free, &period=monthly|yearly,
  /// &currency=USD): the plan to lead with. The price
  /// itself still comes from the claimed space's country.
  final String? plan;
  final String? period;
  final String? currency;
  const ClaimScreen(
      {super.key,
      this.seed,
      this.from,
      this.email,
      this.plan,
      this.period,
      this.currency});
  @override
  State<ClaimScreen> createState() => _ClaimScreenState();
}

// Jonathan, 30 Oct 2026: find your space first, then the pricing page
// (Free and Premium, priced for the space's country), then your
// details, whose button claims for free or goes on to payment.
enum _Step { find, addSpace, plans, about }

/// Below this the page is one column, above it two.
const double _wideAt = 900;

class _ClaimScreenState extends State<ClaimScreen> {
  final _supabase = SupabaseService();
  final _places = PlacesService();

  _Step _step = _Step.find;

  // ---- finding an existing listing ----
  final _search = TextEditingController();
  Timer? _searchTimer;
  List<Map<String, dynamic>> _hits = [];
  bool _searching = false;
  bool _searched = false;
  Map<String, dynamic>? _picked; // a row from claim_search

  // ---- adding a space Google knows but we do not ----
  final _placeSearch = TextEditingController();
  Timer? _placeTimer;
  List<PlaceSuggestion> _suggestions = [];
  bool _placeBusy = false;
  PlaceSuggestion? _pickedPlace;
  String _newType = 'coworking';
  String? _newAddress;
  String? _newCity;
  String? _newCountry;
  double? _newLat;
  double? _newLng;

  // ---- who is paying ----
  final _ownerName = TextEditingController();
  final _ownerRole = TextEditingController(); // job title, when "Other"
  // Owner, Manager, Marketing or Other: not only owners claim a page.
  String? _role;
  // The phone's country code, picked from a list (typed codes were
  // often wrong); defaults to the space's country.
  final _phoneCountry = ValueNotifier<String?>(null);
  final _ownerEmail = TextEditingController();
  final _ownerPhone = TextEditingController();
  final _enquiryEmail = TextEditingController();
  // Enquiries go to the owner's own email unless they untick this and
  // give another address (a shared inbox, reception).
  bool _sameEnquiryEmail = true;
  final _note = TextEditingController();
  // Two optional links. Public facts we would show anyway, and a small
  // investment that makes finishing more likely.
  final _siteUrl = TextEditingController();
  final _instagram = TextEditingController();
  // Honeypot: never shown, so anything in it is a bot.
  final _website = TextEditingController();

  bool _sending = false;

  // The optional website, Instagram and note, folded away on the
  // Premium path so the form is shorter before payment.
  bool _showExtras = false;

  // Opened from the pricing link: the phone is rung once a space is
  // found (step two), not for every look at the pricing page.
  bool get _fromPricing => widget.from == 'pricing';
  bool _rang = false;

  // What Verified costs here (migration 115): loaded for the space's
  // country, with the monthly/yearly and currency choices on it.
  PricingChoice? _pricing;
  String _pricingCountry = '\u0000';
  bool _pricingFailed = false;

  /// The plan chosen on step two ('free' or 'verified'). Back from
  /// Your details, both are there again, so the choice is never final.
  String _plan = 'free';

  /// A button on step two: the plan, then Your details.
  void _choosePlan(String plan) {
    _track('claim_plan_pick', {'plan': plan});
    setState(() {
      _plan = plan;
      _error = null;
      _go(_Step.about, how: plan == 'verified' ? 'premium' : 'free');
    });
  }

  // ---- the draft: back from Stripe with everything still here ----

  /// Period and currency from a restored draft, applied once the
  /// prices for the space's country have loaded.
  String? _restorePeriod;
  String? _restoreCurrency;

  /// True when the visitor came back from Stripe's Cancel button
  /// (&cancelled=1 on the return link) or the browser's Back, with a
  /// draft to pick up: a line on step two says nothing was charged.
  bool _resumed = false;

  Map<String, dynamic> _draft() => {
        'picked': _picked,
        'place': _pickedPlace == null
            ? null
            : {
                'id': _pickedPlace!.placeId,
                'main': _pickedPlace!.main,
                'secondary': _pickedPlace!.secondary,
              },
        'new_type': _newType,
        'new_address': _newAddress,
        'new_city': _newCity,
        'new_country': _newCountry,
        'new_lat': _newLat,
        'new_lng': _newLng,
        'owner_name': _ownerName.text,
        'role': _role,
        'owner_role': _ownerRole.text,
        'phone_country': _phoneCountry.value,
        'owner_email': _ownerEmail.text,
        'owner_phone': _ownerPhone.text,
        'same_enquiry_email': _sameEnquiryEmail,
        'enquiry_email': _enquiryEmail.text,
        'note': _note.text,
        'site_url': _siteUrl.text,
        'instagram': _instagram.text,
        'plan': _plan,
        'period': _pricing?.period,
        'currency': _pricing?.currency,
      };

  /// Puts a saved draft back and opens the plans (step two), with a
  /// line that nothing was charged. Returns false when
  /// the draft has no space in it.
  bool _applyDraft(Map<String, dynamic> d) {
    final picked = d['picked'];
    final place = d['place'];
    if (picked is Map) {
      _picked = Map<String, dynamic>.from(picked);
    } else if (place is Map) {
      _pickedPlace = PlaceSuggestion(
          placeId: '${place['id'] ?? ''}',
          main: '${place['main'] ?? ''}',
          secondary: '${place['secondary'] ?? ''}');
    } else {
      return false;
    }
    String str(String k) => '${d[k] ?? ''}';
    // Restored text is not typing: setting a controller's text notifies
    // its listener at once, so the claim_typed events are muted first.
    _filled.addAll(const {
      'name', 'role', 'email', 'phone', 'enquiry_email', 'website',
      'instagram', 'note'
    });
    _newType = str('new_type').isEmpty ? _newType : str('new_type');
    _newAddress = d['new_address'] as String?;
    _newCity = d['new_city'] as String?;
    _newCountry = d['new_country'] as String?;
    _newLat = (d['new_lat'] as num?)?.toDouble();
    _newLng = (d['new_lng'] as num?)?.toDouble();
    _ownerName.text = str('owner_name');
    _role = d['role'] as String?;
    _ownerRole.text = str('owner_role');
    _phoneCountry.value = d['phone_country'] as String?;
    _ownerEmail.text = str('owner_email');
    _ownerPhone.text = str('owner_phone');
    _sameEnquiryEmail = d['same_enquiry_email'] != false;
    _enquiryEmail.text = str('enquiry_email');
    _note.text = str('note');
    _siteUrl.text = str('site_url');
    _instagram.text = str('instagram');
    _plan = str('plan') == 'verified' ? 'verified' : 'free';
    _restorePeriod = d['period'] as String?;
    _restoreCurrency = d['currency'] as String?;
    // The prices are fetched again so the restored period and currency
    // are applied, even when this country's were already loaded.
    _pricingCountry = '\u0000';
    // Fields the draft left empty can still log a claim_typed event when
    // the visitor fills them now; the restored ones were muted above.
    _filled.removeWhere((f) => switch (f) {
          'name' => _ownerName.text.trim().isEmpty,
          'role' => _ownerRole.text.trim().isEmpty,
          'email' => _ownerEmail.text.trim().isEmpty,
          'phone' => _ownerPhone.text.trim().isEmpty,
          'enquiry_email' => _enquiryEmail.text.trim().isEmpty,
          'website' => _siteUrl.text.trim().isEmpty,
          'instagram' => _instagram.text.trim().isEmpty,
          'note' => _note.text.trim().isEmpty,
          _ => false,
        });
    _step = _Step.plans;
    _resumed = true;
    return true;
  }

  String get _country => _picked != null
      ? '${_picked!['country'] ?? ''}'
      : (_newCountry ?? '');

  /// Loads the prices for the current country once, and again when it
  /// changes (picking another space, or a new address).
  void _ensurePricing() {
    final c = _country;
    if (c == _pricingCountry) return;
    _pricingCountry = c;
    _pricingFailed = false;
    // Another country: no price until its own has loaded, so step two
    // never shows (or charges) the last country's. Monthly / Yearly is
    // kept. (Called from build, so no setState here.)
    final keep = _pricing?.period;
    _pricing = null;
    _supabase.pricingFor(c).then((p) {
      if (!mounted || _pricingCountry != c) return;
      if (p == null) {
        setState(() => _pricingFailed = true);
        return;
      }
      final choice = PricingChoice(p);
      if (keep != null && _restorePeriod == null) choice.period = keep;
      // A restored draft keeps the period and currency that were chosen.
      if (_restorePeriod == 'monthly' || _restorePeriod == 'yearly') {
        choice.period = _restorePeriod!;
      }
      if (_restoreCurrency != null &&
          choice.currencies.contains(_restoreCurrency)) {
        choice.currency = _restoreCurrency!;
      }
      // Kept until a country is known: from the pricing page they must
      // survive the fallback prices shown before a space is picked.
      if (c.isNotEmpty) {
        _restorePeriod = null;
        _restoreCurrency = null;
      }
      setState(() => _pricing = choice);
    });
  }

  String? _error;

  // ---- the journey, for the admin's Claim journeys view ----
  // One id per opening of the page; every event carries it, the step
  // it happened on and the seconds since the page opened, so the
  // whole visit reads as a story afterwards.
  final String _visit =
      '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
      '${Random().nextInt(0xFFFF).toRadixString(36)}';
  final DateTime _openedAt = DateTime.now();
  bool _done = false; // went to Stripe or claimed free: not "left"
  final Set<String> _filled = {}; // fields typed into, logged once each

  int get _secs => DateTime.now().difference(_openedAt).inSeconds;

  static String _stepName(_Step s) => switch (s) {
        _Step.find => 'find',
        _Step.addSpace => 'add_space',
        // New names for the new order (find, plans, details), so the
        // Outreach "got as far as" line reads them right (migration 233).
        _Step.plans => 'plans',
        _Step.about => 'details',
      };

  void _track(String event, [Map<String, dynamic>? props]) {
    Analytics.capture(event, {
      'visit': _visit,
      'step': _stepName(_step),
      'secs': _secs,
      ...?props,
    });
  }

  /// Every change of step goes through here so it is recorded.
  void _go(_Step next, {String? how}) {
    if (next == _step) return;
    _track('claim_step', {
      'to': _stepName(next),
      if (how != null) 'how': how,
      if (_spaceName.isNotEmpty) 'space': _spaceName,
    });
    _step = next;
    // The draft is saved on the way to payment (_startAndPay), so a
    // visitor brought back here really did reach Stripe.
    if (next == _Step.plans) _ringOnce();
    if (next == _Step.about) {
      _phoneCountry.value ??= PhoneField.isoFor(
          _picked != null ? '${_picked!['country'] ?? ''}' : _newCountry);
      final me = _supabase.userEmail;
      if (_ownerEmail.text.trim().isEmpty && me != null) _ownerEmail.text = me;
    }
  }

  static const _roles = [
    ('Owner', 'Owner'),
    ('Manager', 'Manager'),
    ('Marketing', 'Marketing'),
    ('Other', 'Other staff'),
  ];

  String get _roleValue => _role == 'Other'
      ? (_ownerRole.text.trim().isEmpty
          ? 'Other staff'
          : 'Other: ${_ownerRole.text.trim()}')
      : (_role ?? '');

  /// An Instagram handle without the @, from whatever was typed or
  /// pasted: "@kelp.cowork", "kelp.cowork", or a profile link. ''
  /// when empty, null when it cannot be a handle.
  static String? igHandle(String raw) {
    var h = raw.trim();
    if (h.isEmpty) return '';
    final link = RegExp(r'instagram\.com/([^/?#\s]+)', caseSensitive: false)
        .firstMatch(h);
    if (link != null) h = link.group(1)!;
    h = h.replaceFirst(RegExp(r'^@+'), '').trim();
    if (h.isEmpty) return '';
    return RegExp(r'^[A-Za-z0-9._]{1,30}$').hasMatch(h) ? h : null;
  }

  /// What is missing or wrong on Your details, or null when it is fine.
  String? _detailsProblem() {
    final name = _ownerName.text.trim();
    final email = _ownerEmail.text.trim();
    if (name.length < 2) return 'Your name is needed.';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return 'A working email is needed.';
    }
    if (_role == null) return 'Tell us your role at the space.';
    final phone = PhoneField.problem(_phoneCountry.value, _ownerPhone.text);
    if (phone != null) return phone;
    if (igHandle(_instagram.text) == null) {
      return 'That Instagram handle has characters Instagram does not '
          'allow. Letters, numbers, dots and underscores only.';
    }
    if (!_sameEnquiryEmail &&
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
            .hasMatch(_enquiryEmail.text.trim())) {
      return 'Enter the email for enquiries, or tick the box to use your own.';
    }
    return null;
  }

  /// The claim as the database wants it, for both doors.
  Map<String, dynamic> _claimFields() {
    final ig = igHandle(_instagram.text) ?? '';
    return {
      if (_picked != null) 'venue_id': _picked!['id'],
      'owner_name': _ownerName.text.trim(),
      'owner_email': _ownerEmail.text.trim().toLowerCase(),
      'owner_role': _roleValue,
      'owner_phone': PhoneField.compose(_phoneCountry.value, _ownerPhone.text),
      'enquiry_email': _sameEnquiryEmail ? '' : _enquiryEmail.text.trim(),
      'note': _note.text.trim(),
      'space_website': _siteUrl.text.trim(),
      'space_instagram': ig.isEmpty ? '' : '@$ig',
      if (_picked == null) ...{
        'space_name': _pickedPlace?.main ?? '',
        'space_type': _newType,
        'space_address': _newAddress ?? '',
        'space_city': _newCity ?? '',
        'space_country': _newCountry ?? '',
        'space_place_id': _pickedPlace?.placeId ?? '',
        if (_newLat != null) 'space_lat': '$_newLat',
        if (_newLng != null) 'space_lng': '$_newLng',
      },
    };
  }

  void _watchField(TextEditingController c, String field) {
    c.addListener(() {
      if (c.text.trim().isEmpty || _filled.contains(field)) return;
      _filled.add(field);
      _track('claim_typed', {'field': field});
    });
  }

  void _onLeave() {
    if (_done) return;
    Analytics.beacon('claim_left', {
      'visit': _visit,
      'step': _stepName(_step),
      'secs': _secs,
      if (_spaceName.isNotEmpty) 'space': _spaceName,
      'filled': _filled.toList(),
    });
  }

  @override
  void initState() {
    super.initState();
    final seed = (widget.seed ?? '').trim();
    if (seed.isNotEmpty) {
      _search.text = seed;
      _runSearch(seed);
    }
    if ((widget.email ?? '').contains('@')) {
      _ownerEmail.text = widget.email!.trim();
    }
    // Chosen on the pricing page; a saved draft below can still win.
    if (widget.plan == 'premium' || widget.plan == 'verified') {
      _plan = 'verified';
    }
    if (widget.period == 'monthly' || widget.period == 'yearly') {
      _restorePeriod = widget.period;
    }
    final cur = (widget.currency ?? '').trim().toUpperCase();
    if (RegExp(r'^[A-Z]{3}$').hasMatch(cur)) _restoreCurrency = cur;
    // Back from Stripe (Cancel there, or the browser's Back button): a
    // draft saved on the way out puts the visitor on the plans with
    // their details, unless they arrived from a link for a different
    // space.
    final cancelled = Uri.base.queryParameters.containsKey('cancelled');
    SupabaseService.loadClaimDraft().then((d) {
      if (!mounted || d == null) return;
      final picked = d['picked'];
      final place = d['place'];
      final draftName = picked is Map
          ? '${picked['name'] ?? ''}'
          : (place is Map ? '${place['main'] ?? ''}' : '');
      final draftSlug = picked is Map ? '${picked['webflow_slug'] ?? ''}' : '';
      final sameSpace = seed.isEmpty ||
          seed.toLowerCase() == draftName.toLowerCase() ||
          seed == draftSlug;
      if (!cancelled && !sameSpace) return;
      setState(() {
        if (_applyDraft(d)) {
          _track('claim_resumed', {
            'cancelled': cancelled,
            if (_spaceName.isNotEmpty) 'space': _spaceName,
          });
        }
      });
    });
    _track('claim_opened', {
      'seed': seed,
      'from': widget.from,
      if (widget.plan != null) 'plan': widget.plan,
      'referrer': ua.referrer(),
      'device': ua.deviceKind(),
    });
    for (final f in {
      _ownerName: 'name',
      _ownerRole: 'role',
      _ownerEmail: 'email',
      _ownerPhone: 'phone',
      _enquiryEmail: 'enquiry_email',
      _siteUrl: 'website',
      _instagram: 'instagram',
      _note: 'note',
    }.entries) {
      _watchField(f.key, f.value);
    }
    ua.setPageHideHandler(_onLeave);
    // Ring the phone, unless the visitor is a crawler. From the
    // pricing link it waits until a space is found.
    if (!_fromPricing) _ring(seed);
  }

  /// The "someone opened the claim page" notice. It says roughly where
  /// the visitor is (migration 154), so it waits a moment for that.
  void _ring(String seed) {
    if (Analytics.isBot || _rang) return;
    _rang = true;
    final from = widget.from;
    final referrer = ua.referrer();
    final agent = ua.userAgent();
    Analytics.claimGeo(_visit).then((geo) => _supabase.claimOpened(
        seed: seed,
        from: from,
        referrer: referrer,
        userAgent: agent,
        geo: geo));
  }

  /// From the pricing link: ring once, when the space is known, with
  /// its page (or its name) so the notice says which space it is.
  void _ringOnce() {
    if (!_fromPricing || _rang) return;
    final slug = _picked == null ? '' : '${_picked!['webflow_slug'] ?? ''}';
    _ring(slug.isNotEmpty ? slug : _spaceName);
  }

  @override
  void dispose() {
    ua.setPageHideHandler(null);
    _searchTimer?.cancel();
    _placeTimer?.cancel();
    for (final c in [
      _search,
      _placeSearch,
      _ownerName,
      _ownerRole,
      _ownerEmail,
      _ownerPhone,
      _enquiryEmail,
      _note,
      _siteUrl,
      _instagram,
      _website,
    ]) {
      c.dispose();
    }
    _phoneCountry.dispose();
    super.dispose();
  }

  String get _spaceName => _picked != null
      ? '${_picked!['name']}'
      : (_pickedPlace?.main ?? '').trim();

  String get _where => _picked != null
      ? [_picked!['neighbourhood'], _picked!['city'], _picked!['country']]
          .where((x) => x != null && '$x'.isNotEmpty)
          .join(', ')
      : (_newAddress ?? '');

  bool get _alreadyPublished => _picked != null && _picked!['on_site'] == true;

  // ---------------------------------------------------------------- search

  void _scheduleSearch(String q) {
    _searchTimer?.cancel();
    if (q.trim().length < 2) {
      setState(() {
        _hits = [];
        _searched = false;
      });
      return;
    }
    _searchTimer = Timer(const Duration(milliseconds: 350), () => _runSearch(q));
  }

  Future<void> _runSearch(String q) async {
    setState(() => _searching = true);
    final rows = await _supabase.claimSearch(q);
    if (!mounted) return;
    _track('claim_searched', {'q': q.trim(), 'results': rows.length});
    // A link from a listing page carries that page's slug: when the
    // search finds exactly that page, it is chosen without a tap.
    final exact = rows.where((r) => r['webflow_slug'] == q.trim()).toList();
    setState(() {
      _hits = rows;
      _searching = false;
      _searched = true;
      if (exact.length == 1 &&
          exact.first['already_verified'] != true &&
          _picked == null &&
          _step == _Step.find) {
        _picked = exact.first;
        _search.text = '${exact.first['name']}';
        _go(_Step.plans, how: 'link_matched');
      }
    });
  }

  void _schedulePlaces(String q) {
    _placeTimer?.cancel();
    if (q.trim().length < 2) {
      setState(() => _suggestions = []);
      return;
    }
    _placeTimer = Timer(const Duration(milliseconds: 350), () async {
      setState(() => _placeBusy = true);
      final out = await _places.autocomplete(q);
      if (!mounted) return;
      _track('claim_place_searched', {'q': q.trim(), 'results': out.length});
      setState(() {
        _suggestions = out;
        _placeBusy = false;
      });
    });
  }

  Future<void> _choosePlace(PlaceSuggestion s) async {
    setState(() {
      _pickedPlace = s;
      _placeBusy = true;
    });
    final d = await _places.details(s.placeId);
    if (!mounted) return;
    final addr = d?.address ?? s.secondary;
    setState(() {
      _newAddress = addr;
      _newCity = d?.city;
      _newCountry = d?.country ?? _countryFrom(addr);
      _newLat = d?.lat;
      _newLng = d?.lng;
      _newType = (d?.primaryType == 'coworking_space' ||
              s.main.toLowerCase().contains('cowork'))
          ? 'coworking'
          : (d?.primaryType?.contains('cafe') ?? false)
              ? 'cafe'
              : _newType;
      _placeBusy = false;
      _go(_Step.plans, how: 'google_place');
    });
  }

  /// Google's short address ends with the country in most locales.
  static String? _countryFrom(String? address) {
    if (address == null || address.isEmpty) return null;
    final parts = address.split(',').map((p) => p.trim()).toList();
    if (parts.length < 2) return null;
    final last = parts.last;
    return last.length >= 3 && !RegExp(r'^\d').hasMatch(last) ? last : null;
  }

  // ------------------------------------------------------------------- pay

  Future<void> _startAndPay() async {
    if (_website.text.isNotEmpty) return; // a bot
    final email = _ownerEmail.text.trim().toLowerCase();
    final problem = _detailsProblem();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final res = await _supabase.startClaim(_claimFields());
      final claimId = '${res?['claim_id'] ?? ''}';
      if (claimId.isEmpty) throw Exception('no claim id');
      _done = true;
      await SupabaseService.rememberClaim(
          email: email,
          space: _spaceName,
          type: _picked != null ? '${_picked!['type'] ?? ''}' : _newType,
          claimId: claimId);
      _track('claim_to_payment', {
        'space': _spaceName,
        'new_space': _picked == null,
      });
      // The chosen period and currency through Stripe Checkout; the
      // yearly payment link in euros until the prices are in Stripe.
      final p = _pricing;
      String? checkout;
      if (p != null && p.ready) {
        final r = await _supabase.startCheckout(claimId, p.period, p.currency);
        checkout = r['url'] is String ? r['url'] as String : null;
        if (checkout == null && r['error'] != 'not_ready') {
          // A real failure (Stripe refused, or timed out): say so rather
          // than quietly charging a different plan.
          throw Exception(
              'Payment could not be started. Please try again in a moment.');
        }
      }
      final url = Uri.parse(checkout ??
          '${AppConfig.stripeVerifiedLink}'
              '?client_reference_id=$claimId'
              '&prefilled_email=${Uri.encodeQueryComponent(email)}');
      // Back or Cancel from Stripe lands on the plans with everything
      // still filled in; a finished payment clears this on the thank-you
      // page.
      await SupabaseService.saveClaimDraft(_draft());
      await launchUrl(url,
          mode: LaunchMode.platformDefault, webOnlyWindowName: '_self');
    } catch (e) {
      _done = false;
      _track('claim_failed', {'why': _plain(e), 'plan': 'verified'});
      if (mounted) setState(() => _error = _plain(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// The free door: the same claim, no payment. Lands as a claim
  /// waiting for approval in the control centre.
  Future<void> _claimFree() async {
    if (_website.text.isNotEmpty) return; // a bot
    final email = _ownerEmail.text.trim().toLowerCase();
    final problem = _detailsProblem();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final res = await _supabase.startClaim({
        'plan': 'free',
        ..._claimFields(),
      });
      final claimId = '${res?['claim_id'] ?? ''}';
      if (claimId.isEmpty) throw Exception('no claim id');
      _done = true;
      await SupabaseService.rememberClaim(
          email: email,
          space: _spaceName,
          type: _picked != null ? '${_picked!['type'] ?? ''}' : _newType,
          claimId: claimId);
      _track('claim_free', {
        'space': _spaceName,
        'new_space': _picked == null,
      });
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => const ClaimedScreen(free: true)));
    } catch (e) {
      _done = false;
      _track('claim_failed', {'why': _plain(e), 'plan': 'free'});
      if (mounted) setState(() => _error = _plain(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  static String _plain(Object e) {
    final s = '$e';
    final m = RegExp(r'(Too many|A working|Your name|The name|This listing|'
            r'That listing|We are busy)[^\n"}]*')
        .firstMatch(s);
    if (m != null) return m.group(0)!;
    return 'That did not go through. Please try again in a moment.';
  }

  // ----------------------------------------------------------------- build

  /// One corner radius for every box on the form: the plan cards, the
  /// search field, the result tiles, the buttons.
  static const double _corner = 16;

  // Buttons drawn the way nomadwise.io draws them (S3-13/14).
  @override
  Widget build(BuildContext context) =>
      Theme(
          data: siteButtons(Theme.of(context), radius: _corner),
          child: _page(context));

  Widget _page(BuildContext context) {
    _ensurePricing();
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(
        titleSpacing: 20,
        title: const Text('Claim your space'),
        leading: _step == _Step.find
            ? IconButton(
                tooltip: 'nomadwise.io',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => launchUrl(
                    Uri.parse('https://www.nomadwise.io'),
                    mode: LaunchMode.platformDefault))
            : IconButton(
                icon: const Icon(Icons.arrow_back), onPressed: _back),
        // As on the pricing page: owners who already have their page
        // sign in instead.
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton(
                onPressed: () => launchUrl(
                    Uri.parse(AppConfig.ownerAccountUrl),
                    webOnlyWindowName: '_self'),
                child: Text(MediaQuery.sizeOf(context).width >= _wideAt
                    ? 'Sign in to your Owner account'
                    : 'Sign in')),
          ),
        ],
      ),
      body: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= _wideAt;
        // Step two is the pricing page and fits one laptop screen, so
        // it starts higher.
        final top = _step == _Step.plans ? 18.0 : 36.0;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              wide ? 32 : 18, wide ? top : 18, wide ? 32 : 18, 64),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: wide ? 1060 : 600),
              child: switch (_step) {
                _Step.find => _findStep(wide),
                _Step.addSpace => _addStep(wide),
                _Step.plans => _plansStep(wide),
                _Step.about => _aboutStep(wide),
              },
            ),
          ),
        );
      }),
    );
  }

  void _back() {
    setState(() {
      _error = null;
      _go(
          switch (_step) {
            _Step.about => _Step.plans,
            _Step.plans => _picked != null ? _Step.find : _Step.addSpace,
            _Step.addSpace => _Step.find,
            _Step.find => _Step.find,
          },
          how: 'back');
    });
  }

  // --------------------------------------------------------- shared pieces

  Widget _heading(bool wide, int step, String title, String blurb) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('STEP $step OF 3',
              style: const TextStyle(
                  color: Brand.inkMuted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8)),
          SizedBox(height: wide ? 8 : 4),
          Text(title,
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: wide ? 34 : 24,
                  height: 1.15,
                  letterSpacing: wide ? -0.6 : -0.2)),
          if (blurb.isNotEmpty) ...[
            SizedBox(height: wide ? 12 : 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Text(blurb,
                  style: TextStyle(
                      color: Brand.inkSecondary,
                      fontSize: wide ? 15.5 : 13.5,
                      height: 1.55)),
            ),
          ],
        ],
      );

  InputDecoration _field(String label,
          {String? hint, String? helper, Widget? prefix, Widget? suffix}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 3,
        prefixIcon: prefix,
        suffixIcon: suffix,
        filled: true,
        fillColor: Brand.surface,
      );

  static const _spinner = Padding(
    padding: EdgeInsets.all(12),
    child: SizedBox(
        width: 16,
        height: 16,
        child:
            CircularProgressIndicator(strokeWidth: 2, color: Brand.inkMuted)),
  );

  // ------------------------------------------------------------ step one

  /// Step one is the search and nothing else (Jonathan, 30 Oct 2026:
  /// "the only thing that it shows to begin with, is to find your
  /// space"). The plans and the price for its country come next.
  Widget _findStep(bool wide) => _narrow(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _heading(wide, 1, 'Find your space',
              'Search for your coworking space or cafe. Next you will see '
                  'Free and Premium, with the Premium price for your '
                  'country. Not here yet? You can add it.'),
          SizedBox(height: wide ? 24 : 16),
          TextField(
            controller: _search,
            autofocus: wide,
            textCapitalization: TextCapitalization.words,
            onChanged: _scheduleSearch,
            style: TextStyle(fontSize: wide ? 16 : 15),
            decoration: _field('Name of your space',
                hint: 'e.g. Tribal Bali',
                prefix: const Icon(Icons.search, size: 20),
                suffix: _searching ? _spinner : null),
          ),
          const SizedBox(height: 14),
          ..._hits.map((h) => _hitTile(h, wide)),
          if (_searched && _hits.isEmpty && !_searching)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text('Nothing under that name yet.',
                  style: TextStyle(color: Brand.inkMuted, fontSize: 13)),
            ),
          const SizedBox(height: 10),
          const Divider(color: Brand.hairline),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => setState(() {
                _go(_Step.addSpace, how: 'not_here');
                _picked = null;
                _placeSearch.text = _search.text;
                if (_search.text.trim().length >= 2) {
                  _schedulePlaces(_search.text);
                }
              }),
              icon: const Icon(Icons.add_location_alt_outlined, size: 18),
              label: const Text("My space isn't here, add it"),
              style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.symmetric(
                      vertical: 14, horizontal: wide ? 22 : 16)),
            ),
          ),
        ]),
      );

  Widget _hitTile(Map<String, dynamic> h, bool wide) {
    final verified = h['already_verified'] == true;
    final onSite = h['on_site'] == true;
    final where = [h['neighbourhood'], h['city'], h['country']]
        .where((x) => x != null && '$x'.isNotEmpty)
        .join(', ');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(_corner),
        border: Border.all(color: Brand.border),
      ),
      child: ListTile(
        contentPadding:
            EdgeInsets.symmetric(horizontal: wide ? 18 : 14, vertical: 4),
        title: Text('${h['name']}',
            style: TextStyle(
                fontWeight: FontWeight.w700, fontSize: wide ? 15.5 : 14.5)),
        subtitle: Text(
            verified
                ? '$where · already on Premium'
                : onSite
                    ? '$where · has a page on nomadwise.io'
                    : '$where · not published yet',
            style: TextStyle(
                fontSize: wide ? 12.5 : 12, color: Brand.inkSecondary)),
        trailing: verified
            ? const Icon(Icons.verified, size: 20, color: Brand.success)
            : const Icon(Icons.chevron_right, color: Brand.inkMuted),
        onTap: verified
            ? () => _alreadyVerified('${h['name']}')
            : () => setState(() {
                  _picked = h;
                  _pickedPlace = null;
                  _go(_Step.plans,
                      how: onSite ? 'picked_listed' : 'picked_unpublished');
                }),
      ),
    );
  }

  void _alreadyVerified(String name) {
    _track('claim_already_verified', {'space': name});
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$name is already on Premium'),
        content: const Text(
            'Someone has already claimed this listing. If that was not you, '
            'email hello@nomadwise.io and we will look into it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.red),
            onPressed: () {
              Navigator.pop(ctx);
              launchUrl(Uri.parse('mailto:hello@nomadwise.io?subject='
                  '${Uri.encodeComponent('About the listing for $name')}'));
            },
            child: const Text('Email us'),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------- step one (add it)

  Widget _addStep(bool wide) => _narrow(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _heading(wide, 1, 'Add your space',
              'Search for your business as it appears on Google Maps. That '
                  'gives us the right address, opening hours and photos from '
                  'the start, so your page is ready to publish.'),
          SizedBox(height: wide ? 24 : 16),
          TextField(
            controller: _placeSearch,
            autofocus: wide,
            onChanged: _schedulePlaces,
            style: TextStyle(fontSize: wide ? 16 : 15),
            decoration: _field('Your business on Google',
                hint: 'e.g. Tribal Bali, Pererenan',
                prefix: const Icon(Icons.place_outlined, size: 20),
                suffix: _placeBusy ? _spinner : null),
          ),
          const SizedBox(height: 14),
          ..._suggestions.map((s) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Brand.surface,
                  borderRadius: BorderRadius.circular(_corner),
                  border: Border.all(color: Brand.border),
                ),
                child: ListTile(
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: wide ? 18 : 14, vertical: 4),
                  title: Text(s.main,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: wide ? 15.5 : 14.5)),
                  subtitle: Text(s.secondary,
                      style: TextStyle(
                          fontSize: wide ? 12.5 : 12,
                          color: Brand.inkSecondary)),
                  trailing:
                      const Icon(Icons.chevron_right, color: Brand.inkMuted),
                  onTap: () => _choosePlace(s),
                ),
              )),
          const SizedBox(height: 16),
          const Text(
              'Not on Google Maps? Email hello@nomadwise.io and we will add '
              'you by hand.',
              style:
                  TextStyle(color: Brand.inkMuted, fontSize: 12.5, height: 1.5)),
        ]),
      );

  // ---------------------------------------------------------- step three

  Widget _aboutStep(bool wide) {
    final fields = <Widget>[
      _pickedCard(wide),
      _planLine(wide),
      if (_picked == null) ...[
        SizedBox(height: wide ? 22 : 16),
        const Text('What kind of place is it?',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'coworking', label: Text('Coworking')),
              ButtonSegment(value: 'cafe', label: Text('Cafe')),
            ],
            selected: {_newType},
            onSelectionChanged: (s) => setState(() => _newType = s.first),
          ),
        ),
      ],
      SizedBox(height: wide ? 26 : 18),
      TextField(
          controller: _ownerName,
          textCapitalization: TextCapitalization.words,
          decoration: _field('Your name')),
      const SizedBox(height: 16),
      const Text('Your role at the space',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (key, label) in _roles)
          ChoiceChip(
            label: Text(label),
            selected: _role == key,
            showCheckmark: false,
            selectedColor: Brand.ink,
            labelStyle: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _role == key ? Colors.white : Brand.ink),
            onSelected: (_) {
              setState(() => _role = key);
              _track('claim_role', {'role': key});
            },
          ),
      ]),
      if (_role == 'Other') ...[
        const SizedBox(height: 12),
        TextField(
            controller: _ownerRole,
            textCapitalization: TextCapitalization.sentences,
            decoration: _field('Your job title (optional)',
                hint: 'Community lead, front desk, founder')),
      ],
      const SizedBox(height: 16),
      _pair(
        wide,
        Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                  controller: _ownerEmail,
                  keyboardType: TextInputType.emailAddress,
                  decoration: _field('Your email',
                      helper: 'An email at the business\'s own address (like '
                          'you@yourspace.com) is the quickest way we confirm you.')),
              EmailTypoHint(controller: _ownerEmail),
            ]),
        PhoneField(
            number: _ownerPhone,
            country: _phoneCountry,
            helper: 'A WhatsApp number is ideal.'),
      ),
      _signedInNote(),
      const SizedBox(height: 16),
      // Where enquiries go: the email above, unless they say otherwise.
      // A ticked box reads as the normal case; unticking reveals the
      // field, so nobody has to work out what "optional" means.
      AnimatedBuilder(
        animation: _ownerEmail,
        builder: (_, __) {
          final own = _ownerEmail.text.trim();
          return Container(
            decoration: BoxDecoration(
                border: Border.all(color: Brand.border),
                borderRadius: BorderRadius.circular(_corner)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              CheckboxListTile(
                value: _sameEnquiryEmail,
                onChanged: (v) => setState(() => _sameEnquiryEmail = v ?? true),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: const EdgeInsets.fromLTRB(8, 2, 12, 2),
                title: Text(
                    own.contains('@')
                        ? 'Send enquiries from nomads to $own'
                        : 'Send enquiries from nomads to the email above',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                subtitle: const Text(
                    'When a nomad uses the Send an enquiry button on your '
                    'page, it goes to this address.',
                    style: TextStyle(fontSize: 12.5, height: 1.4)),
              ),
              if (!_sameEnquiryEmail)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                    TextField(
                        controller: _enquiryEmail,
                        autofocus: true,
                        keyboardType: TextInputType.emailAddress,
                        decoration: _field('Email for enquiries',
                            hint: 'hello@yourspace.com',
                            helper: 'A shared inbox, or whoever answers '
                                'bookings.')),
                    EmailTypoHint(controller: _enquiryEmail),
                  ]),
                ),
            ]),
          );
        },
      ),
      if (_plan == 'verified' &&
          !_showExtras &&
          _siteUrl.text.trim().isEmpty &&
          _instagram.text.trim().isEmpty &&
          _note.text.trim().isEmpty) ...[
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
              onPressed: () => setState(() => _showExtras = true),
              icon: const Icon(Icons.add, size: 18),
              label: const Text(
                  'Add your website, Instagram or a note (optional)')),
        ),
      ] else ...[
      const SizedBox(height: 16),
      _pair(
        wide,
        TextField(
            controller: _siteUrl,
            keyboardType: TextInputType.url,
            decoration: _field('Website (optional)', hint: 'yourspace.com')),
        TextField(
            controller: _instagram,
            decoration: InputDecoration(
                labelText: 'Instagram (optional)',
                hintText: 'yourspace',
                prefixText: '@',
                helperText: 'Your handle, or paste the profile link.',
                filled: true,
                fillColor: Brand.surface),
            onChanged: (v) {
              // A pasted link or a typed @ becomes the bare handle; the
              // @ is already shown in front.
              final h = igHandle(v);
              if (h != null && h != v) {
                _instagram.value = TextEditingValue(
                    text: h,
                    selection: TextSelection.collapsed(offset: h.length));
              }
            }),
      ),
      const SizedBox(height: 16),
      TextField(
          controller: _note,
          minLines: 3,
          maxLines: 8,
          textCapitalization: TextCapitalization.sentences,
          decoration: _field('Anything we should know? (optional)',
              hint: 'Day pass price, opening hours, a correction...')),
      ],
      Offstage(
          offstage: true,
          child: TextField(controller: _website, autofocus: false)),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text(_error!,
              style: const TextStyle(color: Brand.red, fontSize: 13)),
        ),
      SizedBox(height: wide ? 26 : 20),
      Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: wide ? 260 : double.infinity,
          child: FilledButton(
            onPressed: _sending ? null : _submit,
            style: FilledButton.styleFrom(
                backgroundColor: Brand.red,
                padding: const EdgeInsets.symmetric(vertical: 16)),
            child: Text(_sending
                ? 'One moment'
                : _plan == 'verified'
                    ? 'Continue to payment'
                    : 'Claim my page'),
          ),
        ),
      ),
      const SizedBox(height: 14),
      Text(
          _alreadyPublished
              ? 'We first check you are with the team at $_spaceName, then '
                  'the page is yours to manage.'
              : 'Your space joins our publishing queue and we email you when '
                  'the page is live. We first check you are with the team, '
                  'then it is yours to manage.',
          style: TextStyle(
              color: Brand.inkSecondary,
              fontSize: wide ? 14.5 : 13.5,
              height: 1.5)),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading(wide, 3, 'Your details',
          'For the owner, or anyone the business has asked to look after '
              'its page: a manager, the marketing lead. Before we hand the '
              'page over, we check you are with the team.'),
      SizedBox(height: wide ? 26 : 18),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: wide ? 760 : double.infinity),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: fields),
      ),
    ]);
  }

  /// Signed in as someone else? The claim belongs to the email typed
  /// above (it is the one we check and write to); say so, so nobody is
  /// surprised when their signed-in account does not show the space.
  Widget _signedInNote() => ValueListenableBuilder<TextEditingValue>(
        valueListenable: _ownerEmail,
        builder: (_, v, __) {
          final me = _supabase.userEmail;
          final typed = v.text.trim().toLowerCase();
          if (me == null || !typed.contains('@') || typed == me) {
            return const SizedBox.shrink();
          }
          return Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: Brand.goldTint, borderRadius: BorderRadius.circular(10)),
            child: Text(
                'You are signed in as $me. The space will be claimed with '
                '$typed, so sign in with $typed to manage it.',
                style: const TextStyle(fontSize: 12.5, height: 1.45)),
          );
        },
      );

  /// Side by side on a desktop, stacked on a phone.
  Widget _pair(bool wide, Widget a, Widget b) => wide
      ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: a),
          const SizedBox(width: 16),
          Expanded(child: b),
        ])
      : Column(children: [a, const SizedBox(height: 16), b]);

  /// The chosen space, with Change (back to the search). [big] draws
  /// the name larger, without Change.
  Widget _pickedCard(bool wide, {bool big = false}) => Container(
        padding: EdgeInsets.all(wide ? 18 : 14),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(_corner),
          border: Border.all(color: Brand.border),
        ),
        child: Row(children: [
          Icon(Icons.storefront_outlined,
              color: Brand.inkMuted, size: big ? 28 : 24),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_spaceName,
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: big ? (wide ? 22 : 19) : (wide ? 16 : 15),
                          height: 1.2,
                          letterSpacing: big ? -0.3 : 0)),
                  if (_where.isNotEmpty) ...[
                    if (big) const SizedBox(height: 2),
                    Text(_where,
                        style: TextStyle(
                            fontSize: big ? 14 : 12.5,
                            color: Brand.inkSecondary)),
                  ],
                ]),
          ),
          if (!big)
            TextButton(onPressed: _changeSpace, child: const Text('Change')),
        ]),
      );

  /// Back to finding the space (or adding it), from steps two and three.
  void _changeSpace() {
    setState(() {
      _error = null;
      _resumed = false;
      _go(_picked != null ? _Step.find : _Step.addSpace, how: 'change_space');
    });
  }

  /// Steps one and "add it": one column, left aligned.
  Widget _narrow(Widget main) => Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 660),
            child: SizedBox(width: double.infinity, child: main)),
      );

  // ------------------------------------------------------------ step two

  /// Step two is the pricing page for this space (Jonathan, 30 Oct 2026:
  /// find your space first, "and then it presents the pricing page, all
  /// above the fold"): the space and where it is, Monthly / Yearly and
  /// the currency, then Free and Premium side by side with the price for
  /// its country. Each plan's button goes on to Your details. Claiming
  /// is free; Premium is the optional upgrade (Leonie's review, 28 Sep).
  Widget _plansStep(bool wide) {
    final p = _pricing;
    final waiting = _pricingFailed || (p != null && p.chosen == null)
        ? 'See your price at checkout'
        : 'One moment';
    final bar = Container(
      padding: EdgeInsets.symmetric(
          horizontal: wide ? 16 : 14, vertical: wide ? 10 : 14),
      decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Brand.border)),
      child: Wrap(
          spacing: 28,
          runSpacing: 10,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _spaceLine(wide),
            if (p != null)
              Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    PeriodToggle(
                        choice: p,
                        onChanged: (c) => setState(() => _pricing = c)),
                    CurrencyPicker(
                        choice: p,
                        onChanged: (c) => setState(() => _pricing = c)),
                  ]),
          ]),
    );
    final align = wide ? TextAlign.center : TextAlign.start;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 940),
        child: Column(
            crossAxisAlignment:
                wide ? CrossAxisAlignment.center : CrossAxisAlignment.stretch,
            children: [
              const Text('STEP 2 OF 3',
                  style: TextStyle(
                      color: Brand.inkMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8)),
              SizedBox(height: wide ? 6 : 4),
              Text('Free to be on Nomadwise. Premium to stand out.',
                  textAlign: align,
                  style: TextStyle(
                      fontSize: wide ? 30 : 24,
                      height: 1.2,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      color: Brand.ink)),
              const SizedBox(height: 6),
              Text(
                  _resumed
                      ? 'Nothing was charged. Your details are still here, so '
                          'pick a plan when you are ready.'
                      : 'Claiming your page is free. Premium is optional, '
                          'monthly or yearly, and you can cancel any time.',
                  textAlign: align,
                  style: const TextStyle(
                      fontSize: 15, height: 1.5, color: Brand.inkSecondary)),
              SizedBox(height: wide ? 14 : 16),
              bar,
              SizedBox(height: wide ? 26 : 20),
              PricingPlans(
                pricing: p,
                wide: wide,
                waiting: waiting,
                onFree: () => _choosePlan('free'),
                onPremium: () => _choosePlan('verified'),
              ),
              SizedBox(height: wide ? 14 : 24),
              Text(
                  'You pay the price for the country your space is in. '
                  'Your details come next.',
                  textAlign: align,
                  style: const TextStyle(
                      fontSize: 13, height: 1.5, color: Brand.inkSecondary)),
            ]),
      ),
    );
  }

  /// The space on step two's bar: its name, where it is, and Change.
  Widget _spaceLine(bool wide) => Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.storefront_outlined, color: Brand.inkMuted, size: 22),
        const SizedBox(width: 10),
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: wide ? 360 : double.infinity),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_spaceName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Brand.ink)),
                  if (_where.isNotEmpty)
                    Text(_where,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5, color: Brand.inkSecondary)),
                ]),
          ),
        ),
        const SizedBox(width: 4),
        TextButton(onPressed: _changeSpace, child: const Text('Change')),
      ]);

  /// On Your details: the plan chosen on step two, and a way back to it.
  Widget _planLine(bool wide) {
    final p = _pricing;
    final premium = _plan == 'verified';
    final price = premium && p != null && p.chosen != null
        ? ', ${formatMoney(p.chosen!, p.currency)} '
            '${p.period == 'yearly' ? 'a year' : 'a month'}'
        : '';
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: EdgeInsets.fromLTRB(wide ? 18 : 14, 4, 6, 4),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(_corner),
        border: Border.all(
            color: premium ? Brand.red : Brand.border, width: premium ? 1.5 : 1),
      ),
      child: Row(children: [
        Icon(premium ? Icons.verified : Icons.check_circle_outline,
            size: 20, color: premium ? Brand.success : Brand.inkMuted),
        const SizedBox(width: 10),
        Expanded(
          child: Text('Your plan: ${premium ? 'Premium' : 'Free'}$price',
              style: const TextStyle(
                  fontSize: 14.5, fontWeight: FontWeight.w700, color: Brand.ink)),
        ),
        TextButton(onPressed: _back, child: const Text('Change plan')),
      ]),
    );
  }

  /// The last button: claims for free, or saves the claim and goes on
  /// to payment.
  void _submit() {
    final problem = _detailsProblem();
    if (problem != null) {
      _track('claim_blocked', {'why': problem});
      setState(() => _error = problem);
      return;
    }
    if (_plan == 'verified') {
      _startAndPay();
    } else {
      _claimFree();
    }
  }
}

/// Where Stripe sends the owner back to after paying (and where the
/// free claim lands): says what they did, in their words ("You've
/// claimed your cafe"), and what happens next, so nobody is left
/// wondering whether anything reached us. The Owner account button
/// carries the email they claimed with, so signing in is one tap.
class ClaimedScreen extends StatefulWidget {
  const ClaimedScreen({super.key, this.free = false});

  /// A free claim: no payment, the page stays free, we confirm the
  /// person runs the space and record them as its owner.
  final bool free;

  @override
  State<ClaimedScreen> createState() => _ClaimedScreenState();
}

class _ClaimedScreenState extends State<ClaimedScreen> {
  Map<String, dynamic>? _claim;

  @override
  void initState() {
    super.initState();
    // The claim went through, so there is nothing to come back to.
    SupabaseService.clearClaimDraft();
    SupabaseService.lastClaim().then((c) {
      if (mounted) setState(() => _claim = c);
      // Back from Stripe: have the payment picked up now, not at the
      // next scheduled sync, and remember we are waiting for it.
      final id = '${c?['claim_id'] ?? ''}';
      if (!widget.free && id.isNotEmpty) {
        SupabaseService.markReturnedFromStripe();
        SupabaseService().paymentReturned(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final free = widget.free;
    final email = '${_claim?['email'] ?? ''}';
    final space = '${_claim?['space'] ?? ''}'.trim();
    final kind = SupabaseService.spaceKind('${_claim?['type'] ?? ''}');
    final spaceName = space.isEmpty ? 'your $kind' : space;
    final ownerUrl = email.contains('@')
        ? 'https://nomadmaps.io/?owner&email=${Uri.encodeQueryComponent(email)}'
        : AppConfig.ownerAccountUrl;
    final heading = free
        ? "You've claimed your $kind"
        : "Payment received, you're almost there";
    final text = free
        ? '${space.isEmpty ? '' : 'Thank you for claiming $space. '}'
            'Next we check you are with the team at $spaceName; we email you'
            '${email.contains('@') ? ' at $email' : ''} as soon as that is '
            'done, and the page is yours to manage.\n\n'
            'Your Owner account is ready now: sign in to see where things '
            'stand.'
        : "You've claimed your $kind${space.isEmpty ? '' : ', $space'}, and "
            'your payment has reached us. Next we check you are with the '
            'team at $spaceName, then Premium goes on and we email you'
            '${email.contains('@') ? ' at $email' : ''}.\n\n'
            'Your Owner account is ready now: sign in to see where things '
            'stand.';
    return Scaffold(
      backgroundColor: Brand.bg,
      body: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= _wideAt;
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: wide ? 88 : 76,
                  height: wide ? 88 : 76,
                  decoration: const BoxDecoration(
                      color: Brand.successTint, shape: BoxShape.circle),
                  child: Icon(Icons.check,
                      size: wide ? 42 : 36, color: Brand.success),
                ),
                SizedBox(height: wide ? 24 : 18),
                Text(heading,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: wide ? 30 : 23,
                        letterSpacing: -0.5)),
                const SizedBox(height: 12),
                Text(text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Brand.inkSecondary,
                        height: 1.65,
                        fontSize: wide ? 15 : 14)),
                SizedBox(height: wide ? 28 : 22),
                FilledButton.icon(
                    onPressed: () => launchUrl(Uri.parse(ownerUrl),
                        webOnlyWindowName: '_self'),
                    style: FilledButton.styleFrom(
                        backgroundColor: Brand.red,
                        padding: const EdgeInsets.symmetric(
                            vertical: 14, horizontal: 22)),
                    icon: const Icon(Icons.person_outline, size: 16),
                    label: const Text('Go to my Owner account')),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                    onPressed: () => launchUrl(
                        Uri.parse('https://www.nomadwise.io'),
                        mode: LaunchMode.platformDefault),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            vertical: 14, horizontal: 22)),
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('Back to nomadwise.io')),
                const SizedBox(height: 14),
                const Text('Questions? hello@nomadwise.io',
                    style: TextStyle(color: Brand.inkMuted, fontSize: 12.5)),
              ]),
            ),
          ),
        );
      }),
    );
  }
}
