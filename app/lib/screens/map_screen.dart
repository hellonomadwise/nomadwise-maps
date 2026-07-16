import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/discovered_place.dart';
import '../models/venue.dart';
import '../services/analytics_service.dart';
import '../services/location_service.dart';
import '../services/places_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import 'add_venue_screen.dart';
import 'admin_screen.dart';
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
  String? _typeFilter; // null = all, 'cafe', 'coworking'
  // Which pin colours are visible (tap the legend to toggle).
  final Set<WorkFriendly> _wfVisible = {...WorkFriendly.values};
  bool _showUnscreened = true;
  bool _legendOpen = false;
  bool _showList = false;
  Venue? _selected;
  DiscoveredPlace? _selectedDiscovered;
  List<DiscoveredPlace> _discovered = [];
  bool _searchingArea = false;
  double? _userLat, _userLng;
  bool _loading = true;
  bool _isAdmin = false;

  BitmapDescriptor? _pinYes, _pinNo, _pinUnknown, _pinUnscreened, _pinMe;
  bool _hasRealLocation = false;

  String? _displayName;

  @override
  void initState() {
    super.initState();
    _boot();
    _checkAdmin();
    Analytics.capture('app_opened');
    _supabase.authChanges.listen((state) {
      _checkAdmin();
      final user = _supabase.currentUser;
      if (state.event == AuthChangeEvent.signedIn && user != null) {
        _onSignedIn(user.id, user.email);
      } else if (state.event == AuthChangeEvent.signedOut) {
        Analytics.capture('signed_out');
        Analytics.reset();
        if (mounted) setState(() => _displayName = null);
      }
    });
  }

  Future<void> _onSignedIn(String userId, String? email) async {
    final name = await _supabase.myDisplayName();
    if (mounted) setState(() => _displayName = name);
    await Analytics.identify(userId, email: email, name: name);
    await Analytics.capture('signed_in');
  }

  Future<void> _checkAdmin() async {
    final admin = await _supabase.isAdmin();
    if (mounted && admin != _isAdmin) setState(() => _isAdmin = admin);
    _displayName ??= await _supabase.myDisplayName();
    if (mounted) setState(() {}); // refresh signed-in state in the menu
  }

  Future<void> _editNickname() async {
    final ctrl = TextEditingController(text: _displayName ?? '');
    final saved = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: const Text('Your nickname'),
              content: TextField(
                controller: ctrl,
                autofocus: true,
                maxLength: 24,
                decoration: const InputDecoration(
                    labelText: 'Shown on the leaderboard',
                    counterText: ''),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Save')),
              ],
            ));
    final name = ctrl.text.trim();
    if (saved == true && name.isNotEmpty) {
      await _supabase.updateDisplayName(name);
      if (mounted) setState(() => _displayName = name);
      Analytics.capture('nickname_set');
    }
  }

  Future<void> _boot() async {
    await _loadPinIcons();

    // Instant start: show venues remembered from the last visit while the
    // fresh data and the user's location load in the background.
    final cached = await _supabase.cachedVenues();
    if (cached.isNotEmpty && mounted && _loading) {
      _venues = cached;
      final (la, ln) = LocationService.fallback();
      _userLat ??= la;
      _userLng ??= ln;
      _computeDistances();
      setState(() => _loading = false);
    }

    final results = await Future.wait([
      LocationService.current(),
      _supabase.fetchVenues(),
    ]);
    final pos = results[0] as dynamic;
    _venues = results[1] as List<Venue>;
    if (pos != null) {
      _userLat = pos.latitude;
      _userLng = pos.longitude;
      _hasRealLocation = true;
      // If we started from cache with the fallback centre, fly to the user.
      _map?.animateCamera(CameraUpdate.newLatLngZoom(
          LatLng(pos.latitude, pos.longitude), 14));
    } else {
      final (la, ln) = LocationService.fallback();
      _userLat ??= la;
      _userLng ??= ln;
    }
    _computeDistances();
    if (mounted) setState(() => _loading = false);

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
    _pinUnscreened = await BitmapDescriptor.asset(
        cfg, 'assets/pins/pin_unscreened.png');
    _pinMe = await BitmapDescriptor.asset(
        const ImageConfiguration(size: Size(32, 32)),
        'assets/pins/my_location.png');
  }

  // ---------- discovery ("Search this area") ----------

  Future<void> _searchThisArea() async {
    final map = _map;
    if (map == null || _searchingArea) return;
    setState(() => _searchingArea = true);
    try {
      final bounds = await map.getVisibleRegion();
      final cLat = (bounds.southwest.latitude +
              bounds.northeast.latitude) /
          2;
      final cLng = (bounds.southwest.longitude +
              bounds.northeast.longitude) /
          2;

      // 1. Our own cache first — free.
      final cached = await _supabase.discoveredInBounds(
          bounds.southwest.latitude,
          bounds.northeast.latitude,
          bounds.southwest.longitude,
          bounds.northeast.longitude);
      _mergeDiscovered(cached);

      // 2. Ask Google only when this area is still thin.
      if (cached.length < 5) {
        final radius = Venue.haversineM(
                cLat, cLng,
                bounds.northeast.latitude, bounds.northeast.longitude)
            .clamp(300.0, 5000.0);
        final fresh = await _places.searchNearby(cLat, cLng, radius);
        await _supabase.cacheDiscovered(fresh);
        _mergeDiscovered(fresh);
      }
      Analytics.capture(
          'area_searched', {'found': _visibleDiscovered.length});
      if (mounted) {
        final n = _visibleDiscovered.length;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            duration: const Duration(seconds: 2),
            content: Text(n == 0
                ? 'No unscreened cafes found here yet.'
                : '$n unscreened cafes here. Screen one & earn ${AppConfig.coinsNewVenue} coins!')));
      }
    } finally {
      if (mounted) setState(() => _searchingArea = false);
    }
  }

  void _mergeDiscovered(List<DiscoveredPlace> more) {
    final have = _discovered.map((d) => d.placeId).toSet();
    _discovered = [
      ..._discovered,
      ...more.where((d) => !have.contains(d.placeId)),
    ];
    if (mounted) setState(() {});
  }

  /// Discovered places not yet on our map as venues.
  List<DiscoveredPlace> get _visibleDiscovered {
    if (!_showUnscreened) return [];
    final venuePlaceIds =
        _venues.map((v) => v.googlePlaceId).whereType<String>().toSet();
    return _discovered
        .where((d) => !venuePlaceIds.contains(d.placeId))
        .toList();
  }

  Future<void> _openScreening(DiscoveredPlace p) async {
    if (!_supabase.signedIn) {
      final ok = await Navigator.push<bool>(context,
          MaterialPageRoute(builder: (_) => const AuthScreen()));
      if (ok != true) return;
    }
    if (!mounted) return;
    Analytics.capture('screening_opened', {'place': p.name});
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => AddVenueScreen(
                screening: p,
                userLat: _userLat,
                userLng: _userLng)));
    // Their new pending venue should appear for them right away.
    _venues = await _supabase.fetchVenues();
    _computeDistances();
    if (mounted) {
      setState(() => _selectedDiscovered = null);
    }
  }

  Future<void> _goToMyLocation() async {
    final pos = await LocationService.current();
    if (pos == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Location unavailable. Check your browser/phone location permission.')));
      }
      return;
    }
    _userLat = pos.latitude;
    _userLng = pos.longitude;
    _hasRealLocation = true;
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

  /// "Spaces" / "Cafes" / "Coworking Spaces" depending on the type filter.
  String get _noun => switch (_typeFilter) {
        'cafe' => 'Cafes',
        'coworking' => 'Coworking Spaces',
        _ => 'Spaces',
      };

  bool get _anyFilterOn =>
      _filters.isNotEmpty ||
      _typeFilter != null ||
      _wfVisible.length < WorkFriendly.values.length;

  List<Venue> get _visibleVenues => _venues.where((v) {
        if (v.lat == null || v.lng == null) return false;
        if (!_wfVisible.contains(v.workFriendly)) return false;
        if (_typeFilter != null && v.type != _typeFilter) return false;
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

  Set<Marker> get _markers => {
        // "You are here" — blue dot, only when we truly know the location.
        if (_hasRealLocation && _userLat != null)
          Marker(
            markerId: const MarkerId('me'),
            position: LatLng(_userLat!, _userLng!),
            icon: _pinMe ?? BitmapDescriptor.defaultMarkerWithHue(220),
            anchor: const Offset(0.5, 0.5),
            consumeTapEvents: false,
          ),
        ..._visibleVenues.map((v) => Marker(
              markerId: MarkerId(v.id),
              position: LatLng(v.lat!, v.lng!),
              icon: _iconFor(v),
              alpha: v.workFriendly == WorkFriendly.no ? 0.85 : 1.0,
              onTap: () => setState(() {
                _selected = v;
                _selectedDiscovered = null;
              }),
            )),
        ..._visibleDiscovered.map((d) => Marker(
              markerId: MarkerId('disc-${d.placeId}'),
              position: LatLng(d.lat, d.lng),
              icon: _pinUnscreened ??
                  BitmapDescriptor.defaultMarkerWithHue(200),
              alpha: 0.92,
              onTap: () => setState(() {
                _selectedDiscovered = d;
                _selected = null;
              }),
            )),
      };

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

  Future<void> _requireSignIn(VoidCallback then) async {
    if (_supabase.signedIn) {
      then();
      return;
    }
    final ok = await Navigator.push<bool>(
        context, MaterialPageRoute(builder: (_) => const AuthScreen()));
    if (ok == true && mounted) then();
  }

  void _openDetail(Venue v) => Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => VenueDetailScreen(
              venue: v, onConfirm: () => _openAddVenue(confirming: v))));

  // ---------- venue name search ----------

  Future<void> _openSearch() async {
    final v = await showSearch<Venue?>(
        context: context,
        delegate: _VenueSearchDelegate(_venues));
    if (v != null && v.lat != null && mounted) {
      setState(() {
        _showList = false;
        _selected = v;
      });
      _map?.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(v.lat!, v.lng!), 16));
    }
  }

  // ---------- jump to city ----------

  Future<void> _openJumpToCity() async {
    final citiesWithSpaces =
        _venues.map((v) => v.city).toSet().toList()..sort();
    final placeId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => PointerInterceptor(
          child: _JumpToCitySheet(
              places: _places, citiesWithSpaces: citiesWithSpaces)),
    );
    if (placeId == null || !mounted) return;
    if (placeId.startsWith('venue-city:')) {
      // A city we already have venues in — fly to its first venue.
      final city = placeId.substring('venue-city:'.length);
      final v = _venues
          .where((v) => v.city == city && v.lat != null)
          .firstOrNull;
      if (v != null) {
        _map?.animateCamera(
            CameraUpdate.newLatLngZoom(LatLng(v.lat!, v.lng!), 13));
      }
      return;
    }
    final live = await _places.details(placeId);
    if (live?.lat != null && mounted) {
      _map?.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(live!.lat!, live.lng!), 12));
    }
  }

  // ---------- menu ----------

  Widget _buildMenu() {
    final user = _supabase.currentUser;
    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(gradient: Brand.gradient),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Image.asset('assets/brand/app_icon.png', height: 52),
              const SizedBox(height: 12),
              if (user != null) ...[
                InkWell(
                  onTap: () {
                    Navigator.pop(context);
                    _editNickname();
                  },
                  child: Row(children: [
                    Flexible(
                      child: Text(
                        _displayName ?? 'Set your nickname',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w900),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.edit, size: 15, color: Colors.white70),
                  ]),
                ),
                Text(
                  user.email ?? '',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ] else ...[
                const Text('Not signed in',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700)),
                const Text('Sign in to earn coins',
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
              ],
            ]),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.account_balance_wallet_outlined,
                color: Brand.amber),
            title: const Text('Wallet'),
            onTap: () {
              Navigator.pop(context);
              _requireSignIn(() => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const WalletScreen())));
            },
          ),
          ListTile(
            leading:
                const Icon(Icons.rate_review_outlined, color: Brand.red),
            title: const Text('Review a space'),
            subtitle: Text(
                'Earn up to ${AppConfig.coinsNewVenue} coins',
                style:
                    TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            onTap: () {
              Navigator.pop(context);
              _openAddVenue();
            },
          ),
          if (_isAdmin)
            ListTile(
              leading: const Icon(Icons.fact_check_outlined,
                  color: Brand.charcoal),
              title: const Text('Review submissions'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const AdminScreen()));
              },
            ),
          ListTile(
            enabled: false,
            leading: Icon(Icons.settings_outlined,
                color: Colors.grey.shade400),
            title: Text('Settings',
                style: TextStyle(color: Colors.grey.shade400)),
            subtitle: Text('Coming soon',
                style:
                    TextStyle(color: Colors.grey.shade400, fontSize: 12)),
          ),
          const Spacer(),
          const Divider(height: 1),
          if (user != null)
            ListTile(
              leading: const Icon(Icons.logout, color: Brand.red),
              title: const Text('Sign out'),
              onTap: () async {
                await _supabase.signOut();
                if (mounted) {
                  Navigator.pop(context);
                  setState(() => _isAdmin = false);
                }
              },
            )
          else
            ListTile(
              leading: const Icon(Icons.login, color: Brand.red),
              title: const Text('Sign in'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const AuthScreen()));
              },
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  // ---------- build ----------

  /// Venues + unscreened places merged, nearest first (for the list view).
  List<Object> get _listEntries {
    double distOf(Object e) {
      if (e is Venue) return e.distanceM ?? double.infinity;
      final d = e as DiscoveredPlace;
      if (_userLat == null) return double.infinity;
      return Venue.haversineM(_userLat!, _userLng!, d.lat, d.lng);
    }

    final entries = <Object>[..._visibleVenues, ..._visibleDiscovered];
    entries.sort((a, b) => distOf(a).compareTo(distOf(b)));
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleVenues;
    return Scaffold(
      drawer: _buildMenu(),
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
            icon: const Icon(Icons.search, color: Brand.charcoal),
            tooltip: 'Search venues',
            onPressed: _openSearch,
          ),
          IconButton(
            icon: const Icon(Icons.account_balance_wallet_outlined,
                color: Brand.amber),
            tooltip: 'Wallet',
            onPressed: () => _requireSignIn(() => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const WalletScreen()))),
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
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                markers: _markers,
                onMapCreated: (c) => _map = c,
                onTap: (_) => setState(() {
                  _selected = null;
                  _selectedDiscovered = null;
                }),
              ),

              // ---- list panel (over the map, under the chips) ----
              if (_showList)
                Positioned.fill(
                  child: PointerInterceptor(
                    child: Container(
                      color: Colors.white,
                      padding: EdgeInsets.only(
                          top: MediaQuery.of(context).padding.top + 96),
                      child: _listEntries.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text('No $_noun match these filters.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                              color:
                                                  Colors.grey.shade600)),
                                      const SizedBox(height: 14),
                                      OutlinedButton.icon(
                                          onPressed: () {
                                            setState(
                                                () => _showList = false);
                                            _searchThisArea();
                                          },
                                          icon: const Icon(
                                              Icons.coffee_outlined,
                                              size: 18),
                                          label: const Text(
                                              'Search this area for cafes')),
                                    ]),
                              ))
                          : ListView.builder(
                              padding:
                                  const EdgeInsets.fromLTRB(12, 0, 12, 90),
                              itemCount: _listEntries.length,
                              itemBuilder: (_, i) {
                                final e = _listEntries[i];
                                if (e is Venue) {
                                  return _VenueListCard(
                                    venue: e,
                                    onDetails: () => _openDetail(e),
                                    onConfirm: () =>
                                        _openAddVenue(confirming: e),
                                  );
                                }
                                final d = e as DiscoveredPlace;
                                return _DiscoveredListCard(
                                  place: d,
                                  places: _places,
                                  distanceM: _userLat == null
                                      ? null
                                      : Venue.haversineM(_userLat!,
                                          _userLng!, d.lat, d.lng),
                                  onScreen: () => _openScreening(d),
                                );
                              },
                            ),
                    ),
                  ),
                ),

              // ---- filter chips + count ----
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: PointerInterceptor(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            padding:
                                const EdgeInsets.fromLTRB(12, 10, 12, 2),
                            child: Row(children: [
                              _toggleListChip(),
                              _typeChip('Cafes', 'cafe'),
                              _typeChip('Coworking', 'coworking'),
                              _chip('Open now', VenueFilter.openNow),
                              _chip('Open late', VenueFilter.openLate),
                              _chip('24 hours', VenueFilter.open24h),
                              _chip('Work-friendly',
                                  VenueFilter.workFriendly),
                              _jumpChip(),
                            ]),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets.only(left: 16, top: 2),
                            child: _countBadge(visible.length),
                          ),
                          // "Search this area" sits under the chips,
                          // centred — like Google Maps.
                          if (!_showList)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Center(child: _searchAreaPill()),
                            ),
                        ]),
                  ),
                ),
              ),

              // ---- legend (doubles as pin-colour filter) ----
              Positioned(
                left: 12,
                bottom: 24,
                child: PointerInterceptor(child: _legend()),
              ),

              // ---- locate me (map mode only) ----
              if (!_showList)
                Positioned(
                  right: 14,
                  bottom: _selected == null && _selectedDiscovered == null
                      ? 24
                      : 210,
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

              if (_selected != null && !_showList)
                Positioned(
                    left: 12,
                    right: 12,
                    bottom: 24,
                    child: PointerInterceptor(
                        child: _VenueCard(
                            venue: _selected!,
                            onDetails: () => _openDetail(_selected!)))),

              if (_selectedDiscovered != null && !_showList)
                Positioned(
                    left: 12,
                    right: 12,
                    bottom: 24,
                    child: PointerInterceptor(
                        child: _DiscoveredCard(
                            place: _selectedDiscovered!,
                            places: _places,
                            onScreen: () =>
                                _openScreening(_selectedDiscovered!)))),
            ]),
    );
  }

  // ---------- chips & badges ----------

  Widget _toggleListChip() {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        avatar: Icon(_showList ? Icons.map_outlined : Icons.list,
            size: 18, color: Colors.white),
        label: Text(_showList ? 'Map' : 'List',
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w700)),
        selected: true,
        showCheckmark: false,
        selectedColor: Brand.charcoal,
        elevation: 3,
        onSelected: (_) => setState(() {
          _showList = !_showList;
          _selected = null;
        }),
      ),
    );
  }

  Widget _typeChip(String label, String type) {
    final on = _typeFilter == type;
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
          _typeFilter = on ? null : type;
          if (_selected != null && !_visibleVenues.contains(_selected)) {
            _selected = null;
          }
        }),
      ),
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

  Widget _jumpChip() {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        avatar: const Icon(Icons.travel_explore,
            size: 18, color: Brand.charcoal),
        label: const Text('Jump to…',
            style: TextStyle(
                color: Brand.charcoal, fontWeight: FontWeight.w500)),
        selected: false,
        showCheckmark: false,
        elevation: 3,
        onSelected: (_) => _openJumpToCity(),
      ),
    );
  }

  Widget _searchAreaPill() {
    return Material(
      color: Colors.white,
      elevation: 4,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: _searchThisArea,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _searchingArea
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Brand.red))
                : const Icon(Icons.coffee_outlined,
                    size: 16, color: Brand.red),
            const SizedBox(width: 7),
            Text(_searchingArea ? 'Searching…' : 'Search this area',
                style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: Brand.charcoal)),
          ]),
        ),
      ),
    );
  }

  Widget _unscreenedLegendRow() {
    final on = _showUnscreened;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() {
        if (on && _wfVisible.isEmpty) return; // never hide everything
        _showUnscreened = !_showUnscreened;
        if (!_showUnscreened) _selectedDiscovered = null;
      }),
      onDoubleTap: () => setState(() {
        // Solo: only unscreened places.
        _wfVisible.clear();
        _showUnscreened = true;
        _selected = null;
      }),
      child: Opacity(
        opacity: on ? 1 : .35,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(on ? Icons.location_on : Icons.location_off,
                size: 16, color: const Color(0xFFC7CDD4)),
            const SizedBox(width: 5),
            Text('Unscreened · review & earn',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    decoration: on
                        ? TextDecoration.none
                        : TextDecoration.lineThrough)),
          ]),
        ),
      ),
    );
  }

  Widget _countBadge(int shown) {
    if (!_anyFilterOn && !_showList) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
          color: Brand.charcoal.withValues(alpha: .85),
          borderRadius: BorderRadius.circular(12)),
      child: Text(
        [
          _anyFilterOn
              ? '$shown of ${_venues.length} $_noun shown'
              : '${_venues.length} $_noun',
          if (_visibleDiscovered.isNotEmpty)
            '${_visibleDiscovered.length} unscreened',
        ].join(' · '),
        style: const TextStyle(
            color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _legend() {
    // Total categories currently visible (3 pin colours + unscreened).
    int visibleCategories() =>
        _wfVisible.length + (_showUnscreened ? 1 : 0);

    Widget row(Color color, String label, WorkFriendly wf) {
      final on = _wfVisible.contains(wf);
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() {
          if (on) {
            // Never allow hiding everything.
            if (visibleCategories() > 1) _wfVisible.remove(wf);
          } else {
            _wfVisible.add(wf);
          }
          if (_selected != null && !_visibleVenues.contains(_selected)) {
            _selected = null;
          }
        }),
        onDoubleTap: () => setState(() {
          // Solo: show only this category.
          _wfVisible
            ..clear()
            ..add(wf);
          _showUnscreened = false;
          _selectedDiscovered = null;
          if (_selected != null && !_visibleVenues.contains(_selected)) {
            _selected = null;
          }
        }),
        child: Opacity(
          opacity: on ? 1 : .35,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(on ? Icons.location_on : Icons.location_off,
                  size: 16, color: color),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      decoration: on
                          ? TextDecoration.none
                          : TextDecoration.lineThrough)),
            ]),
          ),
        ),
      );
    }

    final pinsHidden = _wfVisible.length < WorkFriendly.values.length ||
        !_showUnscreened;

    // Collapsed: a small round button that opens the legend.
    if (!_legendOpen) {
      return Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 4,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => setState(() => _legendOpen = true),
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Stack(clipBehavior: Clip.none, children: [
              const Icon(Icons.layers_outlined,
                  color: Brand.charcoal, size: 22),
              if (pinsHidden)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: const BoxDecoration(
                        color: Brand.red, shape: BoxShape.circle),
                  ),
                ),
            ]),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .96),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: .12), blurRadius: 8)
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('PINS · tap to filter',
              style: TextStyle(
                  fontSize: 9,
                  letterSpacing: .5,
                  fontWeight: FontWeight.w700,
                  color: Colors.grey.shade500)),
          const SizedBox(width: 12),
          InkWell(
            onTap: () => setState(() => _legendOpen = false),
            child: Icon(Icons.close,
                size: 15, color: Colors.grey.shade500),
          ),
        ]),
        const SizedBox(height: 3),
        row(Brand.red, 'Work-friendly', WorkFriendly.yes),
        row(const Color(0xFF4A5561), 'Not for laptops', WorkFriendly.no),
        row(Brand.amber, 'Unknown · confirm & earn', WorkFriendly.unknown),
        _unscreenedLegendRow(),
        if (pinsHidden)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() {
              _wfVisible
                ..clear()
                ..addAll(WorkFriendly.values);
              _showUnscreened = true;
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  vertical: 5, horizontal: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: const [
                Icon(Icons.refresh, size: 14, color: Brand.red),
                SizedBox(width: 5),
                Text('Show all pins',
                    style: TextStyle(
                        fontSize: 11,
                        color: Brand.red,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 2, left: 2),
          child: Text('double-tap a row to show only that type',
              style:
                  TextStyle(fontSize: 9, color: Colors.grey.shade500)),
        ),
      ]),
    );
  }
}

// ============================================================
// Venue search (by name)
// ============================================================

class _VenueSearchDelegate extends SearchDelegate<Venue?> {
  final List<Venue> venues;
  _VenueSearchDelegate(this.venues)
      : super(searchFieldLabel: 'Search venues…');

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
              icon: const Icon(Icons.clear), onPressed: () => query = '')
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, null));

  Widget _resultList(BuildContext context) {
    final q = query.trim().toLowerCase();
    final matches = venues
        .where((v) =>
            v.name.toLowerCase().contains(q) ||
            (v.neighbourhood ?? '').toLowerCase().contains(q))
        .toList();
    if (matches.isEmpty) {
      return Center(
          child: Text('No venues found for "$query"',
              style: TextStyle(color: Colors.grey.shade600)));
    }
    return ListView(
      children: matches
          .map((v) => ListTile(
                leading: Icon(Icons.location_on,
                    color: switch (v.workFriendly) {
                      WorkFriendly.yes => Brand.red,
                      WorkFriendly.no => const Color(0xFF9AA3AD),
                      WorkFriendly.unknown => Brand.amber,
                    }),
                title: Text(v.name),
                subtitle: Text([
                  if (v.neighbourhood != null) v.neighbourhood!,
                  if (v.distanceM != null) v.distanceLabel(),
                ].join(' · ')),
                trailing: v.rating != null
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.star,
                            color: Brand.amber, size: 16),
                        Text(' ${v.rating}')
                      ])
                    : null,
                onTap: () => close(context, v),
              ))
          .toList(),
    );
  }

  @override
  Widget buildResults(BuildContext context) => _resultList(context);

  @override
  Widget buildSuggestions(BuildContext context) => query.isEmpty
      ? Center(
          child: Text('Type a venue name…',
              style: TextStyle(color: Colors.grey.shade500)))
      : _resultList(context);
}

// ============================================================
// Jump-to-city bottom sheet
// ============================================================

class _JumpToCitySheet extends StatefulWidget {
  final PlacesService places;
  final List<String> citiesWithSpaces;
  const _JumpToCitySheet(
      {required this.places, required this.citiesWithSpaces});

  @override
  State<_JumpToCitySheet> createState() => _JumpToCitySheetState();
}

class _JumpToCitySheetState extends State<_JumpToCitySheet> {
  List<PlaceSuggestion> _suggestions = [];
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final res = await widget.places
          .autocomplete(text, types: ['locality']);
      if (mounted) setState(() => _suggestions = res);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Jump to a city',
                style:
                    TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 12),
            if (widget.citiesWithSpaces.isNotEmpty) ...[
              Text('Cities with Spaces',
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: widget.citiesWithSpaces
                    .map((c) => ActionChip(
                          avatar: const Icon(Icons.location_city,
                              size: 16, color: Brand.red),
                          label: Text(c),
                          onPressed: () =>
                              Navigator.pop(context, 'venue-city:$c'),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 14),
            ],
            TextField(
              autofocus: true,
              onChanged: _onChanged,
              decoration: const InputDecoration(
                  labelText: 'Search any city…',
                  prefixIcon: Icon(Icons.search)),
            ),
            ..._suggestions.take(5).map((s) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.location_city,
                      color: Brand.charcoal, size: 20),
                  title: Text(s.main),
                  subtitle: s.secondary.isEmpty ? null : Text(s.secondary),
                  onTap: () => Navigator.pop(context, s.placeId),
                )),
            const SizedBox(height: 6),
          ]),
    );
  }
}

// ============================================================
// List-view card ("window shopping")
// ============================================================

class _VenueListCard extends StatelessWidget {
  final Venue venue;
  final VoidCallback onDetails;
  final VoidCallback onConfirm;
  const _VenueListCard(
      {required this.venue,
      required this.onDetails,
      required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    final closing =
        venue.closingLabel(soonMinutes: AppConfig.closingSoonMinutes);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 1.5,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.shade200)),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context)
            .copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          leading: Icon(Icons.location_on,
              size: 30,
              color: switch (venue.workFriendly) {
                WorkFriendly.yes => Brand.red,
                WorkFriendly.no => const Color(0xFF9AA3AD),
                WorkFriendly.unknown => Brand.amber,
              }),
          title: Text(venue.name,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(venue.distanceLabel(),
                      style:
                          const TextStyle(fontWeight: FontWeight.w500)),
                  if (venue.rating != null)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.star,
                          color: Brand.amber, size: 15),
                      Text(' ${venue.rating}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700)),
                    ]),
                  if (closing != null)
                    Text(closing,
                        style: TextStyle(
                            fontSize: 12,
                            color: closing.startsWith('Closing') ||
                                    closing == 'Closed'
                                ? Brand.red
                                : Colors.green.shade700)),
                ]),
          ),
          children: [
            _featureWrap(),
            if (venue.unansweredCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  const Icon(Icons.monetization_on,
                      color: Brand.amber, size: 16),
                  const SizedBox(width: 5),
                  Text(
                    '${venue.unansweredCount} unanswered · earn ${AppConfig.coinsConfirmVenue} coins',
                    style: const TextStyle(
                        fontSize: 12,
                        color: Brand.charcoal,
                        fontWeight: FontWeight.w500),
                  ),
                ]),
              ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: onDetails,
                    child: const Text('Full details')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                    onPressed: onConfirm,
                    child: Text(
                        'Confirm · +${AppConfig.coinsConfirmVenue}')),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _featureWrap() {
    Widget chip(String label, bool? v) {
      final (color, icon) = switch (v) {
        true => (Colors.green.shade600, Icons.check),
        false => (Brand.red, Icons.close),
        null => (Colors.grey.shade400, Icons.help_outline),
      };
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
            color: color.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(fontSize: 11, color: Brand.charcoal)),
        ]),
      );
    }

    return Wrap(spacing: 6, runSpacing: 6, children: [
      chip('Laptops', venue.laptopsAllowed),
      chip(
          venue.wifiSpeedMbps != null
              ? 'Wifi ${venue.wifiSpeedMbps} Mbps'
              : 'Wifi ?',
          venue.wifiSpeedMbps != null ? true : null),
      chip('Power', venue.powerOutlets),
      chip('Aircon', venue.aircon),
      chip('Seating', venue.comfortableSeating),
      chip('Cozy', venue.cozy),
      chip('Quiet', venue.quietSpace),
    ]);
  }
}

// ============================================================
// List-view row for an unscreened place
// ============================================================

class _DiscoveredListCard extends StatefulWidget {
  final DiscoveredPlace place;
  final PlacesService places;
  final double? distanceM;
  final VoidCallback onScreen;
  const _DiscoveredListCard(
      {required this.place,
      required this.places,
      this.distanceM,
      required this.onScreen});

  @override
  State<_DiscoveredListCard> createState() => _DiscoveredListCardState();
}

class _DiscoveredListCardState extends State<_DiscoveredListCard> {
  Map<String, int>? _signals;
  List<String> _photos = [];
  bool _loaded = false;

  DiscoveredPlace get place => widget.place;

  String get _distLabel {
    final d = widget.distanceM;
    if (d == null) return '';
    if (d < 1000) return '${d.round()} m';
    return '${(d / 1000).toStringAsFixed(1)} km';
  }

  Future<void> _loadEvidence() async {
    if (_loaded) return;
    _loaded = true;
    final live = await widget.places.details(place.placeId);
    final signals = await widget.places.nomadSignals(place.placeId);
    if (mounted) {
      setState(() {
        _photos = (live?.photoNames ?? [])
            .take(4)
            .map((n) => PlacesService.photoUrl(n, maxWidth: 400))
            .toList();
        _signals = signals;
      });
    }
  }

  Future<void> _openOnGoogle() async {
    final url = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query='
        '${Uri.encodeComponent(place.name)}&query_place_id=${place.placeId}');
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final s = _signals;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 1.5,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.shade200)),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data:
            Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          onExpansionChanged: (open) {
            if (open) _loadEvidence();
          },
          tilePadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          leading: const Icon(Icons.location_on,
              size: 30, color: Color(0xFFC7CDD4)),
          title: Text(place.name,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (_distLabel.isNotEmpty)
                    Text(_distLabel,
                        style: const TextStyle(
                            fontWeight: FontWeight.w500, fontSize: 13)),
                  if (place.rating != null)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.star,
                          color: Brand.amber, size: 14),
                      Text(' ${place.rating}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13)),
                    ]),
                  Text('Unscreened',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500)),
                ]),
          ),
          children: [
            // ---- evidence: photos + review signals ----
            if (_photos.isNotEmpty) ...[
              SizedBox(
                height: 70,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _photos.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, i) => ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(_photos[i],
                        width: 94,
                        height: 70,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const SizedBox(width: 94)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (s == null)
              Row(children: [
                const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: Brand.amber)),
                const SizedBox(width: 8),
                Text('Checking reviews for nomad signals…',
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade600)),
              ])
            else if (s.isEmpty)
              Text('No wifi/laptop mentions in its Google reviews yet.',
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade600))
            else
              Text(
                'Reviews mention: '
                '${s.entries.map((e) => '${e.key} ×${e.value}').join(' · ')}',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600),
              ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                    onPressed: _openOnGoogle,
                    icon: const Icon(Icons.map_outlined, size: 17),
                    label: const Text('View on Google')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                    onPressed: widget.onScreen,
                    child: Text(
                        'Screen it · +${AppConfig.coinsNewVenue}')),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// Card for an unscreened (Google-discovered) place
// ============================================================

class _DiscoveredCard extends StatefulWidget {
  final DiscoveredPlace place;
  final PlacesService places;
  final VoidCallback onScreen;
  const _DiscoveredCard(
      {required this.place, required this.places, required this.onScreen});

  @override
  State<_DiscoveredCard> createState() => _DiscoveredCardState();
}

class _DiscoveredCardState extends State<_DiscoveredCard> {
  Map<String, int>? _signals;

  DiscoveredPlace get place => widget.place;

  @override
  void initState() {
    super.initState();
    _loadSignals();
  }

  @override
  void didUpdateWidget(covariant _DiscoveredCard old) {
    super.didUpdateWidget(old);
    if (old.place.placeId != place.placeId) {
      _signals = null;
      _loadSignals();
    }
  }

  Future<void> _loadSignals() async {
    final s = await widget.places.nomadSignals(place.placeId);
    if (mounted) setState(() => _signals = s);
  }

  Widget _signalsRow() {
    final s = _signals;
    if (s == null) {
      return Row(children: [
        const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
                strokeWidth: 1.5, color: Brand.amber)),
        const SizedBox(width: 8),
        Text('Checking reviews for nomad signals…',
            style:
                TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      ]);
    }
    if (s.isEmpty) {
      return Text('No wifi/laptop mentions found in its reviews. '
          'Be the first to find out!',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600));
    }
    Widget chip(IconData icon, String label) => Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: Brand.amber.withValues(alpha: .15),
              borderRadius: BorderRadius.circular(10)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 13, color: Brand.charcoal),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Promising! Reviews mention:',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      const SizedBox(height: 5),
      Wrap(spacing: 6, runSpacing: 4, children: [
        if (s['wifi'] != null) chip(Icons.wifi, 'wifi ×${s['wifi']}'),
        if (s['power'] != null)
          chip(Icons.power, 'plugs ×${s['power']}'),
        if (s['laptop'] != null)
          chip(Icons.laptop_mac, 'laptops ×${s['laptop']}'),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 6,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(
                child: Text(place.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 17))),
            if (place.rating != null) ...[
              const Icon(Icons.star, color: Brand.amber, size: 18),
              Text(' ${place.rating}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              if (place.userRatingCount != null)
                Text(' (${place.userRatingCount})',
                    style: TextStyle(
                        color: Colors.grey.shade600, fontSize: 12)),
            ],
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                  color: Colors.blueGrey.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(20)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.help_outline, size: 15, color: Colors.blueGrey),
                SizedBox(width: 5),
                Text('Not screened by nomads yet',
                    style: TextStyle(
                        color: Colors.blueGrey,
                        fontWeight: FontWeight.w700,
                        fontSize: 12)),
              ]),
            ),
            const Spacer(),
          ]),
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerLeft, child: _signalsRow()),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: widget.onScreen,
              icon: const Icon(Icons.rate_review_outlined, size: 19),
              label: Text(
                  'Screen this space  ·  earn ${AppConfig.coinsNewVenue} coins'),
            ),
          ),
        ]),
      ),
    );
  }
}

// ============================================================
// Compact card shown when a pin is tapped (map mode)
// ============================================================

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
          'Unknown · confirm & earn',
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
