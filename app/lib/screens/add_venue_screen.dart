import 'dart:async';
import 'dart:typed_data';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputFormatter, TextEditingValue;
import 'package:image_picker/image_picker.dart';

import '../config.dart';
import '../models/discovered_place.dart';
import '../models/venue.dart';
import '../services/analytics_service.dart';
import '../services/location_service.dart';
import '../services/places_service.dart';
import '../services/speed_test_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';

/// One form, two jobs:
///  • confirming == null  -> "Add a new venue"     (100 coins)
///  • confirming != null  -> "Confirm / update it" (30 coins)
///
/// Requires a photo and captures GPS so the submission can be verified
/// (photo + you-were-actually-there check) before coins unlock.
class AddVenueScreen extends StatefulWidget {
  final Venue? confirming;

  /// Set when the user tapped an unscreened (Google-discovered) pin —
  /// the place identity is prefilled and locked.
  final DiscoveredPlace? screening;
  final double? userLat, userLng;
  const AddVenueScreen(
      {super.key,
      this.confirming,
      this.screening,
      this.userLat,
      this.userLng});

  @override
  State<AddVenueScreen> createState() => _AddVenueScreenState();
}

class _AddVenueScreenState extends State<AddVenueScreen> {
  final _supabase = SupabaseService();
  final _places = PlacesService();
  final _formKey = GlobalKey<FormState>();

  final _name = TextEditingController();
  final _neighbourhood = TextEditingController();
  final _wifi = TextEditingController();
  final _wifiSsid = TextEditingController();
  final _wifiPass = TextEditingController();
  String _type = 'cafe';

  /// The typed wifi speed, cleaned up: comma accepted as the decimal
  /// separator, rounded to one decimal place.
  num? _typedMbps() {
    final t = _wifi.text.trim().replaceAll(',', '.');
    final v = num.tryParse(t);
    if (v == null) return null;
    return double.parse(v.toDouble().toStringAsFixed(1));
  }

  /// Keeps the wifi field to numbers with at most one decimal place.
  static final _mbpsFormatter =
      TextInputFormatter.withFunction((oldValue, newValue) {
    final t = newValue.text;
    if (t.isEmpty) return newValue;
    return RegExp(r'^\d{0,4}([.,]\d?)?$').hasMatch(t)
        ? newValue
        : oldValue;
  });

  // WiFi speed measured live in this form (counts as a real wifi test).
  num? _measuredMbps;
  String? _measuredNetHash;
  String _measuredConnType = 'unknown';
  bool _testingWifi = false;
  String _testPhase = '';

  // New venues must be picked from Google so they're real places.
  String? _placeId;
  double? _placeLat, _placeLng;
  String? _placeCity;
  List<PlaceSuggestion> _suggestions = [];
  Timer? _debounce;
  Venue? _existing; // set when the picked place is already on the map

  // tri-state features: null = don't know
  final Map<String, bool?> _features = {
    'laptops_allowed': null,
    'power_outlets': null,
    'aircon': null,
    'comfortable_seating': null,
    'cozy': null,
    'quiet_space': null,
    // coworking-only questions (shown when type == coworking)
    'good_for_calls': null,
    'call_room': null,
    'monitor': null,
    'office_chairs': null,
    'access_24h': null,
  };

  Uint8List? _photo;
  bool _saving = false;
  int? _coinBalance; // shown in the header

  Future<void> _loadBalance() async {
    if (!_supabase.signedIn) return;
    final w = await _supabase.wallet();
    if (mounted) setState(() => _coinBalance = w.total);
  }

  /// Google's photos of the place, shown so the reviewer can see what
  /// they're assessing.
  List<String> _refPhotos = [];
  num? _refRating;

  Future<void> _loadReference(String placeId) async {
    final live = await _places.details(placeId);
    if (mounted && live != null) {
      setState(() {
        _refPhotos = live.photoNames
            .take(6)
            .map((n) => PlacesService.photoUrl(n, maxWidth: 500))
            .toList();
        _refRating = live.rating;
        _placeCity ??= live.city;
      });
    }
  }

  bool get isConfirm => _confirmTarget != null;
  Venue? get _confirmTarget => widget.confirming ?? _existing;

  String? _knownSsid;
  String? _knownPass;
  bool _ssidIsGuess = false;

  /// Pre-fill the wifi name with our best guess from the space's
  /// name (marked clearly as a guess, freely editable).
  void _prefillSsidGuess() {
    if (_wifiSsid.text.trim().isNotEmpty) return;
    if ((_knownSsid ?? '').isNotEmpty) return;
    final guesses = _ssidGuesses();
    if (guesses.isEmpty) return;
    final name = _name.text.trim();
    _wifiSsid.text = name.length <= 14 ? name : guesses.first;
    _ssidIsGuess = true;
  }

  /// Cafes usually name their wifi after themselves. Offer tappable
  /// guesses built from the space's name; the field stays editable so
  /// a near-miss is fixed in a keystroke or two.
  List<String> _ssidGuesses() {
    final name = _name.text.trim();
    if (name.length < 3) return [];
    final words =
        name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final first = words.first;
    final guesses = <String>{};
    if (first.length >= 3) {
      guesses.add(first);
      guesses.add('$first Guest');
    }
    if (words.length >= 2) guesses.add(words.take(2).join());
    guesses.add(name);
    final current = _wifiSsid.text.trim().toLowerCase();
    return guesses
        .where((s) => s.length >= 3 && s.toLowerCase() != current)
        .take(4)
        .toList();
  }

  /// The wifi login a previous nomad recorded for this venue, offered
  /// as a one-tap fill (browsers cannot list nearby networks).
  Future<void> _loadKnownWifi([Venue? venue]) async {
    final v = venue ?? widget.confirming;
    if (v == null) return;
    final w = await _supabase.venueWifi(v.id);
    if (mounted && w != null) {
      setState(() {
        _knownSsid = (w['ssid'] as String?)?.trim();
        _knownPass = (w['password'] as String?)?.trim();
        // A recorded name beats our guess.
        if (_ssidIsGuess && (_knownSsid ?? '').isNotEmpty) {
          _wifiSsid.text = _knownSsid!;
          _ssidIsGuess = false;
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _loadBalance();
    _prefillFrom(widget.confirming);
    _loadKnownWifi();
    final s = widget.screening;
    if (s != null) {
      _name.text = s.name;
      _placeId = s.placeId;
      _placeLat = s.lat;
      _placeLng = s.lng;
      if (s.primaryType == 'coworking_space') _type = 'coworking';
      _loadReference(s.placeId);
    } else if (widget.confirming?.googlePlaceId != null) {
      _loadReference(widget.confirming!.googlePlaceId!);
    }
    _prefillSsidGuess();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _prefillFrom(Venue? v) {
    if (v != null) {
      _name.text = v.name;
      _neighbourhood.text = v.neighbourhood ?? '';
      _type = v.type;
      if (v.wifiSpeedMbps != null) _wifi.text = v.wifiSpeedLabel ?? '';
      _features['laptops_allowed'] = v.laptopsAllowed;
      _features['power_outlets'] = v.powerOutlets;
      _features['aircon'] = v.aircon;
      _features['comfortable_seating'] = v.comfortableSeating;
      _features['cozy'] = v.cozy;
      _features['quiet_space'] = v.quietSpace;
      _features['good_for_calls'] = v.goodForCalls;
      _features['call_room'] = v.callRoom;
      _features['monitor'] = v.monitorAvailable;
      _features['office_chairs'] = v.officeChairs;
      _features['access_24h'] = v.access24h;
    }
  }

  void _onNameChanged(String text) {
    if (isConfirm) return;
    _placeId = null;
    _placeLat = null;
    _placeLng = null;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final res = await _places.autocomplete(text,
          nearLat: widget.userLat, nearLng: widget.userLng);
      if (mounted) setState(() => _suggestions = res);
    });
  }

  Future<void> _pickSuggestion(PlaceSuggestion s) async {
    setState(() {
      _suggestions = [];
      _name.text = s.main;
    });
    // Is this place already on the map? Then confirm it instead (no dupes).
    final existing = await _supabase.venueByPlaceId(s.placeId);
    if (existing != null) {
      if (!mounted) return;
      setState(() {
        _existing = existing;
        _prefillFrom(existing);
      });
      _loadKnownWifi(existing);
      showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                title: const Text('Already on the map!'),
                content: Text(
                    '${existing.name} is already listed, so you\'re now '
                    'confirming it instead, still worth '
                    '${AppConfig.coinsConfirmVenue} coins.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Got it'))
                ],
              ));
      return;
    }
    final live = await _places.details(s.placeId);
    if (!mounted) return;
    setState(() {
      _placeId = s.placeId;
      _placeLat = live?.lat;
      _placeLng = live?.lng;
      _placeCity = live?.city;
      if (live?.displayName != null) _name.text = live!.displayName!;
      if (live != null) {
        _refPhotos = live.photoNames
            .take(6)
            .map((n) => PlacesService.photoUrl(n, maxWidth: 500))
            .toList();
        _refRating = live.rating;
      }
      _prefillSsidGuess();
    });
  }

  Future<void> _pickPhoto() async {
    final picker = ImagePicker();
    final img = await picker.pickImage(
        source: ImageSource.camera, maxWidth: 1600, imageQuality: 82);
    // Camera unavailable (e.g. web preview on a laptop) -> gallery fallback.
    final chosen = img ??
        await picker.pickImage(
            source: ImageSource.gallery, maxWidth: 1600, imageQuality: 82);
    if (chosen != null) {
      final bytes = await chosen.readAsBytes();
      setState(() => _photo = bytes);
    }
  }

  /// Measure the WiFi for real, right inside the form.
  /// Same protections as on the space page: mobile data is blocked when
  /// the browser can detect it, and there's an honesty check either way.
  Future<void> _testWifiHere() async {
    // What connection is the phone on? (Not all platforms can tell:
    // Android Chrome usually can, iPhone Safari can't.)
    String connType = 'unknown';
    try {
      final results = await Connectivity().checkConnectivity();
      if (results.contains(ConnectivityResult.mobile)) {
        connType = 'cellular';
      } else if (results.contains(ConnectivityResult.wifi)) {
        connType = 'wifi';
      }
    } catch (_) {}
    if (!mounted) return;

    if (connType == 'cellular') {
      _snack('You\'re on mobile data. Connect to the space\'s WiFi '
          'first, then test.');
      return;
    }

    // Honesty gate (and a data-cost warning) before anything downloads.
    final ready = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: const Text('On the space\'s WiFi?'),
              content: const Text(
                  'Make sure you\'re connected to this space\'s WiFi, not '
                  'mobile data. Tests on mobile data don\'t count and this '
                  'uses about 12 MB.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('I\'m on the WiFi')),
              ],
            ));
    if (ready != true || !mounted) return;

    setState(() {
      _testingWifi = true;
      _testPhase = 'Starting…';
    });
    final mbps = await SpeedTestService.measureMbps(
        onPhase: (p) => mounted ? setState(() => _testPhase = p) : null);
    if (!mounted) return;
    setState(() => _testingWifi = false);
    if (mbps == null) {
      _snack('Could not measure. Check the connection and retry.');
      return;
    }
    Analytics.capture('wifi_test_measured',
        {'in_form': true, 'mbps': mbps, 'connection': connType});
    // Fingerprint the network while they're still on it.
    final netHash = await _supabase.networkFingerprint();
    if (!mounted) return;
    setState(() {
      _measuredMbps = mbps;
      _measuredNetHash = netHash;
      _measuredConnType = connType;
      _wifi.text = mbps.toString();
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_features['laptops_allowed'] == null) {
      _snack('Please answer the key question: are laptops allowed?');
      return;
    }
    if (!isConfirm && _placeId == null) {
      _snack('Please pick the space from the search suggestions.');
      return;
    }
    setState(() => _saving = true);
    try {
      // GPS check: where is the user right now?
      final pos = await LocationService.current();
      if (pos == null) {
        _snack('Please allow location access to submit your update.');
        setState(() => _saving = false);
        return;
      }
      double? distance;
      final v = _confirmTarget;
      if (v?.lat != null && v?.lng != null) {
        distance = Venue.haversineM(
            pos.latitude, pos.longitude, v!.lat!, v.lng!);
      } else if (_placeLat != null && _placeLng != null) {
        distance = Venue.haversineM(
            pos.latitude, pos.longitude, _placeLat!, _placeLng!);
      }

      final payload = {
        'name': _name.text.trim(),
        'type': _type,
        'neighbourhood': _neighbourhood.text.trim(),
        if (_wifi.text.trim().isNotEmpty)
          'wifi_speed_mbps': _typedMbps(),
        ..._features,
      };

      String? venueId = _confirmTarget?.id;
      if (!isConfirm) {
        venueId = await _supabase.addPendingVenue({
          'name': _name.text.trim(),
          'type': _type,
          'neighbourhood': _neighbourhood.text.trim(),
          'google_place_id': _placeId,
          'city': _placeCity,
          // Venue pin sits where Google says the place is.
          'lat': _placeLat ?? pos.latitude,
          'lng': _placeLng ?? pos.longitude,
          if (_wifi.text.trim().isNotEmpty)
            'wifi_speed_mbps': _typedMbps(),
          ..._features,
        });
      }

      await _supabase.submit(
        kind: isConfirm ? 'confirm' : 'new_venue',
        venueId: venueId,
        payload: payload,
        photoBytes: _photo,
        gpsLat: pos.latitude,
        gpsLng: pos.longitude,
        gpsDistanceM: distance,
      );

      // Bonus 1: a real measured WiFi test rides along (+100).
      final measuredNow = _measuredMbps != null &&
          _wifi.text.trim() == _measuredMbps.toString();
      if (measuredNow && venueId != null) {
        await _supabase.submit(
          kind: 'wifi_test',
          venueId: venueId,
          payload: {
            'wifi_speed_mbps': _measuredMbps,
            'connection_type': _measuredConnType,
            // Fingerprint captured at the moment of the test.
            if (_measuredNetHash != null)
              'network_hash': _measuredNetHash,
          },
          gpsLat: pos.latitude,
          gpsLng: pos.longitude,
          gpsDistanceM: distance,
        );
      }

      // Bonus 2: shared WiFi login rides along (+20).
      final sharedLogin = _wifiSsid.text.trim().isNotEmpty;
      if (sharedLogin && venueId != null) {
        final netHash =
            _measuredNetHash ?? await _supabase.networkFingerprint();
        await _supabase.submit(
          kind: 'wifi_login',
          venueId: venueId,
          payload: {
            'ssid': _wifiSsid.text.trim(),
            'password': _wifiPass.text.trim(),
            if (netHash != null) 'network_hash': netHash,
          },
          gpsLat: pos.latitude,
          gpsLng: pos.longitude,
          gpsDistanceM: distance,
        );
      }

      if (!mounted) return;
      Analytics.capture('submission_sent', {
        'kind': isConfirm ? 'confirm' : 'new_venue',
        'has_photo': _photo != null,
        'with_wifi_test': measuredNow,
        'with_wifi_login': sharedLogin,
      });
      final coins = (isConfirm
              ? AppConfig.coinsConfirmVenue
              : AppConfig.coinsNewVenue) +
          (measuredNow ? AppConfig.coinsWifiTest : 0) +
          (sharedLogin ? AppConfig.coinsWifiLogin : 0);
      showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                title: Row(children: [
                  const Icon(Icons.monetization_on, color: Brand.amber),
                  const SizedBox(width: 8),
                  Text('+$coins coins'),
                ]),
                content: Text(isConfirm
                    ? 'Thanks! Your coins will be credited after '
                        'verification, usually within 5 minutes.'
                    : 'Thanks! New spaces get a quick once-over by the '
                        'Nomadwise team. Your coins are usually credited '
                        'within a day.'),
                actions: [
                  TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        Navigator.pop(context);
                      },
                      child: const Text('Nice!'))
                ],
              ));
    } catch (e) {
      _snack('Something went wrong: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  bool get _spacePicked =>
      isConfirm || widget.screening != null || _placeId != null;

  int get _pendingCoins =>
      (isConfirm
          ? AppConfig.coinsConfirmVenue
          : AppConfig.coinsNewVenue) +
      (_measuredMbps != null ? AppConfig.coinsWifiTest : 0) +
      (_wifiSsid.text.trim().isNotEmpty ? AppConfig.coinsWifiLogin : 0);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.bg,
      appBar: AppBar(
        title:
            Text(isConfirm ? 'Confirm this space' : 'Review a space'),
        actions: [
          if (_coinBalance != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child:
                  Center(child: CoinChip('$_coinBalance', height: 28)),
            ),
        ],
      ),
      bottomNavigationBar: _stickyFooter(),
      body: Form(
        key: _formKey,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          _rewardCard(),
          const SizedBox(height: 14),
          if (!_spacePicked) ...[
            const FieldLabel('Space'),
            TextFormField(
              controller: _name,
              onChanged: _onNameChanged,
              decoration: const InputDecoration(
                hintText: 'Search for the space…',
                helperText:
                    'Start typing and pick it from the list. Spaces '
                    'must be real places on Google Maps.',
                helperMaxLines: 2,
                suffixIcon: Icon(Icons.search, color: Brand.inkMuted),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            if (_suggestions.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                    color: Brand.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Brand.border),
                    boxShadow: Brand.shadowFloating),
                child: Column(
                    children: _suggestions
                        .take(5)
                        .map((s) => ListTile(
                              dense: true,
                              leading: const Icon(Icons.place_outlined,
                                  color: Brand.accent, size: 20),
                              title: Text(s.main),
                              subtitle: s.secondary.isEmpty
                                  ? null
                                  : Text(s.secondary,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                              onTap: () => _pickSuggestion(s),
                            ))
                        .toList()),
              ),
          ] else
            _spaceCard(),
          const SizedBox(height: 16),
          const FieldLabel('Type'),
          DropdownButtonFormField<String>(
            value: _type,
            items: const [
              DropdownMenuItem(value: 'cafe', child: Text('Cafe')),
              DropdownMenuItem(
                  value: 'coworking', child: Text('Coworking space')),
            ],
            onChanged:
                isConfirm ? null : (v) => setState(() => _type = v!),
          ),
          const SizedBox(height: 14),
          const FieldLabel('Neighbourhood', optional: true),
          TextFormField(
            controller: _neighbourhood,
            decoration:
                const InputDecoration(hintText: 'e.g. Old town'),
          ),
          const SizedBox(height: 24),
          SectionLabel('WIFI',
              trailing: Text(
                  'up to +${AppConfig.coinsWifiTest + AppConfig.coinsWifiLogin}',
                  style: const TextStyle(
                      color: Brand.goldLink,
                      fontSize: 12,
                      fontWeight: FontWeight.w700))),
          const SizedBox(height: 12),
          _wifiTestTile(),
          const SizedBox(height: 8),
          const Text(
            'Runs a 10-second speed test from your phone.\n'
            'Only a measured test earns the bonus.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12.5, color: Brand.inkMuted, height: 1.45),
          ),
          const SizedBox(height: 14),
          FieldLabel(
              _measuredMbps != null
                  ? 'WiFi speed (Mbps), measured ✓'
                  : 'WiFi speed (Mbps)',
              optional: _measuredMbps == null),
          TextFormField(
            controller: _wifi,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [_mbpsFormatter],
            onChanged: (_) {
              // Typed over the measured number? Then it no longer
              // counts as a real test (no bonus).
              if (_measuredMbps != null &&
                  _wifi.text.trim() != _measuredMbps.toString()) {
                setState(() => _measuredMbps = null);
              }
            },
            decoration: InputDecoration(
                hintText: 'Type it if you know it',
                helperText: _measuredMbps != null
                    ? 'Measured just now, the +${AppConfig.coinsWifiTest} '
                        'coin bonus is locked in.'
                    : null),
          ),
          const SizedBox(height: 14),
          Row(children: [
            const Icon(Icons.key, size: 16, color: Brand.ink),
            const SizedBox(width: 6),
            const Expanded(
              child: Text('Know the WiFi login? Share it too.',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13.5)),
            ),
            CoinChip('+${AppConfig.coinsWifiLogin}', height: 22),
          ]),
          const SizedBox(height: 8),
          const FieldLabel('WiFi network name', optional: true),
          TextFormField(
            controller: _wifiSsid,
            decoration: InputDecoration(
              helperText: _ssidIsGuess
                  ? 'Our guess from the place name. Please check it '
                      'against the real wifi and correct it.'
                  : null,
              helperMaxLines: 2,
            ),
            // Rebuild so the footer's coin total updates live; once
            // edited, the value is theirs, not our guess.
            onChanged: (_) => setState(() => _ssidIsGuess = false),
          ),
          if (_knownSsid != null &&
              _knownSsid!.isNotEmpty &&
              _wifiSsid.text.trim() != _knownSsid) ...[
            const SizedBox(height: 6),
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => setState(() {
                _wifiSsid.text = _knownSsid!;
                if ((_knownPass ?? '').isNotEmpty &&
                    _wifiPass.text.trim().isEmpty) {
                  _wifiPass.text = _knownPass!;
                }
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Brand.goldTint,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.wifi,
                      size: 14, color: Brand.goldTextDark),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text('Tap to use recorded: $_knownSsid',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Brand.goldTextDark)),
                  ),
                ]),
              ),
            ),
          ],
          if ((_knownSsid ?? '').isEmpty &&
              _ssidGuesses().isNotEmpty) ...[
            const SizedBox(height: 6),
            if (_wifiSsid.text.trim().isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                    'Often the wifi is named after the place — tap a '
                    'guess, then fix it if needed:',
                    style: TextStyle(
                        fontSize: 11.5, color: Colors.grey.shade600)),
              ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final g in _ssidGuesses())
                  InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () =>
                        setState(() => _wifiSsid.text = g),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Brand.field,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(g,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Brand.ink)),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          const FieldLabel('WiFi password', optional: true),
          TextFormField(
            controller: _wifiPass,
            decoration: const InputDecoration(
                helperText:
                    'Only shared with signed-in nomads, never shown publicly.',
                helperMaxLines: 2),
          ),
          const SizedBox(height: 24),
          const SectionLabel("WHAT'S IT LIKE?"),
          const SizedBox(height: 10),
          _amenityRow('Laptops allowed', 'laptops_allowed', star: true),
          _amenityRow('Power outlets', 'power_outlets'),
          _amenityRow('Aircon', 'aircon'),
          _amenityRow('Comfortable seating', 'comfortable_seating'),
          _amenityRow('Cozy', 'cozy'),
          _amenityRow('Quiet space', 'quiet_space'),
          if (_type == 'coworking') ...[
            const SizedBox(height: 16),
            const SectionLabel('COWORKING EXTRAS'),
            const SizedBox(height: 10),
            _amenityRow('Good for calls', 'good_for_calls'),
            _amenityRow('Call/Skype room', 'call_room'),
            _amenityRow('Monitor available', 'monitor'),
            _amenityRow('Office chairs', 'office_chairs'),
            _amenityRow('24h access', 'access_24h'),
          ],
          const SizedBox(height: 8),
          DashedBorderBox(
            child: InkWell(
              onTap: _pickPhoto,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                height: 54,
                alignment: Alignment.center,
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                          _photo == null
                              ? Icons.photo_camera_outlined
                              : Icons.check_circle,
                          size: 19,
                          color: _photo == null
                              ? Brand.ink
                              : Brand.success),
                      const SizedBox(width: 8),
                      Text(_photo == null ? 'Add a photo' : 'Photo added',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14)),
                      const SizedBox(width: 6),
                      Text(
                          _photo == null
                              ? 'optional · helps nomads'
                              : 'tap to retake',
                          style: const TextStyle(
                              fontSize: 13, color: Brand.inkMuted)),
                    ]),
              ),
            ),
          ),
          if (_photo != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.memory(_photo!, height: 160,
                    width: double.infinity, fit: BoxFit.cover)),
          ],
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  Widget _rewardCard() {
    final base = isConfirm
        ? AppConfig.coinsConfirmVenue
        : AppConfig.coinsNewVenue;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x80F4B23E)),
      ),
      child: Row(children: [
        Container(
          width: 42,
          height: 42,
          decoration: const BoxDecoration(
              color: Brand.goldTint, shape: BoxShape.circle),
          child: const Center(child: CoinDot(size: 20)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    isConfirm
                        ? 'Confirm what this place is really like'
                        : 'Be the first to review this space',
                    style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: Brand.ink)),
                const SizedBox(height: 2),
                Text(
                    'Complete the ${isConfirm ? 'confirmation' : 'review'} '
                    'to earn $base coins',
                    style: const TextStyle(
                        fontSize: 12.5, color: Brand.inkSecondary)),
              ]),
        ),
        Text('+$base',
            style: const TextStyle(
                color: Brand.goldLink,
                fontSize: 16,
                fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _spaceCard() {
    final canChange = !isConfirm && widget.screening == null;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Brand.border),
      ),
      child:
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_refPhotos.isNotEmpty)
          SizedBox(
            height: 120,
            child: Row(
                children: _refPhotos
                    .take(3)
                    .map((u) => Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(right: 3),
                            child: Image.network(u,
                                height: 120,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    Container(color: Brand.field)),
                          ),
                        ))
                    .toList()),
          ),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(_name.text,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.check_circle,
                          size: 17, color: Brand.success),
                    ]),
                    const SizedBox(height: 2),
                    Text(
                        [
                          if (_refRating != null) '★ $_refRating',
                          if (_refPhotos.isNotEmpty)
                            'photos from Google',
                        ].join(' · '),
                        style: const TextStyle(
                            fontSize: 12.5, color: Brand.inkMuted)),
                  ]),
            ),
            if (canChange)
              TextButton(
                onPressed: () => setState(() {
                  _placeId = null;
                  _placeLat = null;
                  _placeLng = null;
                  _placeCity = null;
                  _refPhotos = [];
                  _refRating = null;
                  _existing = null;
                  _name.clear();
                }),
                child: const Text('Change'),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _stickyFooter() {
    return Container(
      decoration: const BoxDecoration(
        color: Brand.surface,
        border: Border(top: BorderSide(color: Brand.hairline)),
      ),
      padding: EdgeInsets.fromLTRB(
          16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        PrimaryCta(
          label:
              isConfirm ? 'Submit confirmation' : 'Submit review',
          coins: '+$_pendingCoins',
          onPressed: _saving ? null : _submit,
          busyChild: _saving
              ? const SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2.5))
              : null,
        ),
        const SizedBox(height: 7),
        Text(
          isConfirm
              ? 'Coins are credited after verification, usually within 5 minutes.'
              : 'Reviewed by another nomad before it goes live',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Brand.inkMuted, fontSize: 12),
        ),
      ]),
    );
  }

  Widget _amenityRow(String label, String key, {bool star = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.border),
      ),
      child: Row(children: [
        Expanded(
          child: Row(children: [
            Flexible(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w600)),
            ),
            if (star) ...[
              const SizedBox(width: 6),
              const Icon(Icons.star, size: 15, color: Brand.gold),
            ],
          ]),
        ),
        YesNoToggle(
          value: _features[key],
          onChanged: (v) => setState(() => _features[key] = v),
        ),
      ]),
    );
  }


  Widget _wifiTestTile() {
    if (_testingWifi) {
      return Container(
        height: 52,
        width: double.infinity,
        decoration: BoxDecoration(
            color: Brand.ink,
            borderRadius: BorderRadius.circular(14)),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white)),
          const SizedBox(width: 10),
          Text(_testPhase,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, color: Colors.white)),
        ]),
      );
    }
    if (_measuredMbps != null) {
      return Container(
        width: double.infinity,
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
            color: Brand.successTint,
            borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          const Icon(Icons.check_circle, color: Brand.success, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text('$_measuredMbps Mbps measured',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          TextButton(
              onPressed: _testWifiHere, child: const Text('Re-test')),
        ]),
      );
    }
    return PrimaryCta(
      label: 'Test the WiFi now',
      coins: '+${AppConfig.coinsWifiTest}',
      navy: true,
      icon: Icons.speed,
      onPressed: _testWifiHere,
    );
  }
}
