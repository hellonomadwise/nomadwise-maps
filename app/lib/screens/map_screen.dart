import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent;
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/discovered_place.dart';
import '../models/venue.dart';
import '../services/analytics_service.dart';
import '../services/location_service.dart';
import '../services/places_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'add_venue_screen.dart';
import 'admin_screen.dart';
import 'admin_analytics_screen.dart';
import 'admin_users_screen.dart';
import 'feedback_inbox_screen.dart';
import 'intro_overlay.dart';
import 'auth_screen.dart';
import 'leaderboard_screen.dart';
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
  // Pin-colour selection: empty = show everything; tapping a legend row
  // SELECTS that colour (shows only the selected ones).
  final Set<String> _pinFilter = {};
  bool _legendOpen = false;
  LatLngBounds? _mapBounds;

  bool _catVisible(String cat) =>
      _pinFilter.isEmpty || _pinFilter.contains(cat);

  bool _inBounds(double lat, double lng) {
    final b = _mapBounds;
    if (b == null) return true;
    final latOk =
        lat >= b.southwest.latitude && lat <= b.northeast.latitude;
    final lngOk = b.southwest.longitude <= b.northeast.longitude
        ? (lng >= b.southwest.longitude && lng <= b.northeast.longitude)
        : (lng >= b.southwest.longitude || lng <= b.northeast.longitude);
    return latOk && lngOk;
  }

  static String _wfKey(WorkFriendly wf) => switch (wf) {
        WorkFriendly.yes => 'yes',
        WorkFriendly.no => 'no',
        WorkFriendly.unknown => 'unknown',
      };
  bool _showList = false;
  Venue? _selected;
  DiscoveredPlace? _selectedDiscovered;
  List<DiscoveredPlace> _discovered = [];
  bool _searchingArea = false;
  double? _userLat, _userLng;
  bool _loading = true;
  bool _isAdmin = false;

  BitmapDescriptor? _pinYes, _pinNo, _pinUnknown, _pinUnscreened, _pinMe;
  BitmapDescriptor? _pinPromising;
  bool _hasRealLocation = false;

  String? _displayName;
  String? _avatarUrl;

  int? _walletTotal;
  int _pendingCount = 0;

  Future<void> _loadProfileBits() async {
    final p = await _supabase.myProfile();
    if (mounted && p != null) {
      setState(() {
        _displayName ??= p['display_name'];
        _avatarUrl = p['avatar_url'];
      });
    }
    final w = await _supabase.wallet();
    if (mounted) setState(() => _walletTotal = w.total);
  }

  Future<void> _changeAvatar() async {
    try {
      XFile? img;
      try {
        img = await ImagePicker().pickImage(
            source: ImageSource.gallery, maxWidth: 512, imageQuality: 80);
      } catch (_) {
        // Shrinking can fail on some browsers (odd formats, huge photos).
        // Take the photo exactly as it is instead.
        img = await ImagePicker().pickImage(source: ImageSource.gallery);
      }
      if (img == null) return;
      final bytes = await img.readAsBytes();

      // What format did the phone actually hand over?
      final kind = _imageKind(bytes);
      if (kind == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              duration: Duration(seconds: 5),
              content: Text(
                  'That photo is in a format other phones can\'t show '
                  '(often iPhone HEIC). Try a different photo, or a '
                  'screenshot of it.')));
        }
        return;
      }

      final url = await _supabase.uploadAvatar(bytes,
          ext: kind.$1, contentType: kind.$2);
      if (mounted && url != null) {
        setState(() => _avatarUrl = url);
        Analytics.capture('avatar_updated');
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            duration: Duration(seconds: 2),
            content: Text('Looking good! Profile photo updated.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Couldn\'t update the photo. Please try another one.')));
      }
    }
  }

  /// (extension, mime type) read from the file's first bytes,
  /// or null when it's a format browsers can't display (e.g. HEIC).
  static (String, String)? _imageKind(Uint8List b) {
    if (b.length > 2 && b[0] == 0xFF && b[1] == 0xD8) {
      return ('jpg', 'image/jpeg');
    }
    if (b.length > 4 &&
        b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return ('png', 'image/png');
    }
    if (b.length > 12 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return ('webp', 'image/webp');
    }
    if (b.length > 3 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      return ('gif', 'image/gif');
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _boot();
    _checkAdmin();
    Analytics.capture('app_opened');
    // The intro cards no longer auto-show on first visit (too much
    // friction) — they live under "How it works" in the menu instead.
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
    _loadProfileBits();
    await Analytics.identify(userId, email: email, name: name);
    await Analytics.capture('signed_in');
    // Discoveries made before signing in become theirs now.
    final claimed = await _supabase.claimAnonDiscoveries();
    if (claimed > 0 && mounted) {
      Analytics.capture('anon_finds_claimed', {'count': claimed});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 5),
          content: Text(
              'The $claimed space${claimed == 1 ? '' : 's'} you '
              'discovered ${claimed == 1 ? 'is' : 'are'} now yours: '
              '+${AppConfig.coinsDiscovery} each when they get '
              'screened.')));
    }
  }

  Future<void> _checkAdmin() async {
    final admin = await _supabase.isAdmin();
    if (mounted && admin != _isAdmin) setState(() => _isAdmin = admin);
    if (_displayName == null || _avatarUrl == null) _loadProfileBits();
    if (admin) {
      try {
        final pending = await _supabase.pendingSubmissions();
        if (mounted) setState(() => _pendingCount = pending.length);
      } catch (_) {}
    }
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

  double _initZoom = 14;

  Future<void> _boot() async {
    await _loadPinIcons();

    // Where should the map open? Priority: where they last left it,
    // then a rough guess from their internet connection, then a
    // neutral world view. Never a hardcoded city.
    var haveStart = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('last_cam');
      if (saved != null) {
        final p = saved.split(',');
        _userLat = double.tryParse(p[0]);
        _userLng = double.tryParse(p[1]);
        _initZoom = double.tryParse(p[2]) ?? 13;
        haveStart = _userLat != null && _userLng != null;
      }
    } catch (_) {}
    if (!haveStart) {
      // World view while the guesses come in.
      _userLat = 20;
      _userLng = 0;
      _initZoom = 2.5;
      // City-level guess from the connection, no permission needed.
      LocationService.ipLocate().then((ip) {
        if (ip != null && !_hasRealLocation && mounted) {
          _userLat = ip.$1;
          _userLng = ip.$2;
          _computeDistances();
          setState(() {});
          _map?.animateCamera(CameraUpdate.newLatLngZoom(
              LatLng(ip.$1, ip.$2), 11));
        }
      });
    }

    // Instant start: show venues remembered from the last visit while the
    // fresh data and the user's location load in the background.
    final cached = await _supabase.cachedVenues();
    if (cached.isNotEmpty && mounted && _loading) {
      _venues = cached;
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
      // Fly to the person, wherever the map was pointing before.
      _map?.animateCamera(CameraUpdate.newLatLngZoom(
          LatLng(pos.latitude, pos.longitude), 14));
    }
    _computeDistances();
    if (mounted) setState(() => _loading = false);

    await _places.enrich(_venues);
    _computeDistances();
    if (mounted) setState(() {});
  }

  /// Remember where the map is pointing so next open starts there.
  Future<void> _saveCamera(LatLngBounds b) async {
    try {
      final z = await _map?.getZoomLevel();
      final lat =
          (b.southwest.latitude + b.northeast.latitude) / 2;
      final lng =
          (b.southwest.longitude + b.northeast.longitude) / 2;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_cam',
          '$lat,$lng,${(z ?? 13).toStringAsFixed(1)}');
    } catch (_) {}
  }

  Future<void> _loadPinIcons() async {
    // Square size = no stretching; ~30 logical px reads like Google's own.
    const cfg = ImageConfiguration(size: Size(30, 30));
    _pinYes = await BitmapDescriptor.asset(cfg, 'assets/pins/pin_yes.png');
    _pinNo = await BitmapDescriptor.asset(cfg, 'assets/pins/pin_no.png');
    _pinUnknown =
        await BitmapDescriptor.asset(cfg, 'assets/pins/pin_unknown.png');
    _pinUnscreened = await BitmapDescriptor.asset(
        cfg, 'assets/pins/pin_unscreened.png');
    _pinPromising = await BitmapDescriptor.asset(
        cfg, 'assets/pins/pin_unscreened_promising.png');
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
      var newFinds = 0;
      if (cached.length < 5) {
        final radius = Venue.haversineM(
                cLat, cLng,
                bounds.northeast.latitude, bounds.northeast.longitude)
            .clamp(300.0, 5000.0);
        final fresh = await _places.searchNearby(cLat, cLng, radius);
        final known = _discovered.map((d) => d.placeId).toSet()
          ..addAll(cached.map((d) => d.placeId));
        newFinds =
            fresh.where((d) => !known.contains(d.placeId)).length;
        await _supabase.cacheDiscovered(fresh);
        _mergeDiscovered(fresh);
      }
      Analytics.capture('area_searched',
          {'found': _visibleDiscovered.length, 'new': newFinds});
      if (mounted) {
        final n = _visibleDiscovered.length;
        if (newFinds > 0) {
          _showDiscoveryPopup(
              count: newFinds, signedIn: _supabase.signedIn);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              duration: const Duration(seconds: 2),
              content: Text(n == 0
                  ? 'No unscreened cafes found here yet.'
                  : '$n unscreened cafes here. Screen one & earn '
                      '${AppConfig.coinsNewVenue} coins!')));
        }
      }
    } finally {
      if (mounted) setState(() => _searchingArea = false);
    }
  }

  bool _loadingDiscovered = false;

  /// Quietly pull already-discovered spaces for the visible area, so
  /// past searches stay on the map for every visitor (signed in or not).
  Future<void> _loadDiscoveredHere(LatLngBounds b) async {
    final latSpan =
        b.northeast.latitude - b.southwest.latitude;
    // Zoomed way out = too much world; wait until they zoom in.
    if (latSpan > 1.0 || _loadingDiscovered) return;
    _loadingDiscovered = true;
    try {
      final cached = await _supabase.discoveredInBounds(
          b.southwest.latitude,
          b.northeast.latitude,
          b.southwest.longitude,
          b.northeast.longitude);
      if (cached.isNotEmpty) _mergeDiscovered(cached);
    } finally {
      _loadingDiscovered = false;
    }
  }

  /// Centre-screen celebration when a search reveals new spaces.
  /// Closes on the X, on a tap anywhere outside, or by itself after 5s.
  void _showDiscoveryPopup(
      {required int count, required bool signedIn}) {
    var closed = false;
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .35),
      builder: (ctx) {
        void close() {
          if (!closed) {
            closed = true;
            Navigator.of(ctx).pop();
          }
        }

        Timer(const Duration(seconds: 5), () {
          if (!closed && ctx.mounted) close();
        });

        return Stack(children: [
          // Full-screen catcher so tapping anywhere (even over the
          // map) dismisses it.
          Positioned.fill(
            child: PointerInterceptor(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: close,
                child: const SizedBox.expand(),
              ),
            ),
          ),
          Center(
            child: PointerInterceptor(
              child: Material(
                color: Colors.transparent,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 32),
                  constraints: const BoxConstraints(maxWidth: 340),
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                  decoration: BoxDecoration(
                    color: Brand.surface,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: Brand.shadowSheet,
                  ),
                  child: Stack(clipBehavior: Clip.none, children: [
                    Column(mainAxisSize: MainAxisSize.min, children: [
                      const SizedBox(height: 6),
                      const CoinDot(size: 46),
                      const SizedBox(height: 14),
                      Text(
                          'You discovered $count new '
                          'space${count == 1 ? '' : 's'}!',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(
                          signedIn
                              ? '+${AppConfig.coinsDiscovery} coins for '
                                  'each one once another nomad screens it.'
                              : 'Sign in to claim '
                                  '+${AppConfig.coinsDiscovery} coins for '
                                  'each once they get screened.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 13.5,
                              height: 1.5,
                              color: Brand.inkSecondary)),
                      if (!signedIn) ...[
                        const SizedBox(height: 16),
                        PrimaryCta(
                          label: 'Sign in to claim',
                          onPressed: () {
                            close();
                            Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const AuthScreen()));
                          },
                        ),
                      ],
                    ]),
                    Positioned(
                      right: -10,
                      top: -8,
                      child: IconButton(
                        icon: const Icon(Icons.close,
                            size: 20, color: Brand.inkMuted),
                        onPressed: close,
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ]);
      },
    ).then((_) => closed = true);
  }

  void _mergeDiscovered(List<DiscoveredPlace> more) {
    final have = _discovered.map((d) => d.placeId).toSet();
    _discovered = [
      ..._discovered,
      ...more.where((d) => !have.contains(d.placeId)),
    ];
    if (mounted) setState(() {});
  }

  /// Discovered places not yet on our map as venues. Promising ones
  /// (reviews mention wifi/laptops) filter as their own category.
  List<DiscoveredPlace> get _visibleDiscovered {
    final venuePlaceIds =
        _venues.map((v) => v.googlePlaceId).whereType<String>().toSet();
    return _discovered
        .where((d) =>
            !venuePlaceIds.contains(d.placeId) &&
            _catVisible(d.promising ? 'promising' : 'unscreened'))
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
      _filters.isNotEmpty || _typeFilter != null || _pinFilter.isNotEmpty;

  List<Venue> get _visibleVenues => _venues.where((v) {
        if (v.lat == null || v.lng == null) return false;
        if (!_catVisible(_wfKey(v.workFriendly))) return false;
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
              onTap: () {
                setState(() {
                  _selected = v;
                  _selectedDiscovered = null;
                });
                _recenterOn(v.lat!, v.lng!);
              },
            )),
        ..._visibleDiscovered.map((d) => Marker(
              markerId: MarkerId('disc-${d.placeId}'),
              position: LatLng(d.lat, d.lng),
              // Solid violet = reviews mention wifi/plugs/laptops;
              // outline violet = nothing known yet.
              icon: (d.promising ? _pinPromising : _pinUnscreened) ??
                  BitmapDescriptor.defaultMarkerWithHue(200),
              alpha: 0.92,
              onTap: () {
                setState(() {
                  _selectedDiscovered = d;
                  _selected = null;
                });
                _recenterOn(d.lat, d.lng);
              },
            )),
      };

  bool get _wideScreen => MediaQuery.of(context).size.width > 900;

  /// Centre the map on the tapped pin. On wide screens the details
  /// panel covers the right side, so aim slightly east: the pin then
  /// sits centred in the visible left part.
  void _recenterOn(double lat, double lng) {
    var targetLng = lng;
    final b = _mapBounds;
    if (_wideScreen && b != null) {
      final span =
          b.northeast.longitude - b.southwest.longitude;
      if (span > 0 && span < 90) targetLng = lng + span * .19;
    }
    _map?.animateCamera(
        CameraUpdate.newLatLng(LatLng(lat, targetLng)));
  }

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

  // ---------- global space search ----------

  Future<void> _openSearch() async {
    // Instant (no-animation) route: the phone keyboard only opens
    // automatically when focus lands during the tap itself, and a
    // page transition breaks that timing on iOS.
    final result = await Navigator.push<Object?>(
      context,
      PageRouteBuilder(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, __, ___) => _SpaceSearchScreen(
            venues: _venues,
            places: _places,
            nearLat: _userLat,
            nearLng: _userLng),
      ),
    );
    if (result == null || !mounted) return;

    if (result is Venue && result.lat != null) {
      setState(() {
        _showList = false;
        _selected = result;
        _selectedDiscovered = null;
      });
      _map?.animateCamera(CameraUpdate.newLatLngZoom(
          LatLng(result.lat!, result.lng!), 16));
      return;
    }

    if (result is PlaceSuggestion) {
      Analytics.capture('global_search_used', {'query': result.main});
      // Already one of our Spaces?
      final existing = _venues
          .where((v) => v.googlePlaceId == result.placeId)
          .firstOrNull;
      if (existing != null && existing.lat != null) {
        setState(() {
          _showList = false;
          _selected = existing;
          _selectedDiscovered = null;
        });
        _map?.animateCamera(CameraUpdate.newLatLngZoom(
            LatLng(existing.lat!, existing.lng!), 16));
        return;
      }
      // A new place from Google: fly there, ready to screen.
      final live = await _places.details(result.placeId);
      if (live?.lat == null || !mounted) return;
      final d = DiscoveredPlace(
        placeId: result.placeId,
        name: live?.displayName ?? result.main,
        lat: live!.lat!,
        lng: live.lng!,
        rating: live.rating,
        userRatingCount: live.userRatingCount,
      );
      _mergeDiscovered([d]);
      _supabase.cacheDiscovered([d]);
      setState(() {
        _showList = false;
        _selectedDiscovered = d;
        _selected = null;
      });
      _map?.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(d.lat, d.lng), 16));
    }
  }

  // ---------- jump to city ----------

  Future<void> _openJumpToCity() async {
    final citiesWithSpaces =
        _venues.map((v) => v.city).whereType<String>().toSet().toList()
          ..sort();
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
      backgroundColor: Brand.surface,
      width: MediaQuery.of(context).size.width * .82,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.only(topRight: Radius.circular(24), bottomRight: Radius.circular(24))),
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (user != null) ...[
                    InkWell(
                      onTap: _changeAvatar,
                      customBorder: const CircleBorder(),
                      child: Stack(clipBehavior: Clip.none, children: [
                        NomadAvatar(
                            name: _displayName ?? user.email,
                            photoUrl: _avatarUrl,
                            radius: 32),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                                color: Brand.ink,
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: Colors.white, width: 2)),
                            child: const Icon(Icons.photo_camera,
                                size: 12, color: Colors.white),
                          ),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 12),
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
                                color: Brand.ink,
                                fontSize: 19,
                                fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 7),
                        const Icon(Icons.edit_outlined,
                            size: 15, color: Brand.inkMuted),
                      ]),
                    ),
                    Text(
                      user.email ?? '',
                      style: const TextStyle(
                          color: Brand.inkMuted, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 14),
                    Material(
                      color: Brand.goldTint,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          Navigator.pop(context);
                          _requireSignIn(() => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      const WalletScreen())));
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          child: Row(children: [
                            const CoinDot(size: 18),
                            const SizedBox(width: 10),
                            Text('${_walletTotal ?? '…'}',
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(width: 5),
                            const Text('coins',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: Brand.inkSecondary)),
                            const Spacer(),
                            const Text('Wallet ›',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Brand.goldLink)),
                          ]),
                        ),
                      ),
                    ),
                  ] else ...[
                    Image.asset('assets/brand/app_icon.png', height: 52),
                    const SizedBox(height: 12),
                    const Text('Not signed in',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    const Text('Sign in to earn coins',
                        style: TextStyle(
                            color: Brand.inkMuted, fontSize: 13)),
                  ],
                ]),
          ),
          const Divider(height: 1, color: Brand.hairline),
          const SizedBox(height: 8),
          _menuRow(
            icon: Icons.emoji_events_outlined,
            label: 'Leaderboard',
            sub: 'Top nomads & live activity',
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const LeaderboardScreen()));
            },
          ),
          _menuRow(
            icon: Icons.rate_review_outlined,
            label: 'Review a space',
            sub: 'Earn up to ${AppConfig.coinsNewVenue} coins',
            accent: true,
            trailing: CoinChip('+${AppConfig.coinsNewVenue}', height: 22),
            onTap: () {
              Navigator.pop(context);
              _openAddVenue();
            },
          ),
          if (_isAdmin) ...[
            _menuRow(
              icon: Icons.fact_check_outlined,
              label: 'Review submissions',
              trailing: _pendingCount > 0
                  ? Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                          color: Brand.accent, shape: BoxShape.circle),
                      child: Text('$_pendingCount',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700)),
                    )
                  : null,
              onTap: () async {
                Navigator.pop(context);
                await Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const AdminScreen()));
                // Back from reviewing: refresh the badge count.
                try {
                  final pending =
                      await _supabase.pendingSubmissions();
                  if (mounted) {
                    setState(() => _pendingCount = pending.length);
                  }
                } catch (_) {}
              },
            ),
            _menuRow(
              icon: Icons.insights_outlined,
              label: 'Analytics',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            const AdminAnalyticsScreen()));
              },
            ),
            _menuRow(
              icon: Icons.inbox_outlined,
              label: 'Feedback inbox',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            const FeedbackInboxScreen()));
              },
            ),
            _menuRow(
              icon: Icons.travel_explore_outlined,
              label: 'Sweep a city',
              sub: 'Pre-discover every cafe in a city',
              onTap: () {
                Navigator.pop(context);
                _openCitySweep();
              },
            ),
            _menuRow(
              icon: Icons.group_outlined,
              label: 'Users',
              trailing: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: Brand.field,
                    borderRadius: BorderRadius.circular(8)),
                child: const Text('ADMIN',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: .5,
                        color: Brand.inkSecondary)),
              ),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const AdminUsersScreen()));
              },
            ),
          ],
          if (kIsWeb)
            _menuRow(
              icon: Icons.add_to_home_screen,
              label: 'Add to Home Screen',
              sub: 'Use it like a real app',
              onTap: () {
                Navigator.pop(context);
                _showAddToHome();
              },
            ),
          _menuRow(
            icon: Icons.chat_bubble_outline,
            label: 'Send feedback',
            sub: 'Ideas, bugs, anything',
            onTap: () {
              Navigator.pop(context);
              _openFeedback();
            },
          ),
          _menuRow(
            icon: Icons.help_outline,
            label: 'How it works',
            onTap: () {
              Navigator.pop(context);
              showIntro(context);
            },
          ),
          const Spacer(),
          const Divider(height: 1, color: Brand.hairline),
          if (user != null)
            ListTile(
              leading: const Icon(Icons.logout, color: Brand.accent),
              title: const Text('Sign out',
                  style: TextStyle(
                      color: Brand.accent,
                      fontWeight: FontWeight.w600)),
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
              leading: const Icon(Icons.login, color: Brand.accent),
              title: const Text('Sign in',
                  style: TextStyle(
                      color: Brand.accent,
                      fontWeight: FontWeight.w600)),
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

  /// Step-by-step guide for pinning the web app to the home screen.
  void _showAddToHome() {
    Analytics.capture('add_to_home_opened');
    final isIOS = Theme.of(context).platform == TargetPlatform.iOS;
    final isAndroid =
        Theme.of(context).platform == TargetPlatform.android;

    Widget step(int n, IconData icon, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                      color: Brand.field, shape: BoxShape.circle),
                  child: Text('$n',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 12),
                Icon(icon, size: 20, color: Brand.ink),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(text,
                      style: const TextStyle(
                          fontSize: 14, height: 1.45)),
                ),
              ]),
        );

    showModalBottomSheet(
      context: context,
      backgroundColor: Brand.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => PointerInterceptor(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 34),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset('assets/brand/app_icon.png',
                        height: 42),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Add Nomad Maps to your Home Screen',
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700)),
                          Text(
                              'Opens full screen with one tap, like a real app.',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: Brand.inkSecondary)),
                        ]),
                  ),
                ]),
                const SizedBox(height: 14),
                if (isIOS) ...[
                  step(1, Icons.ios_share,
                      'Tap the Share button at the bottom of Safari.'),
                  step(2, Icons.add_box_outlined,
                      'Scroll down and tap "Add to Home Screen".'),
                  step(3, Icons.check_circle_outline,
                      'Tap Add. Done, Nomad Maps now lives with your other apps.'),
                  const SizedBox(height: 8),
                  const Text(
                      'Using Chrome or another browser? Open this page in '
                      'Safari first, the option lives there.',
                      style: TextStyle(
                          fontSize: 12, color: Brand.inkMuted)),
                ] else if (isAndroid) ...[
                  step(1, Icons.more_vert,
                      'Tap the three dots menu in the corner of your browser.'),
                  step(2, Icons.add_box_outlined,
                      'Tap "Add to Home screen" or "Install app".'),
                  step(3, Icons.check_circle_outline,
                      'Confirm. Done, Nomad Maps now lives with your other apps.'),
                ] else ...[
                  const Text(
                      'Open nomadmaps.io on '
                      'your phone, then come back to this menu item for '
                      'the steps.',
                      style: TextStyle(fontSize: 14, height: 1.5)),
                ],
              ]),
        ),
      ),
    );
  }

  /// Anyone can send a thought; it lands in the admin's inbox.
  /// Admin: queue a city for the overnight sweep that pre-discovers
  /// every cafe and coworking space in it. The city field offers live
  /// Google suggestions so the right city in the right country is
  /// picked explicitly.
  Future<void> _openCitySweep() async {
    final cityCtrl = TextEditingController();
    final swept = await _supabase.citySweeps();
    final queued = await _supabase.sweepQueue();
    if (!mounted) return;
    final sweptNames = swept
        .map((s) => '${s['city']} (${s['places_found'] ?? '?'} places)')
        .toList();
    final pending = queued
        .where((q) =>
            !swept.any((s) => (s['city'] as String).toLowerCase() ==
                q.toLowerCase()))
        .toList();
    List<PlaceSuggestion> sugg = [];
    String? picked; // qualified "City, Country" chosen from suggestions
    Timer? debounce;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Brand.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => PointerInterceptor(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                24, 22, 24, MediaQuery.of(ctx).viewInsets.bottom + 28),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Sweep a city',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text(
                      'The overnight job discovers every cafe and '
                      'coworking space there and reads their reviews '
                      'for laptop/wifi signals. One city per night.',
                      style: TextStyle(
                          fontSize: 13, color: Brand.inkSecondary)),
                  const SizedBox(height: 14),
                  TextField(
                    controller: cityCtrl,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                        hintText: 'City name, e.g. Copenhagen'),
                    onChanged: (text) {
                      picked = null;
                      debounce?.cancel();
                      debounce =
                          Timer(const Duration(milliseconds: 350), () async {
                        // Cities, but also regions and districts:
                        // "Bali" is a province, "Canggu" a village.
                        final res = await _places.autocomplete(text.trim(),
                            types: [
                              'locality',
                              'sublocality_level_1',
                              'administrative_area_level_1',
                              'administrative_area_level_2',
                            ]);
                        if (ctx.mounted) {
                          setSheet(() => sugg = res.take(5).toList());
                        }
                      });
                    },
                  ),
                  ...sugg.map((m) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.location_city,
                            size: 20, color: Brand.inkSecondary),
                        title: Text(m.main),
                        subtitle: m.secondary.isEmpty
                            ? null
                            : Text(m.secondary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                        onTap: () => setSheet(() {
                          picked = m.secondary.isEmpty
                              ? m.main
                              : '${m.main}, ${m.secondary}';
                          cityCtrl.text = picked!;
                          sugg = [];
                        }),
                      )),
                  const SizedBox(height: 12),
                  PrimaryCta(
                    label: picked == null
                        ? 'Pick a city above'
                        : 'Sweep $picked',
                    onPressed: picked == null
                        ? null
                        : () async {
                            final city = picked!;
                            final ok =
                                await _supabase.queueCitySweep(city);
                            if (!ctx.mounted) return;
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(
                                    content: Text(ok
                                        ? '$city queued. The map fills '
                                            'in overnight.'
                                        : 'Could not queue $city. '
                                            'Is migration 34 in?')));
                          },
                  ),
                  if (pending.isNotEmpty || sweptNames.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                        [
                          if (pending.isNotEmpty)
                            'Queued: ${pending.join(', ')}',
                          if (sweptNames.isNotEmpty)
                            'Swept: ${sweptNames.join(', ')}',
                        ].join('\n'),
                        style: const TextStyle(
                            fontSize: 12, color: Brand.inkMuted)),
                  ],
                ]),
          ),
        ),
      ),
    );
    debounce?.cancel();
  }

  Future<void> _openFeedback() async {
    final msg = TextEditingController();
    final contact = TextEditingController();
    final signedIn = _supabase.signedIn;
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Brand.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => PointerInterceptor(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              24, 22, 24, MediaQuery.of(ctx).viewInsets.bottom + 28),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Send feedback',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text(
                    'Ideas, bugs, missing features, anything at all. '
                    'It goes straight to the Nomadwise team.',
                    style: TextStyle(
                        fontSize: 13, color: Brand.inkSecondary)),
                const SizedBox(height: 14),
                TextField(
                  controller: msg,
                  autofocus: true,
                  maxLines: 4,
                  decoration: const InputDecoration(
                      hintText: 'What is on your mind?'),
                ),
                if (!signedIn) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: contact,
                    decoration: const InputDecoration(
                        hintText:
                            'Email or WhatsApp, optional, for replies'),
                  ),
                ],
                const SizedBox(height: 16),
                PrimaryCta(
                  label: 'Send',
                  onPressed: () => Navigator.pop(ctx, true),
                ),
              ]),
        ),
      ),
    );
    if (sent != true || msg.text.trim().isEmpty) return;
    final ok = await _supabase.sendFeedback(msg.text.trim(),
        contact: contact.text);
    Analytics.capture('feedback_sent', {'ok': ok});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok
              ? 'Thank you! Your feedback is on its way.'
              : 'Could not send right now. Please try again.')));
    }
  }

  Widget _menuRow(
      {required IconData icon,
      required String label,
      String? sub,
      bool accent = false,
      Widget? trailing,
      VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: accent ? Brand.accentTint : Brand.field,
                borderRadius: BorderRadius.circular(10)),
            child: Icon(icon,
                size: 19, color: accent ? Brand.accent : Brand.ink),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  if (sub != null)
                    Text(sub,
                        style: const TextStyle(
                            fontSize: 12, color: Brand.inkMuted)),
                ]),
          ),
          if (trailing != null) trailing,
        ]),
      ),
    );
  }

  // ---------- build ----------

  /// Venues + unscreened places merged, nearest first (for the list
  /// view). Scoped to roughly where the map is looking: within ~25 km
  /// of the view centre, or the whole viewport when zoomed out wider.
  List<Object> get _listEntries {
    double distOf(Object e) {
      if (e is Venue) return e.distanceM ?? double.infinity;
      final d = e as DiscoveredPlace;
      if (_userLat == null) return double.infinity;
      return Venue.haversineM(_userLat!, _userLng!, d.lat, d.lng);
    }

    double? cLat = _userLat, cLng = _userLng;
    var radiusM = 25000.0;
    final b = _mapBounds;
    if (b != null) {
      cLat = (b.southwest.latitude + b.northeast.latitude) / 2;
      cLng = (b.southwest.longitude + b.northeast.longitude) / 2;
      final halfDiag = Venue.haversineM(
              b.southwest.latitude,
              b.southwest.longitude,
              b.northeast.latitude,
              b.northeast.longitude) /
          2;
      if (halfDiag > radiusM) radiusM = halfDiag;
    }
    bool inScope(double? lat, double? lng) {
      if (cLat == null || cLng == null || lat == null || lng == null) {
        return true;
      }
      return Venue.haversineM(cLat!, cLng!, lat, lng) <= radiusM;
    }

    final entries = <Object>[
      ..._visibleVenues.where((v) => inScope(v.lat, v.lng)),
      ..._visibleDiscovered.where((d) => inScope(d.lat, d.lng)),
    ];
    entries.sort((a, b) => distOf(a).compareTo(distOf(b)));
    return entries;
  }

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Top chrome per the design: menu button, search field, wallet button,
  /// over a white-to-transparent gradient.
  Widget _topChrome() {
    return Container(
      decoration: BoxDecoration(
        // Super subtle dark fade so the buttons read against any map,
        // without a distracting white wash.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: .10),
            Colors.black.withValues(alpha: .04),
            Colors.black.withValues(alpha: 0),
          ],
        ),
      ),
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(children: [
            IconSquareButton(
              icon: Icons.menu,
              floating: true,
              onTap: () => _scaffoldKey.currentState?.openDrawer(),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GestureDetector(
                onTap: _openSearch,
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Brand.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Brand.border),
                    boxShadow: Brand.shadowResting,
                  ),
                  child: const Row(children: [
                    Icon(Icons.search, size: 18, color: Brand.inkMuted),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text('Search cafes, coworking…',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Brand.inkMuted, fontSize: 14)),
                    ),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 10),
            _walletTotal != null
                // Signed in: your live balance IS the wallet button.
                ? GestureDetector(
                    onTap: () => _requireSignIn(() => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const WalletScreen()))),
                    child: Container(
                      height: 38,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: Brand.surface,
                        borderRadius: BorderRadius.circular(19),
                        border: Border.all(color: Brand.border),
                        boxShadow: Brand.shadowFloating,
                      ),
                      child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CoinDot(size: 17),
                            const SizedBox(width: 6),
                            Text('$_walletTotal',
                                style: const TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w700,
                                    color: Brand.ink)),
                          ]),
                    ),
                  )
                : IconSquareButton(
                    icon: Icons.account_balance_wallet_outlined,
                    floating: true,
                    child: Stack(clipBehavior: Clip.none, children: [
                      const Icon(
                          Icons.account_balance_wallet_outlined,
                          size: 19,
                          color: Brand.ink),
                      const Positioned(
                          right: -5, top: -5, child: CoinDot(size: 12)),
                    ]),
                    onTap: () => _requireSignIn(() => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const WalletScreen()))),
                  ),
          ]),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
          child: Row(children: [
            _toggleListChip(),
            _typeChip('Cafes', 'cafe'),
            _typeChip('Coworking', 'coworking'),
            _chip('Open now', VenueFilter.openNow),
            _chip('Open late', VenueFilter.openLate),
            _chip('24 hours', VenueFilter.open24h),
            _chip('Work-friendly', VenueFilter.workFriendly),
            _jumpChip(),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, top: 8),
          child: _countBadge(),
        ),
        if (!_showList)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Center(child: _searchAreaPill()),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildMenu(),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Brand.red))
          : Stack(children: [
              GoogleMap(
                initialCameraPosition: CameraPosition(
                    target: LatLng(_userLat ?? 20, _userLng ?? 0),
                    zoom: _initZoom),
                myLocationEnabled: true,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                markers: _markers,
                onMapCreated: (c) => _map = c,
                onCameraIdle: () async {
                  final b = await _map?.getVisibleRegion();
                  if (mounted && b != null) {
                    setState(() => _mapBounds = b);
                    // The world stays discovered: anything anyone ever
                    // found here appears for everyone, automatically.
                    _loadDiscoveredHere(b);
                    _saveCamera(b);
                  }
                },
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
                      color: Brand.bg,
                      padding: EdgeInsets.only(
                          top: MediaQuery.of(context).padding.top + 140),
                      child: _listEntries.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                          'No $_noun around here yet. '
                                          'Be the first to put this '
                                          'area on the map!',
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

              // ---- top chrome: menu / search / wallet + chips ----
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: PointerInterceptor(child: _topChrome()),
                ),
              ),

              // ---- legend (doubles as pin-colour filter) ----
              Positioned(
                left: 12,
                bottom: 24,
                child: PointerInterceptor(child: _legend()),
              ),

              // ---- map controls: locate (+ zoom on desktop) ----
              if (!_showList)
                Positioned(
                  right: 14,
                  bottom: (_selected == null &&
                              _selectedDiscovered == null) ||
                          _wideScreen
                      ? 24
                      : 210,
                  child: PointerInterceptor(child: _mapControls()),
                ),

              if (_selected != null && !_showList && !_wideScreen)
                Positioned(
                    left: 12,
                    right: 12,
                    bottom: 24,
                    child: PointerInterceptor(
                        child: _VenueCard(
                            venue: _selected!,
                            onDetails: () => _openDetail(_selected!)))),

              if (_selectedDiscovered != null &&
                  !_showList &&
                  !_wideScreen)
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

              // ---- desktop: details live in a right-side panel ----
              if (_wideScreen &&
                  !_showList &&
                  (_selected != null || _selectedDiscovered != null))
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  child: PointerInterceptor(child: _sidePanel()),
                ),
            ]),
    );
  }

  /// Bottom-right map controls: the locate button, and on desktop a
  /// zoom pill underneath it. Phones get pinch-to-zoom, so no pill.
  Widget _mapControls() {
    Widget zoomBtn(IconData icon, VoidCallback onTap, {bool top = false}) {
      return InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 40,
          child: Icon(icon, size: 20, color: Brand.ink),
        ),
      );
    }

    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Brand.surface,
              shape: BoxShape.circle,
              boxShadow: Brand.shadowFloating,
            ),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _goToMyLocation,
                child: const Icon(Icons.my_location,
                    color: Brand.accent, size: 21),
              ),
            ),
          ),
          if (_wideScreen) ...[
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: Brand.surface,
                borderRadius: BorderRadius.circular(12),
                boxShadow: Brand.shadowFloating,
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  zoomBtn(
                      Icons.add,
                      () => _map?.animateCamera(
                          CameraUpdate.zoomIn()),
                      top: true),
                  Container(
                      width: 28, height: 1, color: Brand.hairline),
                  zoomBtn(
                      Icons.remove,
                      () => _map?.animateCamera(
                          CameraUpdate.zoomOut())),
                ]),
              ),
            ),
          ],
        ]);
  }

  /// Wide screens: the tapped pin's details in a panel on the right,
  /// map stays visible on the left.
  Widget _sidePanel() {
    final w =
        (MediaQuery.of(context).size.width * .38).clamp(340.0, 520.0);
    return Container(
      width: w,
      decoration: const BoxDecoration(
        color: Brand.surface,
        border: Border(left: BorderSide(color: Brand.hairline)),
        boxShadow: Brand.shadowSheet,
      ),
      child: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
            child: Row(children: [
              const Spacer(),
              IconSquareButton(
                icon: Icons.close,
                onTap: () => setState(() {
                  _selected = null;
                  _selectedDiscovered = null;
                }),
              ),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              child: _selected != null
                  ? _VenueCard(
                      venue: _selected!,
                      onDetails: () => _openDetail(_selected!))
                  : _DiscoveredCard(
                      place: _selectedDiscovered!,
                      places: _places,
                      onScreen: () =>
                          _openScreening(_selectedDiscovered!)),
            ),
          ),
        ]),
      ),
    );
  }

  // ---------- chips & badges ----------

  /// 32px filter pill: navy when active, white + border when not.
  Widget _pill(String label,
      {required bool on,
      required VoidCallback onTap,
      IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.ease,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: on ? Brand.ink : Brand.surface,
            borderRadius: BorderRadius.circular(16),
            border: on ? null : Border.all(color: Brand.border),
            boxShadow: Brand.shadowResting,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 15,
                  color: on ? Colors.white : Brand.ink),
              const SizedBox(width: 5),
            ],
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: on ? Colors.white : Brand.ink)),
          ]),
        ),
      ),
    );
  }

  Widget _toggleListChip() => _pill(
        _showList ? 'Map' : 'List',
        icon: _showList ? Icons.map_outlined : Icons.list,
        on: true,
        onTap: () => setState(() {
          _showList = !_showList;
          _selected = null;
        }),
      );

  Widget _typeChip(String label, String type) {
    final on = _typeFilter == type;
    return _pill(label, on: on, onTap: () => setState(() {
          _typeFilter = on ? null : type;
          if (_selected != null && !_visibleVenues.contains(_selected)) {
            _selected = null;
          }
        }));
  }

  Widget _chip(String label, VenueFilter f) {
    final on = _filters.contains(f);
    return _pill(label, on: on, onTap: () => setState(() {
          on ? _filters.remove(f) : _filters.add(f);
          if (_selected != null && !_visibleVenues.contains(_selected)) {
            _selected = null;
          }
        }));
  }

  Widget _jumpChip() => _pill('Jump to…',
      icon: Icons.travel_explore, on: false, onTap: _openJumpToCity);

  Widget _searchAreaPill() {
    return Container(
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: Brand.shadowFloating,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: _searchThisArea,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _searchingArea
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Brand.accent))
                  : const Icon(Icons.refresh,
                      size: 16, color: Brand.accent),
              const SizedBox(width: 6),
              Text(_searchingArea ? 'Searching…' : 'Search this area',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                      color: Brand.accent)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _countBadge() {
    String text;
    if (_showList) {
      // List mode covers everywhere, sorted by distance.
      text = [
        _anyFilterOn
            ? '${_visibleVenues.length} of ${_venues.length} $_noun shown'
            : '${_venues.length} $_noun',
        if (_visibleDiscovered.isNotEmpty)
          '${_visibleDiscovered.length} unscreened',
      ].join(' · ');
    } else {
      // Map mode: count only what's inside the current view.
      final totalHere = _venues
          .where((v) =>
              v.lat != null && v.lng != null && _inBounds(v.lat!, v.lng!))
          .length;
      final shownHere = _visibleVenues
          .where((v) => _inBounds(v.lat!, v.lng!))
          .length;
      final unscreenedHere = _visibleDiscovered
          .where((d) => _inBounds(d.lat, d.lng))
          .length;
      if (totalHere == 0 && unscreenedHere == 0) {
        text = 'No $_noun here yet';
      } else {
        text = [
          _anyFilterOn
              ? '$shownHere of $totalHere $_noun here'
              : '$totalHere $_noun here',
          if (unscreenedHere > 0) '$unscreenedHere unscreened',
        ].join(' · ');
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
          color: Brand.charcoal.withValues(alpha: .85),
          borderRadius: BorderRadius.circular(12)),
      child: Text(
        text,
        style: const TextStyle(
            color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _legend() {
    Widget row(Color color, String label, String cat,
        {bool outline = false}) {
      final selecting = _pinFilter.isNotEmpty;
      final selected = _pinFilter.contains(cat);
      final shown = !selecting || selected;
      return InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() {
          // Tap = show only this colour; tap more to add; tap again to
          // remove. Empty selection = show everything.
          selected ? _pinFilter.remove(cat) : _pinFilter.add(cat);
          if (_selected != null && !_visibleVenues.contains(_selected)) {
            _selected = null;
          }
          final sel = _selectedDiscovered;
          if (sel != null &&
              !_catVisible(sel.promising ? 'promising' : 'unscreened')) {
            _selectedDiscovered = null;
          }
        }),
        child: Opacity(
          opacity: shown ? 1 : .35,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                  outline
                      ? Icons.location_on_outlined
                      : Icons.location_on,
                  size: 16,
                  color: color),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight:
                          selected ? FontWeight.w800 : FontWeight.w500)),
              if (selected) ...[
                const SizedBox(width: 4),
                const Icon(Icons.check_circle,
                    size: 12, color: Brand.red),
              ],
            ]),
          ),
        ),
      );
    }

    final filtering = _pinFilter.isNotEmpty;

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
              if (filtering)
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
          Text('PINS',
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
        row(Brand.red, 'Work-friendly', 'yes'),
        row(Brand.ink, 'Not for laptops', 'no'),
        row(Brand.amber, 'Unknown · confirm & earn', 'unknown'),
        row(Brand.violet, 'Promising · wifi/laptops in reviews',
            'promising'),
        row(Brand.violet, 'Unscreened · review & earn', 'unscreened',
            outline: true),
        if (filtering)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _pinFilter.clear()),
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
          child: Text('tap a colour to show only those pins',
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

class _SpaceSearchScreen extends StatefulWidget {
  final List<Venue> venues;
  final PlacesService places;
  final double? nearLat, nearLng;
  const _SpaceSearchScreen(
      {required this.venues,
      required this.places,
      this.nearLat,
      this.nearLng});

  @override
  State<_SpaceSearchScreen> createState() => _SpaceSearchScreenState();
}

class _SpaceSearchScreenState extends State<_SpaceSearchScreen> {
  final _ctrl = TextEditingController();

  List<Venue> get venues => widget.venues;
  PlacesService get places => widget.places;
  String get query => _ctrl.text;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void close(BuildContext context, Object? result) =>
      Navigator.pop(context, result);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => close(context, null)),
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search any space, anywhere…',
            border: InputBorder.none,
          ),
          style: const TextStyle(fontSize: 17),
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          if (query.isNotEmpty)
            IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () => setState(() => _ctrl.clear()))
        ],
      ),
      body: query.trim().length < 3
          ? Center(
              child: Text('Type at least 3 letters…',
                  style: TextStyle(color: Colors.grey.shade500)))
          : _resultList(context),
    );
  }

  Widget _resultList(BuildContext context) {
    final q = query.trim().toLowerCase();
    final local = venues
        .where((v) =>
            v.name.toLowerCase().contains(q) ||
            (v.neighbourhood ?? '').toLowerCase().contains(q))
        .take(6)
        .toList();
    final localPlaceIds =
        venues.map((v) => v.googlePlaceId).whereType<String>().toSet();

    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text(text,
              style: TextStyle(
                  fontSize: 11,
                  letterSpacing: .5,
                  fontWeight: FontWeight.w800,
                  color: Colors.grey.shade500)),
        );

    return ListView(children: [
      if (local.isNotEmpty) ...[
        header('ON NOMAD MAPS'),
        ...local.map((v) => ListTile(
              leading: Icon(Icons.location_on,
                  color: switch (v.workFriendly) {
                    WorkFriendly.yes => Brand.red,
                    WorkFriendly.no => Brand.ink,
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
            )),
      ],
      header('FROM GOOGLE · ANYWHERE'),
      FutureBuilder<List<PlaceSuggestion>>(
        future: places.autocomplete(query,
            nearLat: widget.nearLat, nearLng: widget.nearLng),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Brand.red))),
            );
          }
          final results = snap.data!
              .where((s) => !localPlaceIds.contains(s.placeId))
              .take(6)
              .toList();
          if (results.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Nothing found for "$query"',
                  style: TextStyle(color: Colors.grey.shade600)),
            );
          }
          return Column(
              children: results
                  .map((s) => ListTile(
                        leading: const Icon(Icons.travel_explore,
                            color: Brand.charcoal, size: 22),
                        title: Text(s.main),
                        subtitle: s.secondary.isEmpty
                            ? null
                            : Text(s.secondary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                        onTap: () => close(context, s),
                      ))
                  .toList());
        },
      ),
    ]);
  }
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
                WorkFriendly.no => Brand.ink,
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
              ? 'Wifi ${venue.wifiSpeedLabel} Mbps'
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
              size: 30, color: Brand.inkFaint),
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
  List<String> _photos = [];

  DiscoveredPlace get place => widget.place;

  @override
  void initState() {
    super.initState();
    _loadSignals();
    _loadPhotos();
  }

  @override
  void didUpdateWidget(covariant _DiscoveredCard old) {
    super.didUpdateWidget(old);
    if (old.place.placeId != place.placeId) {
      _signals = null;
      _photos = [];
      _loadSignals();
      _loadPhotos();
    }
  }

  Future<void> _loadSignals() async {
    final s = await widget.places.nomadSignals(place.placeId);
    if (mounted) setState(() => _signals = s);
  }

  Future<void> _loadPhotos() async {
    final p = await widget.places.photoNames(place.placeId);
    if (mounted) setState(() => _photos = p);
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
    return Container(
      decoration: BoxDecoration(
        color: Brand.surface,
        borderRadius: BorderRadius.circular(22),
        boxShadow: Brand.shadowSheet,
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cardPhotoStrip(_photos),
            Row(children: [
              Expanded(
                  child: Text(place.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 18))),
              if (place.rating != null) ...[
                const Icon(Icons.star, color: Brand.gold, size: 17),
                Text(' ${place.rating}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
                if (place.userRatingCount != null)
                  Text(' (${place.userRatingCount})',
                      style: const TextStyle(
                          color: Brand.inkMuted, fontSize: 12)),
              ],
            ]),
            const SizedBox(height: 10),
            const StatusChip('Not screened by nomads yet'),
            const SizedBox(height: 10),
            _signalsRow(),
            const SizedBox(height: 14),
            PrimaryCta(
              label: 'Screen this space',
              coins: '+${AppConfig.coinsNewVenue}',
              onPressed: widget.onScreen,
            ),
          ]),
    );
  }
}

// ============================================================
// Compact card shown when a pin is tapped (map mode)
// ============================================================

/// Small scrollable photo strip for the pin tap cards — people are
/// visual, a picture sells the place faster than any fact row.
Widget _cardPhotoStrip(List<String> names) {
  if (names.isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: names.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) => ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            PlacesService.photoUrl(names[i], maxWidth: 400),
            height: 96,
            width: 132,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
}

class _VenueCard extends StatelessWidget {
  final Venue venue;
  final VoidCallback onDetails;
  const _VenueCard({required this.venue, required this.onDetails});

  @override
  Widget build(BuildContext context) {
    final wf = venue.workFriendly;
    final closing = venue.closingLabel(
        soonMinutes: AppConfig.closingSoonMinutes);
    final (statusText, statusDot) = switch (wf) {
      WorkFriendly.yes => ('Work-friendly', Brand.accent),
      WorkFriendly.no => ('Not for laptops', Brand.ink),
      WorkFriendly.unknown => (
          'Unknown · confirm & earn',
          Brand.gold
        ),
    };
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onDetails,
        child: Container(
          decoration: BoxDecoration(
            color: Brand.surface,
            borderRadius: BorderRadius.circular(22),
            boxShadow: Brand.shadowSheet,
          ),
          padding: const EdgeInsets.all(18),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _cardPhotoStrip(
                    (venue.live?.photoNames ?? []).take(5).toList()),
                Row(children: [
                  Expanded(
                      child: Text(venue.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 18))),
                  if (venue.rating != null) ...[
                    const Icon(Icons.star, color: Brand.gold, size: 17),
                    Text(' ${venue.rating}',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    if (venue.reviewCount != null)
                      Text(' (${venue.reviewCount})',
                          style: const TextStyle(
                              color: Brand.inkMuted, fontSize: 12)),
                  ],
                ]),
                const SizedBox(height: 10),
                StatusChip(statusText, dotColor: statusDot),
                const SizedBox(height: 8),
                Text(
                  [
                    venue.distanceLabel(),
                    if (closing != null) closing,
                  ].join(' · '),
                  style: const TextStyle(
                      fontSize: 13, color: Brand.inkSecondary),
                ),
                const SizedBox(height: 10),
                _facts(),
                const SizedBox(height: 10),
                const Row(children: [
                  Expanded(
                    child: Text('Photos, wifi login & directions',
                        style: TextStyle(
                            fontSize: 12, color: Brand.inkMuted)),
                  ),
                  Text('More ›',
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: Brand.accent)),
                ]),
              ]),
        ),
      ),
    );
  }

  /// The facts nomads care about, visible without another tap.
  Widget _facts() {
    Widget pillFact(IconData? icon, Color iconColor, String label) =>
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: Brand.field,
              borderRadius: BorderRadius.circular(10)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: iconColor),
              const SizedBox(width: 4),
            ],
            Text(label,
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Brand.ink)),
          ]),
        );

    Widget fact(String label, bool? v) {
      final (color, icon) = switch (v) {
        true => (Brand.success, Icons.check),
        false => (Brand.accent, Icons.close),
        null => (Brand.inkMuted, Icons.help_outline),
      };
      return pillFact(icon, color, label);
    }

    return Wrap(spacing: 6, runSpacing: 6, children: [
      if (venue.wifiSpeedMbps != null)
        pillFact(Icons.wifi, Brand.ink, '${venue.wifiSpeedLabel} Mbps')
      else
        fact('Wifi', null),
      fact('Laptops', venue.laptopsAllowed),
      fact('Power', venue.powerOutlets),
      fact('Aircon', venue.aircon),
      fact('Quiet', venue.quietSpace),
    ]);
  }
}
