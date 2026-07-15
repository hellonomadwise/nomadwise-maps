import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../config.dart';
import '../models/venue.dart';
import '../services/location_service.dart';
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
  final double? userLat, userLng;
  const AddVenueScreen(
      {super.key, this.confirming, this.userLat, this.userLng});

  @override
  State<AddVenueScreen> createState() => _AddVenueScreenState();
}

class _AddVenueScreenState extends State<AddVenueScreen> {
  final _supabase = SupabaseService();
  final _formKey = GlobalKey<FormState>();

  final _name = TextEditingController();
  final _neighbourhood = TextEditingController();
  final _wifi = TextEditingController();
  String _type = 'cafe';

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

  bool get isConfirm => widget.confirming != null;

  @override
  void initState() {
    super.initState();
    final v = widget.confirming;
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
    if (_photo == null) {
      _snack('A photo of the venue is required — it\'s how we verify.');
      return;
    }
    if (_features['laptops_allowed'] == null) {
      _snack('Please answer the key question: are laptops allowed?');
      return;
    }
    setState(() => _saving = true);
    try {
      // GPS check: where is the user right now?
      final pos = await LocationService.current();
      if (pos == null) {
        _snack('Location is required to verify you\'re at the venue.');
        setState(() => _saving = false);
        return;
      }
      double? distance;
      final v = widget.confirming;
      if (v?.lat != null && v?.lng != null) {
        distance = Venue.haversineM(
            pos.latitude, pos.longitude, v!.lat!, v.lng!);
      }

      final payload = {
        'name': _name.text.trim(),
        'type': _type,
        'neighbourhood': _neighbourhood.text.trim(),
        if (_wifi.text.trim().isNotEmpty)
          'wifi_speed_mbps': num.tryParse(_wifi.text.trim()),
        ..._features,
      };

      String? venueId = widget.confirming?.id;
      if (!isConfirm) {
        venueId = await _supabase.addPendingVenue({
          'name': _name.text.trim(),
          'type': _type,
          'neighbourhood': _neighbourhood.text.trim(),
          'lat': pos.latitude,
          'lng': pos.longitude,
          if (_wifi.text.trim().isNotEmpty)
            'wifi_speed_mbps': num.tryParse(_wifi.text.trim()),
          ..._features,
        });
      }

      await _supabase.submit(
        kind: isConfirm ? 'confirm' : 'new_venue',
        venueId: venueId,
        payload: payload,
        photoBytes: _photo!,
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
                content: const Text(
                    'Thanks! Your coins are pending and will unlock once the '
                    'photo and location are verified.'),
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
              ? 'Confirm this venue'
              : 'Add a new venue')),
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
                  : 'Add a place nomads can work from and earn '
                      '${AppConfig.coinsNewVenue} coins.',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: _name,
            enabled: !isConfirm,
            decoration: const InputDecoration(labelText: 'Venue name'),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Required' : null,
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
                labelText: 'WiFi speed (Mbps) — if you know it',
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
                ? 'Take a photo (required)'
                : 'Photo added ✓ — tap to retake'),
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
                    : 'Submit new venue  ·  +${AppConfig.coinsNewVenue} coins'),
          ),
          const SizedBox(height: 10),
          Text(
            'Coins unlock after verification (photo + a check that you were '
            'really at the venue).',
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
            ButtonSegment(value: true, label: Text('Yes')),
            ButtonSegment(value: false, label: Text('No')),
            ButtonSegment(value: null, label: Text('?')),
          ],
          selected: {val},
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
