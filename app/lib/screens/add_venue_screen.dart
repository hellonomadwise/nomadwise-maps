import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../config.dart';
import '../models/discovered_place.dart';
import '../models/venue.dart';
import '../services/location_service.dart';
import '../services/places_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';

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
  String _type = 'cafe';

  // New venues must be picked from Google so they're real places.
  String? _placeId;
  double? _placeLat, _placeLng;
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
  };

  Uint8List? _photo;
  bool _saving = false;

  bool get isConfirm => _confirmTarget != null;
  Venue? get _confirmTarget => widget.confirming ?? _existing;

  @override
  void initState() {
    super.initState();
    _prefillFrom(widget.confirming);
    final s = widget.screening;
    if (s != null) {
      _name.text = s.name;
      _placeId = s.placeId;
      _placeLat = s.lat;
      _placeLng = s.lng;
      if (s.primaryType == 'coworking_space') _type = 'coworking';
    }
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
      if (v.wifiSpeedMbps != null) _wifi.text = v.wifiSpeedMbps.toString();
      _features['laptops_allowed'] = v.laptopsAllowed;
      _features['power_outlets'] = v.powerOutlets;
      _features['aircon'] = v.aircon;
      _features['comfortable_seating'] = v.comfortableSeating;
      _features['cozy'] = v.cozy;
      _features['quiet_space'] = v.quietSpace;
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
      if (live?.displayName != null) _name.text = live!.displayName!;
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

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_features['laptops_allowed'] == null) {
      _snack('Please answer the key question: are laptops allowed?');
      return;
    }
    if (!isConfirm && _placeId == null) {
      _snack('Please pick the venue from the search suggestions.');
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
          'wifi_speed_mbps': num.tryParse(_wifi.text.trim()),
        ..._features,
      };

      String? venueId = _confirmTarget?.id;
      if (!isConfirm) {
        venueId = await _supabase.addPendingVenue({
          'name': _name.text.trim(),
          'type': _type,
          'neighbourhood': _neighbourhood.text.trim(),
          'google_place_id': _placeId,
          // Venue pin sits where Google says the place is.
          'lat': _placeLat ?? pos.latitude,
          'lng': _placeLng ?? pos.longitude,
          if (_wifi.text.trim().isNotEmpty)
            'wifi_speed_mbps': num.tryParse(_wifi.text.trim()),
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

      if (!mounted) return;
      final coins = isConfirm
          ? AppConfig.coinsConfirmVenue
          : AppConfig.coinsNewVenue;
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
                    : 'Thanks! New venues get a quick once-over by the '
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(isConfirm
              ? 'Confirm this space'
              : 'Review a space')),
      body: Form(
        key: _formKey,
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                gradient: Brand.gradient,
                borderRadius: BorderRadius.circular(14)),
            child: Text(
              isConfirm
                  ? 'Confirm what this place is really like and earn '
                      '${AppConfig.coinsConfirmVenue} coins.'
                  : 'Be the first to review this space for nomads and earn '
                      '${AppConfig.coinsNewVenue} coins.',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: _name,
            enabled: !isConfirm && widget.screening == null,
            onChanged: _onNameChanged,
            decoration: InputDecoration(
              labelText: isConfirm || widget.screening != null
                  ? 'Space name'
                  : 'Search for the space…',
              helperText: isConfirm || widget.screening != null
                  ? null
                  : 'Start typing and pick it from the list. Spaces must '
                      'be real places on Google Maps.',
              helperMaxLines: 2,
              suffixIcon: isConfirm
                  ? null
                  : Icon(
                      _placeId != null
                          ? Icons.check_circle
                          : Icons.search,
                      color: _placeId != null
                          ? Colors.green
                          : Colors.grey.shade500),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
          if (_suggestions.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: .08),
                        blurRadius: 12)
                  ]),
              child: Column(
                  children: _suggestions
                      .take(5)
                      .map((s) => ListTile(
                            dense: true,
                            leading: const Icon(Icons.place_outlined,
                                color: Brand.red, size: 20),
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
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _type,
            items: const [
              DropdownMenuItem(value: 'cafe', child: Text('Cafe')),
              DropdownMenuItem(
                  value: 'coworking', child: Text('Coworking space')),
            ],
            onChanged:
                isConfirm ? null : (v) => setState(() => _type = v!),
            decoration: const InputDecoration(labelText: 'Type'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _neighbourhood,
            decoration:
                const InputDecoration(labelText: 'Neighbourhood'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _wifi,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'WiFi speed (Mbps), if you know it',
                helperText:
                    'Soon the app will measure this for you automatically.'),
          ),
          const SizedBox(height: 20),
          const Text('WHAT\'S IT LIKE?',
              style: TextStyle(
                  color: Brand.red,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                  letterSpacing: 1)),
          const SizedBox(height: 4),
          _triState('Laptops allowed  ⭐', 'laptops_allowed'),
          _triState('Power outlets', 'power_outlets'),
          _triState('Aircon', 'aircon'),
          _triState('Comfortable seating', 'comfortable_seating'),
          _triState('Cozy', 'cozy'),
          _triState('Quiet space', 'quiet_space'),
          const SizedBox(height: 20),

          // ---- photo ----
          OutlinedButton.icon(
            onPressed: _pickPhoto,
            icon: Icon(
                _photo == null ? Icons.photo_camera : Icons.check_circle,
                color: _photo == null ? Brand.red : Colors.green),
            label: Text(_photo == null
                ? 'Add a photo (optional, helps other nomads)'
                : 'Photo added ✓ · tap to retake'),
            style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: const BorderSide(color: Brand.red)),
          ),
          if (_photo != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.memory(_photo!, height: 160,
                    width: double.infinity, fit: BoxFit.cover)),
          ],
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2.5))
                : Text(isConfirm
                    ? 'Submit confirmation  ·  +${AppConfig.coinsConfirmVenue} coins'
                    : 'Submit review  ·  +${AppConfig.coinsNewVenue} coins'),
          ),
          const SizedBox(height: 10),
          Text(
            isConfirm
                ? 'Coins are credited after verification, usually within 5 minutes.'
                : 'Coins are credited after a quick review, usually within a day.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
          const SizedBox(height: 30),
        ]),
      ),
    );
  }

  Widget _triState(String label, String key) {
    final val = _features[key];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(child: Text(label)),
        SegmentedButton<bool?>(
          segments: const [
            ButtonSegment(
                value: true,
                label: SizedBox(
                    width: 34, child: Center(child: Text('Yes')))),
            ButtonSegment(
                value: false,
                label: SizedBox(
                    width: 34, child: Center(child: Text('No')))),
            ButtonSegment(
                value: null,
                label: SizedBox(
                    width: 34, child: Center(child: Text('?')))),
          ],
          selected: {val},
          showSelectedIcon: false, // no checkmark = no width jumping
          onSelectionChanged: (s) =>
              setState(() => _features[key] = s.first),
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            backgroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.selected)
                    ? Brand.red.withValues(alpha: .12)
                    : null),
          ),
        ),
      ]),
    );
  }
}
