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
///
/// Owners read this on a laptop at their desk as often as on a phone,
/// so every step lays out in two columns above [_wideAt] and stacks
/// below it.
class ClaimScreen extends StatefulWidget {
  /// A name to search for straight away, from ?claim=<name>.
  final String? seed;
  const ClaimScreen({super.key, this.seed});
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
      _step = switch (_step) {
        _Step.pay => _Step.about,
        _Step.about => _picked != null ? _Step.find : _Step.addSpace,
        _Step.addSpace => _Step.find,
        _Step.find => _Step.find,
      };
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

  /// Two columns above the breakpoint, stacked below, with the side
  /// column dropping underneath the main one on a phone.
  Widget _split(bool wide,
      {required Widget main, required Widget side, int mainFlex = 3}) {
    if (!wide) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        main,
        const SizedBox(height: 28),
        side,
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(flex: mainFlex, child: main),
      const SizedBox(width: 44),
      Expanded(flex: 2, child: side),
    ]);
  }

  InputDecoration _field(String label,
          {String? hint, String? helper, Widget? prefix, Widget? suffix}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
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

  Widget _findStep(bool wide) => _split(
        wide,
        main: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                _step = _Step.addSpace;
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
        side: _valueBlock(wide, compact: true),
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

  Widget _addStep(bool wide) => _split(
        wide,
        main: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
        side: _valueBlock(wide, compact: true),
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
      _pair(
        wide,
        TextField(
            controller: _ownerName,
            textCapitalization: TextCapitalization.words,
            decoration: _field('Your name')),
        TextField(
            controller: _ownerRole,
            textCapitalization: TextCapitalization.sentences,
            decoration: _field('Your role (optional)',
                hint: 'Owner, manager, community lead')),
      ),
      const SizedBox(height: 16),
      _pair(
        wide,
        TextField(
            controller: _ownerEmail,
            keyboardType: TextInputType.emailAddress,
            decoration: _field('Your email',
                helper: 'Receipts and anything we need to ask you.')),
        TextField(
            controller: _ownerPhone,
            keyboardType: TextInputType.phone,
            decoration: _field('Phone or WhatsApp (optional)')),
      ),
      const SizedBox(height: 16),
      TextField(
          controller: _enquiryEmail,
          keyboardType: TextInputType.emailAddress,
          decoration: _field('Where should booking requests go? (optional)',
              helper: "Leave blank and we'll send them to the email above.")),
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
              final name = _ownerName.text.trim();
              final email = _ownerEmail.text.trim();
              if (name.length < 2 || !email.contains('@')) {
                setState(() =>
                    _error = 'Your name and a working email are needed.');
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
        ),
      ),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading(wide, 2, 'About you',
          'So we know who to reply to, and where booking requests from your '
              'page should land.'),
      SizedBox(height: wide ? 26 : 18),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: wide ? 760 : double.infinity),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: fields),
      ),
    ]);
  }

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

  Widget _payStep(bool wide) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading(wide, 3, 'Your Verified listing', ''),
          const SizedBox(height: 6),
          Text('for $_spaceName',
              style: TextStyle(
                  color: Brand.inkSecondary,
                  fontSize: wide ? 16 : 14,
                  fontWeight: FontWeight.w600)),
          SizedBox(height: wide ? 28 : 18),
          _split(
            wide,
            main: _valueBlock(wide),
            side: _checkoutCard(wide),
          ),
        ],
      );

  Widget _checkoutCard(bool wide) => Container(
        padding: EdgeInsets.all(wide ? 24 : 18),
        decoration: BoxDecoration(
          color: Brand.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Brand.border),
          boxShadow: wide ? Brand.shadowResting : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('€99',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: wide ? 40 : 32,
                    height: 1,
                    letterSpacing: -1)),
            const SizedBox(width: 8),
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('per year',
                  style: TextStyle(color: Brand.inkSecondary, fontSize: 14)),
            ),
          ]),
          const SizedBox(height: 8),
          const Text(
              'Renews once a year. Cancel any time and it runs to the end of '
              'the 12 months.',
              style:
                  TextStyle(color: Brand.inkMuted, fontSize: 12.5, height: 1.45)),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Brand.successTint,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.bolt, color: Brand.success, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    _alreadyPublished
                        ? 'Your page is already live. The badge and your '
                            'details are added to it automatically.'
                        : 'Your listing joins our publishing queue. We will '
                            'email you as soon as your page is live.',
                    style: const TextStyle(
                        fontSize: 12.5, height: 1.45, color: Brand.ink)),
              ),
            ]),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(_error!,
                  style: const TextStyle(color: Brand.red, fontSize: 13)),
            ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _sending ? null : _startAndPay,
            style: FilledButton.styleFrom(
                backgroundColor: Brand.red,
                minimumSize: const Size.fromHeight(52)),
            icon: const Icon(Icons.lock_outline, size: 18),
            label: Text(_sending ? 'One moment' : 'Continue to payment',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 12),
          const Text('Payment is handled by Stripe. We never see your card.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Brand.inkMuted, fontSize: 11.5)),
        ]),
      );

  // ------------------------------------------------------- what you get

  Widget _valueBlock(bool wide, {bool compact = false}) {
    // The badge is green wherever it appears, so its own line is drawn
    // green here too; the rest carry the house red.
    const rows = [
      (Icons.verified, Brand.success, 'The Verified badge',
          'A green badge on your page and in every list you appear in.'),
      (Icons.arrow_upward, Brand.red, 'Above every free listing',
          'Verified spaces are listed ahead of every unpaid space on their '
              'city and area pages.'),
      (Icons.mark_email_read_outlined, Brand.red,
          'Booking requests to your inbox',
          'A request button on your page that emails you directly. '
              'No commission, no middleman.'),
      (Icons.photo_library_outlined, Brand.red, 'Your own photos and words',
          'Your description, your prices, your pictures, instead of '
              'whatever Google shows.'),
      (Icons.travel_explore, Brand.red, 'Found by Google and by AI',
          'Your page is built so Google, ChatGPT and Perplexity can find '
              'it and quote it when someone asks where to work.'),
      (Icons.insights_outlined, Brand.red, 'A report every quarter',
          'How many people saw your page, where they came from, how many '
              'asked to book.'),
    ];
    final show = compact ? rows.take(3).toList() : rows;
    return Container(
      padding: EdgeInsets.all(wide ? 24 : 18),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Brand.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (compact) ...[
          const Text('What a Verified listing gets you',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 16),
        ],
        ...show.map((r) => Padding(
              padding: EdgeInsets.only(bottom: wide ? 18 : 14),
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: r.$2 == Brand.success
                            ? Brand.successTint
                            : Brand.accentTint,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(r.$1, size: 17, color: r.$2),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(r.$3,
                                style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: wide ? 15 : 13.5)),
                            const SizedBox(height: 3),
                            Text(r.$4,
                                style: TextStyle(
                                    fontSize: wide ? 13.5 : 12.5,
                                    height: 1.5,
                                    color: Brand.inkSecondary)),
                          ]),
                    ),
                  ]),
            )),
        if (compact) ...[
          const Divider(height: 1, color: Brand.border),
          SizedBox(height: wide ? 18 : 14),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('€99',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: wide ? 34 : 28,
                    height: 1,
                    letterSpacing: -1)),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text('a year',
                  style: TextStyle(
                      color: Brand.inkSecondary,
                      fontSize: wide ? 15 : 14,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 6),
          Text('Billed once a year. Cancel any time.',
              style: TextStyle(
                  fontSize: wide ? 13.5 : 12.5,
                  height: 1.45,
                  color: Brand.inkSecondary)),
        ],
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
                  child: Icon(Icons.verified,
                      size: wide ? 42 : 36, color: Brand.success),
                ),
                SizedBox(height: wide ? 24 : 18),
                Text('You are Verified',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: wide ? 30 : 23,
                        letterSpacing: -0.5)),
                const SizedBox(height: 12),
                Text(
                    'Thank you. Your payment reached us and your listing is '
                    'in the queue.\n\n'
                    'We will email you as soon as your page is live, with a '
                    'private link for adding your photos, your description '
                    'and your prices.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Brand.inkSecondary,
                        height: 1.65,
                        fontSize: wide ? 15 : 14)),
                SizedBox(height: wide ? 28 : 22),
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
