import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../services/analytics_service.dart';
import '../services/places_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';

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
class ClaimScreen extends StatefulWidget {
  /// A name to search for straight away, from ?claim=<name>.
  final String? seed;
  const ClaimScreen({super.key, this.seed});
  @override
  State<ClaimScreen> createState() => _ClaimScreenState();
}

enum _Step { find, addSpace, about, pay }

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
  final _ownerRole = TextEditingController();
  final _ownerEmail = TextEditingController();
  final _ownerPhone = TextEditingController();
  final _enquiryEmail = TextEditingController();
  final _note = TextEditingController();
  // Honeypot: never shown, so anything in it is a bot.
  final _website = TextEditingController();

  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final seed = (widget.seed ?? '').trim();
    if (seed.isNotEmpty) {
      _search.text = seed;
      _runSearch(seed);
    }
    Analytics.capture('claim_opened', {'seed': seed});
  }

  @override
  void dispose() {
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
      _website,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _spaceName => _picked != null
      ? '${_picked!['name']}'
      : (_pickedPlace?.main ?? '').trim();

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
    setState(() {
      _hits = rows;
      _searching = false;
      _searched = true;
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
      _newCountry = _countryFrom(addr);
      _newLat = d?.lat;
      _newLng = d?.lng;
      _newType = (d?.primaryType == 'coworking_space' ||
              s.main.toLowerCase().contains('cowork'))
          ? 'coworking'
          : (d?.primaryType?.contains('cafe') ?? false)
              ? 'cafe'
              : _newType;
      _placeBusy = false;
      _step = _Step.about;
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
    final name = _ownerName.text.trim();
    final email = _ownerEmail.text.trim().toLowerCase();
    if (name.length < 2 || !email.contains('@') || email.length < 5) {
      setState(() => _error = 'Your name and a working email are needed.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final res = await _supabase.startClaim({
        if (_picked != null) 'venue_id': _picked!['id'],
        'owner_name': name,
        'owner_email': email,
        'owner_role': _ownerRole.text.trim(),
        'owner_phone': _ownerPhone.text.trim(),
        'enquiry_email': _enquiryEmail.text.trim(),
        'note': _note.text.trim(),
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
      });
      final claimId = '${res?['claim_id'] ?? ''}';
      if (claimId.isEmpty) throw Exception('no claim id');
      Analytics.capture('claim_to_payment', {
        'space': _spaceName,
        'new_space': _picked == null,
      });
      final url = Uri.parse('${AppConfig.stripeVerifiedLink}'
          '?client_reference_id=$claimId'
          '&prefilled_email=${Uri.encodeQueryComponent(email)}');
      await launchUrl(url,
          mode: LaunchMode.platformDefault, webOnlyWindowName: '_self');
    } catch (e) {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(
        title: const Text('Claim your space'),
        leading: _step == _Step.find
            ? IconButton(
                tooltip: 'nomadwise.io',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => launchUrl(
                    Uri.parse('https://www.nomadwise.io'),
                    mode: LaunchMode.platformDefault))
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _back),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: switch (_step) {
            _Step.find => _findStep(),
            _Step.addSpace => _addStep(),
            _Step.about => _aboutStep(),
            _Step.pay => _payStep(),
          },
        ),
      ),
    );
  }

  void _back() {
    setState(() {
      _error = null;
      _step = switch (_step) {
        _Step.pay => _Step.about,
        _Step.about => _picked != null ? _Step.find : _Step.addSpace,
        _Step.addSpace => _Step.find,
        _Step.find => _Step.find,
      };
    });
  }

  Widget _stepLine(int n) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text('Step $n of 3',
            style: const TextStyle(
                color: Brand.inkMuted,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4)),
      );

  // ------------------------------------------------------------ step one

  Widget _findStep() => ListView(padding: const EdgeInsets.all(18), children: [
        _stepLine(1),
        const Text('Find your space',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        const SizedBox(height: 6),
        const Text(
            'Nomadwise already lists thousands of coworking spaces and '
            'laptop-friendly cafes. Search for yours below.',
            style: TextStyle(
                color: Brand.inkSecondary, fontSize: 13.5, height: 1.5)),
        const SizedBox(height: 16),
        TextField(
          controller: _search,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          onChanged: _scheduleSearch,
          decoration: InputDecoration(
            labelText: 'Name of your space',
            hintText: 'e.g. Tribal Bali',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _searching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Brand.inkMuted)))
                : null,
          ),
        ),
        const SizedBox(height: 12),
        ..._hits.map(_hitTile),
        if (_searched && _hits.isEmpty && !_searching)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('Nothing under that name yet.',
                style: TextStyle(color: Brand.inkMuted, fontSize: 13)),
          ),
        const SizedBox(height: 8),
        const Divider(color: Brand.hairline),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => setState(() {
            _step = _Step.addSpace;
            _picked = null;
            _placeSearch.text = _search.text;
            if (_search.text.trim().length >= 2) {
              _schedulePlaces(_search.text);
            }
          }),
          icon: const Icon(Icons.add_location_alt_outlined, size: 18),
          label: const Text("My space isn't here — add it"),
          style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14)),
        ),
        const SizedBox(height: 28),
        _valueBlock(compact: true),
        const SizedBox(height: 40),
      ]);

  Widget _hitTile(Map<String, dynamic> h) {
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
        title: Text('${h['name']}',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
        subtitle: Text(
            verified
                ? '$where · already Verified'
                : onSite
                    ? '$where · has a page on nomadwise.io'
                    : '$where · not published yet',
            style: const TextStyle(fontSize: 12, color: Brand.inkSecondary)),
        trailing: verified
            ? const Icon(Icons.verified, size: 20, color: Brand.success)
            : const Icon(Icons.chevron_right, color: Brand.inkMuted),
        onTap: verified
            ? () => _alreadyVerified('${h['name']}')
            : () => setState(() {
                  _picked = h;
                  _pickedPlace = null;
                  _step = _Step.about;
                }),
      ),
    );
  }

  void _alreadyVerified(String name) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$name is already Verified'),
        content: const Text(
            'Someone has already claimed this listing. If that was not you, '
            'email hello@nomadwise.io and we will look into it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.red),
            onPressed: () {
              Navigator.pop(ctx);
              launchUrl(Uri.parse(
                  'mailto:hello@nomadwise.io?subject=${Uri.encodeComponent('About the listing for $name')}'));
            },
            child: const Text('Email us'),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------- step one (add it)

  Widget _addStep() => ListView(padding: const EdgeInsets.all(18), children: [
        _stepLine(1),
        const Text('Add your space',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        const SizedBox(height: 6),
        const Text(
            'Search for your business as it appears on Google Maps. That '
            'gives us the right address, opening hours and photos from the '
            'start, so your page is ready the same day.',
            style: TextStyle(
                color: Brand.inkSecondary, fontSize: 13.5, height: 1.5)),
        const SizedBox(height: 16),
        TextField(
          controller: _placeSearch,
          autofocus: true,
          onChanged: _schedulePlaces,
          decoration: InputDecoration(
            labelText: 'Your business on Google',
            hintText: 'e.g. Tribal Bali, Pererenan',
            prefixIcon: const Icon(Icons.place_outlined, size: 20),
            suffixIcon: _placeBusy
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Brand.inkMuted)))
                : null,
          ),
        ),
        const SizedBox(height: 12),
        ..._suggestions.map((s) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Brand.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Brand.border),
              ),
              child: ListTile(
                title: Text(s.main,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14.5)),
                subtitle: Text(s.secondary,
                    style: const TextStyle(
                        fontSize: 12, color: Brand.inkSecondary)),
                trailing:
                    const Icon(Icons.chevron_right, color: Brand.inkMuted),
                onTap: () => _choosePlace(s),
              ),
            )),
        const SizedBox(height: 20),
        const Text(
            'Not on Google Maps? Email hello@nomadwise.io and we will add '
            'you by hand.',
            style: TextStyle(color: Brand.inkMuted, fontSize: 12, height: 1.5)),
        const SizedBox(height: 40),
      ]);

  // ------------------------------------------------------------ step two

  Widget _aboutStep() {
    final where = _picked != null
        ? [_picked!['neighbourhood'], _picked!['city'], _picked!['country']]
            .where((x) => x != null && '$x'.isNotEmpty)
            .join(', ')
        : (_newAddress ?? '');
    return ListView(padding: const EdgeInsets.all(18), children: [
      _stepLine(2),
      const Text('About you',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Brand.border),
        ),
        child: Row(children: [
          const Icon(Icons.storefront_outlined, color: Brand.inkMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_spaceName,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15)),
                  if (where.isNotEmpty)
                    Text(where,
                        style: const TextStyle(
                            fontSize: 12, color: Brand.inkSecondary)),
                ]),
          ),
          TextButton(onPressed: _back, child: const Text('Change')),
        ]),
      ),
      if (_picked == null) ...[
        const SizedBox(height: 14),
        const Text('What kind of place is it?',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'coworking', label: Text('Coworking')),
            ButtonSegment(value: 'cafe', label: Text('Cafe')),
          ],
          selected: {_newType},
          onSelectionChanged: (s) => setState(() => _newType = s.first),
        ),
      ],
      const SizedBox(height: 18),
      TextField(
          controller: _ownerName,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Your name')),
      const SizedBox(height: 12),
      TextField(
          controller: _ownerRole,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
              labelText: 'Your role (optional)',
              hintText: 'Owner, manager, community lead')),
      const SizedBox(height: 12),
      TextField(
          controller: _ownerEmail,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
              labelText: 'Your email',
              helperText: 'Receipts and anything we need to ask you.')),
      const SizedBox(height: 12),
      TextField(
          controller: _ownerPhone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
              labelText: 'Phone or WhatsApp (optional)')),
      const SizedBox(height: 12),
      TextField(
          controller: _enquiryEmail,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
              labelText: 'Where should booking requests go? (optional)',
              helperText: 'Leave blank to use your own email.')),
      const SizedBox(height: 12),
      TextField(
          controller: _note,
          minLines: 2,
          maxLines: 6,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
              labelText: 'Anything we should know? (optional)',
              hintText: 'Day pass price, opening hours, a correction...',
              alignLabelWithHint: true)),
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
      FilledButton(
        onPressed: () {
          final name = _ownerName.text.trim();
          final email = _ownerEmail.text.trim();
          if (name.length < 2 || !email.contains('@')) {
            setState(() => _error = 'Your name and a working email are needed.');
            return;
          }
          setState(() {
            _error = null;
            _step = _Step.pay;
          });
        },
        style: FilledButton.styleFrom(
            backgroundColor: Brand.red,
            padding: const EdgeInsets.symmetric(vertical: 16)),
        child: const Text('Continue'),
      ),
      const SizedBox(height: 40),
    ]);
  }

  // ---------------------------------------------------------- step three

  Widget _payStep() => ListView(padding: const EdgeInsets.all(18), children: [
        _stepLine(3),
        const Text('Your Verified listing',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
        const SizedBox(height: 6),
        Text('for $_spaceName',
            style: const TextStyle(
                color: Brand.inkSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        _valueBlock(),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Brand.successTint,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            const Icon(Icons.bolt, color: Brand.success),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                  _picked != null && _picked!['on_site'] == true
                      ? 'Your page is already live. The badge and your details '
                          'go on today.'
                      : 'We review every paid listing the same day it arrives. '
                          'Your page is usually live within a few hours.',
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.45, color: Brand.ink)),
            ),
          ]),
        ),
        const SizedBox(height: 18),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: const [
          Text('€99',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 30)),
          SizedBox(width: 6),
          Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('per year',
                style: TextStyle(color: Brand.inkSecondary, fontSize: 14)),
          ),
        ]),
        const SizedBox(height: 4),
        const Text('Renews once a year. Cancel any time and it runs to the '
            'end of the 12 months.',
            style: TextStyle(color: Brand.inkMuted, fontSize: 12, height: 1.4)),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!,
                style: const TextStyle(color: Brand.red, fontSize: 13)),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _sending ? null : _startAndPay,
          style: FilledButton.styleFrom(
              backgroundColor: Brand.red,
              padding: const EdgeInsets.symmetric(vertical: 16)),
          icon: const Icon(Icons.lock_outline, size: 18),
          label: Text(_sending ? 'One moment' : 'Continue to payment'),
        ),
        const SizedBox(height: 10),
        const Text('Payment is handled by Stripe. We never see your card.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Brand.inkMuted, fontSize: 11.5)),
        const SizedBox(height: 40),
      ]);

  Widget _valueBlock({bool compact = false}) {
    const rows = [
      (Icons.verified, 'The Verified badge',
          'A green badge on your page and in every list you appear in.'),
      (Icons.arrow_upward, 'First position in your city',
          'Verified spaces sit above the free listings on their city and '
              'area pages.'),
      (Icons.mark_email_read_outlined, 'Booking requests to your inbox',
          'A request button on your page that emails you directly. '
              'No commission, no middleman.'),
      (Icons.photo_library_outlined, 'Your own photos and words',
          'Your description, your prices, your pictures, instead of '
              'whatever Google shows.'),
      (Icons.travel_explore, 'Found by Google and by AI',
          'Your page is written to be quoted by ChatGPT, Claude and '
              'Perplexity when someone asks where to work.'),
      (Icons.insights_outlined, 'A report every quarter',
          'How many people saw your page, where they came from, how many '
              'asked to book.'),
    ];
    final show = compact ? rows.take(3) : rows;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (compact) ...[
          const Text('What a Verified listing gets you',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
          const SizedBox(height: 12),
        ],
        ...show.map((r) => Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(r.$1, size: 18, color: Brand.red),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(r.$2,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13.5)),
                            const SizedBox(height: 2),
                            Text(r.$3,
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    height: 1.4,
                                    color: Brand.inkSecondary)),
                          ]),
                    ),
                  ]),
            )),
        if (compact)
          const Text('€99 a year.',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
      ]),
    );
  }
}

/// Where Stripe sends the owner back to after paying: a plain thank you
/// that says what happens next, so nobody is left on Stripe's own page
/// wondering whether anything reached us.
class ClaimedScreen extends StatelessWidget {
  const ClaimedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                width: 76,
                height: 76,
                decoration: const BoxDecoration(
                    color: Brand.successTint, shape: BoxShape.circle),
                child: const Icon(Icons.verified,
                    size: 36, color: Brand.success),
              ),
              const SizedBox(height: 18),
              const Text('You are Verified',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
              const SizedBox(height: 10),
              const Text(
                  'Thank you. Your payment reached us and your listing is '
                  'being set up now.\n\n'
                  'We check every paid listing the same day, so your page is '
                  'usually live within a few hours. You will get an email '
                  'when it is, with a private link for adding your photos, '
                  'your description and your prices.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Brand.inkSecondary, height: 1.6, fontSize: 14)),
              const SizedBox(height: 22),
              OutlinedButton.icon(
                  onPressed: () => launchUrl(
                      Uri.parse('https://www.nomadwise.io'),
                      mode: LaunchMode.platformDefault),
                  icon: const Icon(Icons.arrow_back, size: 16),
                  label: const Text('Back to nomadwise.io')),
              const SizedBox(height: 12),
              const Text('Questions? hello@nomadwise.io',
                  style: TextStyle(color: Brand.inkMuted, fontSize: 12)),
            ]),
          ),
        ),
      ),
    );
  }
}
