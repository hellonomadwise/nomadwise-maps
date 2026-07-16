import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../config.dart';
import '../models/venue.dart';
import '../services/location_service.dart';
import '../services/places_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import 'add_venue_screen.dart';
import 'auth_screen.dart';
import 'venue_detail.dart';
import 'wallet_screen.dart';

enum VenueFilter { openNow, openLate, open24h, workFriendly }

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _supabase = SupabaseService();
  final _places = PlacesService();

  GoogleMapController? _map;
  List<Venue> _venues = [];
  final Set<VenueFilter> _filters = {};
  Venue? _selected;
  double? _userLat, _userLng;
  bool _loading = true;

  BitmapDescriptor? _pinYes, _pinNo, _pinUnknown;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await _loadPinIcons();
    // Location and venue list in parallel.
    final results = await Future.wait([
      LocationService.current(),
      _supabase.fetchVenues(),
    ]);
    final pos = results[0] as dynamic;
    _venues = results[1] as List<Venue>;
    if (pos != null) {
      _userLat = pos.latitude;
      _userLng = pos.longitude;
    } else {
      final (la, ln) = LocationService.fallback();
      _userLat = la;
      _userLng = ln;
    }
    _computeDistances();
    if (mounted) setState(() => _loading = false);

    // Live Google data (rating, hours, coordinates) arrives second;
    // markers refresh when it lands.
    await _places.enrich(_venues);
    _computeDistances();
    if (mounted) setState(() {});
  }

  Future<void> _loadPinIcons() async {
    const cfg = ImageConfiguration(size: Size(38, 48));
    _pinYes = await BitmapDescriptor.asset(cfg, 'assets/pins/pin_yes.png');
    _pinNo = await BitmapDescriptor.asset(cfg, 'assets/pins/pin_no.png');
    _pinUnknown =
        await BitmapDescriptor.asset(cfg, 'assets/pins/pin_unknown.png');
  }

  Future<void> _goToMyLocation() async {
    final pos = await LocationService.current();
    if (pos == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Location unavailable — check your browser/phone location permission.')));
      }
      return;
    }
    _userLat = pos.latitude;
    _userLng = pos.longitude;
    _computeDistances();
    if (mounted) setState(() {});
    _map?.animateCamera(CameraUpdate.newLatLngZoom(
        LatLng(pos.latitude, pos.longitude), 15));
  }

  void _computeDistances() {
    if (_userLat == null) return;
    for (final v in _venues) {
      if (v.lat != null && v.lng != null) {
        v.distanceM =
            Venue.haversineM(_userLat!, _userLng!, v.lat!, v.lng!);
      }
    }
    _venues.sort((a, b) => (a.distanceM ?? double.infinity)
        .compareTo(b.distanceM ?? double.infinity));
  }

  List<Venue> get _visibleVenues => _venues.where((v) {
        if (v.lat == null || v.lng == null) return false;
        if (_filters.contains(VenueFilter.workFriendly) &&
            v.workFriendly != WorkFriendly.yes) return false;
        if (_filters.contains(VenueFilter.openNow) && v.openNow != true) {
          return false;
        }
        if (_filters.contains(VenueFilter.openLate) && !v.openLate) {
          return false;
        }
        if (_filters.contains(VenueFilter.open24h) && !v.is24h) return false;
        return true;
      }).toList();

  BitmapDescriptor _iconFor(Venue v) => switch (v.workFriendly) {
        WorkFriendly.yes =>
          _pinYes ?? BitmapDescriptor.defaultMarkerWithHue(358),
        WorkFriendly.no =>
          _pinNo ?? BitmapDescriptor.defaultMarkerWithHue(0),
        WorkFriendly.unknown =>
          _pinUnknown ?? BitmapDescriptor.defaultMarkerWithHue(30),
      };

  Set<Marker> get _markers => _visibleVenues
      .map((v) => Marker(
            markerId: MarkerId(v.id),
            position: LatLng(v.lat!, v.lng!),
            icon: _iconFor(v),
            alpha: v.workFriendly == WorkFriendly.no ? 0.55 : 1.0,
            onTap: () => setState(() => _selected = v),
          ))
      .toSet();

  Future<void> _openAddVenue({Venue? confirming}) async {
    if (!_supabase.signedIn) {
      final ok = await Navigator.push<bool>(context,
          MaterialPageRoute(builder: (_) => const AuthScreen()));
      if (ok != true) return;
    }
    if (!mounted) return;
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => AddVenueScreen(
                confirming: confirming,
                userLat: _userLat,
                userLng: _userLng)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Image.asset('assets/brand/logo_mark.png', height: 28),
          const SizedBox(width: 8),
          const Text('nomadwise',
              style: TextStyle(color: Brand.charcoal)),
          const SizedBox(width: 5),
          const Text('maps', style: TextStyle(color: Brand.red)),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_balance_wallet_outlined,
                color: Brand.amber),
            tooltip: 'Wallet',
            onPressed: () async {
              if (!_supabase.signedIn) {
                final ok = await Navigator.push<bool>(context,
                    MaterialPageRoute(builder: (_) => const AuthScreen()));
                if (ok != true) return;
              }
              if (!context.mounted) return;
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const WalletScreen()));
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Brand.red))
          : Stack(children: [
              GoogleMap(
                initialCameraPosition: CameraPosition(
                    target: LatLng(_userLat!, _userLng!), zoom: 14),
                myLocationEnabled: true,
                myLocationButtonEnabled: true,
                zoomControlsEnabled: false,
                markers: _markers,
                onMapCreated: (c) => _map = c,
                onTap: (_) => setState(() => _selected = null),
              ),
              // ---- filter chips ----
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: PointerInterceptor(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                      child: Row(children: [
                        _chip('Open now', VenueFilter.openNow),
                        _chip('Open late', VenueFilter.openLate),
                        _chip('24 hours', VenueFilter.open24h),
                        _chip('Work-friendly', VenueFilter.workFriendly),
                      ]),
                    ),
                  ),
                ),
              ),
              // ---- locate me ----
              Positioned(
                right: 14,
                bottom: _selected == null ? 96 : 210,
                child: PointerInterceptor(
                  child: Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    elevation: 4,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _goToMyLocation,
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Icon(Icons.my_location,
                            color: Brand.red, size: 22),
                      ),
                    ),
                  ),
                ),
              ),
              if (_selected != null)
                Positioned(
                    left: 12,
                    right: 12,
                    bottom: 24,
                    child: PointerInterceptor(
                        child: _VenueCard(
                            venue: _selected!,
                            onDetails: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => VenueDetailScreen(
                                        venue: _selected!,
                                        onConfirm: () => _openAddVenue(
                                            confirming: _selected))))))),
            ]),
      floatingActionButton: _selected == null
          ? PointerInterceptor(
              child: FloatingActionButton.extended(
                onPressed: () => _openAddVenue(),
                icon: const Icon(Icons.add_location_alt_outlined),
                label: const Text('Add / confirm a cafe'),
              ),
            )
          : null,
    );
  }

  Widget _chip(String label, VenueFilter f) {
    final on = _filters.contains(f);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label,
            style: TextStyle(
                color: on ? Colors.white : Brand.charcoal,
                fontWeight: FontWeight.w500)),
        selected: on,
        showCheckmark: false,
        elevation: 3,
        pressElevation: 1,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        onSelected: (_) => setState(() {
          on ? _filters.remove(f) : _filters.add(f);
          if (_selected != null && !_visibleVenues.contains(_selected)) {
            _selected = null;
          }
        }),
      ),
    );
  }
}

/// Compact card shown when a pin is tapped.
class _VenueCard extends StatelessWidget {
  final Venue venue;
  final VoidCallback onDetails;
  const _VenueCard({required this.venue, required this.onDetails});

  @override
  Widget build(BuildContext context) {
    final wf = venue.workFriendly;
    final closing = venue.closingLabel(
        soonMinutes: AppConfig.closingSoonMinutes);
    return Card(
      elevation: 6,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(
                child: Text(venue.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 17))),
            Text(venue.distanceLabel(),
                style: const TextStyle(
                    color: Brand.charcoal, fontWeight: FontWeight.w500)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            if (venue.rating != null) ...[
              const Icon(Icons.star, color: Brand.amber, size: 18),
              Text(' ${venue.rating}  ',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              if (venue.reviewCount != null)
                Text('(${venue.reviewCount})  ',
                    style: TextStyle(color: Colors.grey.shade600)),
            ],
            if (closing != null)
              Expanded(
                child: Text(closing,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: closing.startsWith('Closing') ||
                                closing == 'Closed'
                            ? Brand.red
                            : Colors.green.shade700,
                        fontWeight: FontWeight.w500)),
              ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _wfBadge(wf),
            const Spacer(),
            TextButton(onPressed: onDetails, child: const Text('Details')),
          ]),
        ]),
      ),
    );
  }

  Widget _wfBadge(WorkFriendly wf) {
    final (label, color, icon) = switch (wf) {
      WorkFriendly.yes => ('Work-friendly', Brand.red, Icons.laptop_mac),
      WorkFriendly.no => (
          'Not for laptops',
          Colors.blueGrey,
          Icons.laptop_chromebook
        ),
      WorkFriendly.unknown => (
          'Unknown — confirm & earn',
          Brand.amber,
          Icons.help_outline
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 5),
        Text(label,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w700, fontSize: 12)),
      ]),
    );
  }
}
