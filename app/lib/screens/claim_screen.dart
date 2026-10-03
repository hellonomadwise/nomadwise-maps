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
import '../widgets/ui.dart' show PlanFeatureRow;

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
  const ClaimScreen({super.key, this.seed, this.from, this.email});
  @override
  State<ClaimScreen> createState() => _ClaimScreenState();
}

enum _Step { find, addSpace, about, pay }

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

  // What Verified costs here (migration 115): loaded for the space's
  // country, with the monthly/yearly and currency choices on it.
  PricingChoice? _pricing;
  String _pricingCountry = '\u0000';

  /// The plan picked on the overview cards ('free' or 'verified').
  /// Free to start with; step three leads with whichever is chosen,
  /// and both buttons stay there, so the choice is never final.
  String _plan = 'free';

  void _choosePlan(String plan) {
    if (plan == _plan) return;
    setState(() => _plan = plan);
    _track('claim_plan_pick', {'plan': plan});
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
    _supabase.pricingFor(c).then((p) {
      if (!mounted || p == null || _pricingCountry != c) return;
      setState(() => _pricing = PricingChoice(p));
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
        _Step.about => 'about',
        _Step.pay => 'plan',
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
    _track('claim_opened', {
      'seed': seed,
      'from': widget.from,
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
    // Ring the phone, unless the visitor is a crawler.
    if (!Analytics.isBot) {
      _supabase.claimOpened(
          seed: seed,
          from: widget.from,
          referrer: ua.referrer(),
          userAgent: ua.userAgent());
    }
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
        _go(_Step.about, how: 'link_matched');
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
      _go(_Step.about, how: 'google_place');
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

  // Buttons drawn the way nomadwise.io draws them (S3-13/14).
  @override
  Widget build(BuildContext context) =>
      Theme(data: siteButtons(Theme.of(context)), child: _page(context));

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
      ),
      body: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= _wideAt;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              wide ? 32 : 18, wide ? 36 : 18, wide ? 32 : 18, 64),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: wide ? 1060 : 600),
              child: switch (_step) {
                _Step.find => _findStep(wide),
                _Step.addSpace => _addStep(wide),
                _Step.about => _aboutStep(wide),
                _Step.pay => _payStep(wide),
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
            _Step.pay => _Step.about,
            _Step.about => _picked != null ? _Step.find : _Step.addSpace,
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

  Widget _findStep(bool wide) => _withPlans(
        wide,
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _heading(wide, 1, 'Find your space',
              'Nomadwise lists thousands of coworking spaces and '
                  'laptop-friendly cafes. Search for yours below, and if it is '
                  'not here yet you can add it in the next step.'),
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
        borderRadius: BorderRadius.circular(12),
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
                ? '$where · already Verified'
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
                  _go(_Step.about,
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
        title: Text('$name is already Verified'),
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

  Widget _addStep(bool wide) => _withPlans(
        wide,
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
                  borderRadius: BorderRadius.circular(12),
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

  // ------------------------------------------------------------ step two

  Widget _aboutStep(bool wide) {
    final fields = <Widget>[
      _pickedCard(wide),
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
        TextField(
            controller: _ownerEmail,
            keyboardType: TextInputType.emailAddress,
            decoration: _field('Your email',
                helper: 'An email at the business\'s own address (like '
                    'you@yourspace.com) is the quickest way we confirm you.')),
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
                borderRadius: BorderRadius.circular(8)),
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
                  child: TextField(
                      controller: _enquiryEmail,
                      autofocus: true,
                      keyboardType: TextInputType.emailAddress,
                      decoration: _field('Email for enquiries',
                          hint: 'hello@yourspace.com',
                          helper: 'A shared inbox, or whoever answers '
                              'bookings.')),
                ),
            ]),
          );
        },
      ),
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
            onPressed: () {
              final problem = _detailsProblem();
              if (problem != null) {
                _track('claim_blocked', {'why': problem});
                setState(() => _error = problem);
                return;
              }
              setState(() {
                _error = null;
                _go(_Step.pay, how: 'continue');
              });
            },
            style: FilledButton.styleFrom(
                backgroundColor: Brand.red,
                padding: const EdgeInsets.symmetric(vertical: 16)),
            child: const Text('Continue'),
          ),
        ),
      ),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading(wide, 2, 'Your details',
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

  Widget _pickedCard(bool wide) => Container(
        padding: EdgeInsets.all(wide ? 18 : 14),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Brand.border),
        ),
        child: Row(children: [
          const Icon(Icons.storefront_outlined, color: Brand.inkMuted),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_spaceName,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: wide ? 16 : 15)),
                  if (_where.isNotEmpty)
                    Text(_where,
                        style: const TextStyle(
                            fontSize: 12.5, color: Brand.inkSecondary)),
                ]),
          ),
          TextButton(onPressed: _back, child: const Text('Change')),
        ]),
      );

  // ---------------------------------------------------------- step three

  /// Step three, laid out like a pricing page: Monthly / Yearly switch
  /// and the currency at the top, then Free and Verified side by side,
  /// each with its price, its button and what it gives. Everything
  /// fits one laptop screen, so the choice is made without scrolling.
  /// Claiming is free; Verified is the optional upgrade (Leonie's
  /// review, 28 Sep: the paid offer alone hid the point of claiming
  /// for free).
  Widget _payStep(bool wide) {
    final p = _pricing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(wide, 3, 'Choose your plan',
            'Claiming $_spaceName is free, and stays free. Verified is an '
                'optional extra, which you can add now or later from your '
                'Owner account.'),
        SizedBox(height: wide ? 18 : 14),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 860 : double.infinity),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (p != null)
                  wide
                      ? Row(children: [
                          PeriodToggle(
                              choice: p,
                              onChanged: (c) => setState(() => _pricing = c)),
                          const Spacer(),
                          CurrencyPicker(
                              choice: p,
                              onChanged: (c) => setState(() => _pricing = c)),
                        ])
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                              PeriodToggle(
                                  choice: p,
                                  onChanged: (c) =>
                                      setState(() => _pricing = c)),
                              const SizedBox(height: 6),
                              CurrencyPicker(
                                  choice: p,
                                  onChanged: (c) =>
                                      setState(() => _pricing = c)),
                            ]),
                SizedBox(height: wide ? 14 : 12),
                _planCards(wide, buttons: true),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(_error!,
                        style: const TextStyle(color: Brand.red, fontSize: 13)),
                  ),
                const SizedBox(height: 12),
                Text(
                    _alreadyPublished
                        ? 'Either way, we first check you are with the team '
                            'at $_spaceName, then the page is yours to manage.'
                        : 'Either way, your space joins our publishing queue '
                            'and we email you when the page is live. We first '
                            'check you are with the team, then it is yours to '
                            'manage.',
                    style: const TextStyle(
                        color: Brand.inkMuted, fontSize: 12.5, height: 1.5)),
              ]),
        ),
      ],
    );
  }

  /// The two buttons on step three, one in each card. The plan chosen
  /// on the cards gets the filled button; the other stays outlined, so
  /// both are always one tap away.
  Widget _planButton({
    required bool filled,
    required VoidCallback? onPressed,
    required String label,
  }) {
    const textStyle = TextStyle(fontSize: 15, fontWeight: FontWeight.w700);
    return filled
        ? FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
                backgroundColor: Brand.red,
                minimumSize: const Size.fromHeight(48)),
            child: Text(label, style: textStyle),
          )
        : OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48)),
            child: Text(label, style: textStyle),
          );
  }

  Widget _freeButton() => _planButton(
        filled: _plan == 'free',
        onPressed: _sending ? null : _claimFree,
        label: _sending ? 'One moment' : 'Claim for free',
      );

  Widget _payButton() => _planButton(
        filled: _plan == 'verified',
        onPressed: _sending ? null : _startAndPay,
        label: _sending ? 'One moment' : 'Go Verified: continue to payment',
      );

  // ------------------------------------------------------- what you get

  /// A step's own content, then both ways to be on Nomadwise below it,
  /// full width, so it is clear from the first screen that claiming is
  /// free and Verified is an optional extra.
  Widget _withPlans(bool wide, Widget main) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 660),
              child: SizedBox(width: double.infinity, child: main)),
        ),
        SizedBox(height: wide ? 28 : 22),
        _plansOverview(wide),
      ]);

  static const _freeGets = [
    'Your page on Nomadwise, built to be found by Google and AI assistants',
    'Correct the facts: hours, prices, WiFi and contact',
    'Your own photos and description',
    'Your Owner account, to keep it all up to date',
  ];
  static const _verifiedAdds = [
    'The green Verified badge on your page and in every list',
    'Always shown above free spaces in your city and area, which counts '
        'for more as more spaces join',
    'A "Send an enquiry" button that emails you directly, no commission',
    'Your event or offer in the advert slot on your page',
  ];

  // ------------------------------------------------------ plan cards

  Widget _pill(String text, {bool on = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: on ? Brand.red : Brand.field,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: .5,
                color: on ? Colors.white : Brand.inkSecondary)),
      );

  /// "€99  a year": the big figure with its unit beside it.
  Widget _priceLine(bool wide, String big, String small) => Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(big,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: wide ? 30 : 26,
                    height: 1,
                    letterSpacing: -0.8)),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(small,
                    style: TextStyle(
                        color: Brand.inkSecondary,
                        fontSize: wide ? 14 : 13.5,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ]);

  /// The round tick in a card's corner: filled on the chosen plan.
  Widget _mark(bool on) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? Brand.red : Colors.transparent,
          border: Border.all(
              color: on ? Brand.red : Brand.border, width: on ? 0 : 1.5),
        ),
        child: on
            ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
            : null,
      );

  /// One plan card. Tapping it selects the plan (red border, tick).
  /// [button] is the plan's own button on step three; the overview on
  /// steps one and two has none.
  Widget _planCard(
    bool wide, {
    required String plan,
    required Widget top,
    required List<Widget> body,
    Widget? button,
  }) {
    final on = _plan == plan;
    return Semantics(
      button: true,
      selected: on,
      label: plan == 'free' ? 'Free plan' : 'Verified plan',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _choosePlan(plan),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: EdgeInsets.all(wide ? 18 : 16),
            decoration: BoxDecoration(
              color: Brand.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: on ? Brand.red : Brand.border, width: on ? 2 : 1),
              boxShadow: on ? Brand.shadowFloating : Brand.shadowResting,
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: top),
                    const SizedBox(width: 10),
                    _mark(on),
                  ]),
                  if (button != null) ...[
                    const SizedBox(height: 14),
                    button,
                  ],
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: Brand.hairline),
                  const SizedBox(height: 12),
                  ...body,
                  if (wide) const Spacer(),
                ]),
          ),
        ),
      ),
    );
  }

  /// Free and Verified side by side (stacked on a phone), Free first.
  /// With [buttons], each card carries its own button (step three);
  /// without, it is the overview under the search box, where the
  /// Verified price is "around a day pass a month" until a space, and
  /// so a country, is known.
  Widget _planCards(bool wide, {required bool buttons}) {
    Widget line(String text, {bool plus = false}) =>
        PlanFeatureRow(text, extra: plus, fontSize: wide ? 13.5 : 13);
    Widget title(String name, {bool verified = false, required Widget pill}) =>
        Row(children: [
          Text(name,
              style: TextStyle(
                  fontWeight: FontWeight.w800, fontSize: wide ? 20 : 19)),
          if (verified) ...[
            const SizedBox(width: 6),
            const Icon(Icons.verified, color: Brand.success, size: 19),
          ],
          const SizedBox(width: 10),
          pill,
        ]);
    Widget sub(String text) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(text,
              style: const TextStyle(fontSize: 13, color: Brand.inkSecondary)),
        );

    // On the overview (no space picked yet) neither card shows a
    // figure: a sentence in the price slot, the same weight on both
    // cards, so nothing reads as a bait or a placeholder. Step three
    // has the real numbers.
    Widget lead(String text) => Text(text,
        style: TextStyle(
            fontSize: wide ? 16 : 15,
            fontWeight: FontWeight.w700,
            height: 1.3));

    final free = _planCard(
      wide,
      plan: 'free',
      top: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        title('Free', pill: _pill('WHERE EVERY SPACE STARTS')),
        const SizedBox(height: 10),
        if (buttons) ...[
          _priceLine(wide, '€0', 'always'),
          sub('No card needed. Nothing to pay, ever.'),
        ] else ...[
          lead('Free, always'),
          sub('No card, nothing to pay, ever. Claim your page and make it '
              'yours.'),
        ],
      ]),
      body: [for (final t in _freeGets) line(t)],
      button: buttons ? _freeButton() : null,
    );

    // The Verified price. On step three it is the chosen period and
    // currency for this space; before that, "around a day pass a
    // month" unless the country is already known.
    final p = _pricing;
    final Widget priceLine;
    final String priceSub;
    if (!buttons) {
      // No figure before a space is picked: the cheapest country's
      // "from €4" reads as a bait to an owner in Lisbon who then sees
      // €10, and "priced for your country" invites the same
      // comparison. The anchor the prices were set by is true
      // everywhere.
      priceLine = lead('About the price of a day pass a month');
      priceSub = 'Monthly or yearly, cancel any time. See your price when '
          'you pick your space.';
    } else if (p != null && p.chosen != null) {
      final yearly = p.period == 'yearly';
      priceLine = _priceLine(wide, formatMoney(p.chosen!, p.currency),
          yearly ? 'a year' : 'a month');
      final perMonth = p.yearly == null
          ? null
          : formatMoney(p.yearly! / 12, p.currency);
      final months = p.monthsFree.round();
      priceSub = yearly
          ? (perMonth == null
              ? 'Billed once a year. Cancel any time.'
              : '$perMonth a month, billed once a year. Cancel any time.')
          : (p.yearly == null
              ? 'Billed monthly. Cancel any time.'
              : 'Billed monthly. Yearly is ${formatMoney(p.yearly!, p.currency)}'
                  '${months >= 1 ? ', $months month${months == 1 ? '' : 's'} free' : ''}.');
    } else {
      // Prices not in Stripe yet: the payment link's price.
      priceLine = _priceLine(wide, '€99', 'a year');
      priceSub = 'Billed once a year. Cancel any time.';
    }

    final verified = _planCard(
      wide,
      plan: 'verified',
      top: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        title('Verified', verified: true, pill: _pill('RECOMMENDED', on: true)),
        const SizedBox(height: 10),
        priceLine,
        sub(priceSub),
      ]),
      body: [
        const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Everything in Free, plus:',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Brand.inkSecondary)),
          ),
        for (final t in _verifiedAdds) line(t, plus: true),
      ],
      button: buttons ? _payButton() : null,
    );

    final cards = wide
        ? IntrinsicHeight(
            child:
                Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: free),
              const SizedBox(width: 16),
              Expanded(child: verified),
            ]),
          )
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_plan == 'verified' && buttons) ...[
              verified,
              const SizedBox(height: 12),
              free,
            ] else ...[
              free,
              const SizedBox(height: 12),
              verified,
            ],
          ]);
    return cards;
  }

  /// The overview under the search box on steps one and two.
  Widget _plansOverview(bool wide) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Text('Two ways to be on Nomadwise',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: wide ? 20 : 18,
                    letterSpacing: -0.3)),
          ),
          Text('Tap one to choose',
              style: TextStyle(
                  fontSize: wide ? 13 : 12.5, color: Brand.inkMuted)),
        ]),
        SizedBox(height: wide ? 14 : 12),
        _planCards(wide, buttons: false),
        const SizedBox(height: 10),
        const Text(
            'Claiming is free and needs no card. Verified can be added when '
            'you claim or any time later from your Owner account, monthly or '
            'yearly, cancel any time.',
            style: TextStyle(
                fontSize: 12.5, height: 1.5, color: Brand.inkMuted)),
      ]);

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
            'team at $spaceName, then Verified goes on and we email you'
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
