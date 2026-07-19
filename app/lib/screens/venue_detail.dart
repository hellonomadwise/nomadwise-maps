import 'dart:ui' as ui;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/venue.dart';
import '../services/analytics_service.dart';
import '../services/location_service.dart';
import '../services/places_service.dart';
import '../services/speed_test_service.dart';
import '../services/story_card.dart';
import '../services/supabase_service.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'auth_screen.dart';

class VenueDetailScreen extends StatefulWidget {
  final Venue venue;
  final VoidCallback onConfirm;
  const VenueDetailScreen(
      {super.key, required this.venue, required this.onConfirm});

  @override
  State<VenueDetailScreen> createState() => _VenueDetailScreenState();
}

class _VenueDetailScreenState extends State<VenueDetailScreen> {
  final _supabase = SupabaseService();
  final _places = PlacesService();
  List<String> _photos = [];
  bool _testingWifi = false;
  String _testPhase = '';
  String _wifiConnType = 'unknown';
  Map<String, dynamic>? _wifiLogin;
  String? _discoveredBy;
  String? _screenedBy;

  Future<void> _loadWifiLogin() async {
    final w = await _supabase.venueWifi(venue.id);
    if (mounted) setState(() => _wifiLogin = w);
  }

  Future<void> _loadCredits() async {
    final c = await _supabase.venueCredits(venue.id);
    if (mounted && c != null) {
      setState(() {
        _discoveredBy = c['discovered_by'] as String?;
        _screenedBy = c['screened_by'] as String?;
      });
    }
  }
  int _photoIndex = 0;

  Venue get venue => widget.venue;

  @override
  void initState() {
    super.initState();
    _loadPhotos();
    _loadWifiLogin();
    _loadCredits();
    Analytics.capture('venue_viewed',
        {'venue': venue.name, 'type': venue.type});
  }

  Future<void> _loadPhotos() async {
    // Google's listing photos first (curated), community photos after.
    // If this screen opened before the map fetched the live details,
    // fetch them ourselves so the photos always appear.
    var live = venue.live;
    if ((live == null || live.photoNames.isEmpty) &&
        venue.googlePlaceId != null) {
      live = await _places.details(venue.googlePlaceId!);
      if (live != null) venue.live = live;
    }
    final google = (live?.photoNames ?? [])
        .take(6)
        .map((n) => PlacesService.photoUrl(n))
        .toList();
    final community = await _supabase.venuePhotoUrls(venue.id);
    if (mounted) setState(() => _photos = [...google, ...community]);
  }

  bool _sharing = false;

  /// Build the story card and hand it to the phone's share sheet
  /// (Instagram Stories, WhatsApp, wherever they like).
  Future<void> _share() async {
    setState(() => _sharing = true);
    try {
      // Best backdrop: the space's first Google photo.
      ui.Image? photo;
      try {
        final names = venue.live?.photoNames ?? [];
        if (names.isNotEmpty) {
          final res = await http
              .get(Uri.parse(
                  PlacesService.photoUrl(names.first, maxWidth: 1200)))
              .timeout(const Duration(seconds: 6));
          if (res.statusCode == 200) {
            final codec =
                await ui.instantiateImageCodec(res.bodyBytes);
            photo = (await codec.getNextFrame()).image;
          }
        }
      } catch (_) {} // no photo = brand gradient background

      final bytes = await StoryCard.build(venue, photo: photo);
      if (bytes == null) throw Exception('render failed');
      Analytics.capture('space_shared', {'venue': venue.name});
      await Share.shareXFiles(
        [
          XFile.fromData(bytes,
              mimeType: 'image/png', name: 'nomadwise_maps.png')
        ],
        text: '${venue.name} on Nomadwise Maps: '
            'https://hellonomadwise.github.io/nomadwise-maps/',
      );
    } catch (_) {
      // Device cannot share images (e.g. desktop): share the link.
      try {
        await Share.share('${venue.name} on Nomadwise Maps: '
            'https://hellonomadwise.github.io/nomadwise-maps/');
      } catch (_) {
        await Clipboard.setData(const ClipboardData(
            text:
                'https://hellonomadwise.github.io/nomadwise-maps/'));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Link copied to clipboard.')));
        }
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _openDirections() async {
    Analytics.capture('directions_clicked', {'venue': venue.name});
    final lat = venue.lat, lng = venue.lng;
    if (lat == null || lng == null) return;
    final pid = venue.googlePlaceId;
    final url = Uri.parse('https://www.google.com/maps/dir/?api=1'
        '&destination=$lat,$lng'
        '${pid != null ? '&destination_place_id=$pid' : ''}');
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final closing =
        venue.closingLabel(soonMinutes: AppConfig.closingSoonMinutes);
    // Comfortable reading width on desktop; full width on phones.
    final screenW = MediaQuery.of(context).size.width;
    final contentW = screenW > 760 ? 760.0 : screenW;
    final carouselH = (contentW * 0.55).clamp(180.0, 380.0);

    return Scaffold(
      appBar: AppBar(title: Text(venue.name)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(padding: EdgeInsets.zero, children: [
        // ---- photo carousel ----
        _carousel(carouselH),

        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ---- header ----
                Row(children: [
                  Chip(
                      label: Text(
                          venue.type == 'coworking'
                              ? 'Coworking Space'
                              : 'Cafe',
                          style: const TextStyle(fontSize: 12))),
                  const SizedBox(width: 8),
                  if (venue.neighbourhood != null)
                    Expanded(
                      child: Text(venue.neighbourhood!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.grey.shade600)),
                    )
                  else
                    const Spacer(),
                  Text(venue.distanceLabel(),
                      style:
                          const TextStyle(fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 12),

                // ---- action row ----
                Row(children: [
                  Expanded(
                    child: ElevatedButton.icon(
                        onPressed: _openDirections,
                        icon: const Icon(Icons.directions, size: 20),
                        label: const Text('Directions')),
                  ),
                  if (venue.website != null) ...[
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 52,
                      height: 48,
                      child: OutlinedButton(
                        onPressed: () => launchUrl(
                            Uri.parse(venue.website!),
                            mode: LaunchMode.externalApplication),
                        style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.zero),
                        child: const Icon(Icons.language, size: 20),
                      ),
                    ),
                  ],
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 52,
                    height: 48,
                    child: OutlinedButton(
                      onPressed: _sharing ? null : _share,
                      style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.zero),
                      child: _sharing
                          ? const SizedBox(
                              width: 17,
                              height: 17,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Brand.ink))
                          : const Icon(Icons.ios_share, size: 20),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),

                // ---- wifi hero + login + in-place speed test ----
                _wifiHero(),
                const SizedBox(height: 8),
                _wifiLoginCard(),
                const SizedBox(height: 8),
                _wifiTestButton(),
                const SizedBox(height: 14),

                // ---- Google live block ----
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      color: Brand.lightGrey,
                      borderRadius: BorderRadius.circular(16)),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          if (venue.rating != null) ...[
                            const Icon(Icons.star, color: Brand.amber),
                            const SizedBox(width: 4),
                            Text('${venue.rating}',
                                style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w900)),
                            const SizedBox(width: 6),
                            if (venue.reviewCount != null)
                              Text('${venue.reviewCount} reviews',
                                  style: TextStyle(
                                      color: Colors.grey.shade600)),
                          ] else
                            Text('No Google rating yet',
                                style: TextStyle(
                                    color: Colors.grey.shade600)),
                          const Spacer(),
                          if (venue.openNow != null)
                            Text(venue.openNow! ? 'Open' : 'Closed',
                                style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: venue.openNow!
                                        ? Colors.green.shade700
                                        : Brand.red)),
                        ]),
                        if (closing != null) ...[
                          const SizedBox(height: 6),
                          Text(closing,
                              style: TextStyle(
                                  fontWeight: FontWeight.w500,
                                  color: closing.startsWith('Closing')
                                      ? Brand.red
                                      : Brand.charcoal)),
                        ],
                        if (venue.live?.weekdayDescriptions != null) ...[
                          const Divider(height: 24),
                          ...venue.live!.weekdayDescriptions!
                              .map((d) => Padding(
                                  padding:
                                      const EdgeInsets.only(bottom: 3),
                                  child: Text(d,
                                      style: const TextStyle(
                                          fontSize: 13)))),
                        ] else if (venue.fallbackHours != null) ...[
                          const Divider(height: 24),
                          ..._fallbackHourLines(),
                        ],
                      ]),
                ),
                const SizedBox(height: 20),

                // ---- community info: freshness + features ----
                Row(children: [
                  const Text('CAN I WORK HERE?',
                      style: TextStyle(
                          color: Brand.red,
                          fontWeight: FontWeight.w900,
                          fontSize: 13,
                          letterSpacing: 1)),
                  const Spacer(),
                  _freshnessBadge(),
                ]),
                const SizedBox(height: 10),
                _feature('Laptops allowed', venue.laptopsAllowed,
                    highlight: true),
                _feature('Power outlets', venue.powerOutlets),
                _feature('Aircon', venue.aircon),
                _feature('Comfortable seating', venue.comfortableSeating),
                _feature('Cozy', venue.cozy),
                _feature('Quiet space', venue.quietSpace),
                if (venue.type == 'coworking') ...[
                  _feature('Good for calls', venue.goodForCalls),
                  _feature('Call/Skype room', venue.callRoom),
                  _feature('Monitor', venue.monitorAvailable),
                  _feature('Office chairs', venue.officeChairs),
                  _feature('24h access', venue.access24h),
                ],
                const SizedBox(height: 8),
                if (venue.instagram != null)
                  TextButton.icon(
                      onPressed: () => launchUrl(
                          Uri.parse(venue.instagram!),
                          mode: LaunchMode.externalApplication),
                      icon: const Icon(Icons.camera_alt_outlined,
                          size: 18),
                      label: const Text('Instagram')),
                const SizedBox(height: 8),

                // ---- confirm & earn ----
                if (venue.unansweredCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                          color: Brand.amber.withValues(alpha: .15),
                          borderRadius: BorderRadius.circular(12)),
                      child: Row(children: [
                        const Icon(Icons.monetization_on,
                            color: Brand.amber, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${venue.unansweredCount} unanswered '
                            'question${venue.unansweredCount == 1 ? '' : 's'} '
                            '. Help other nomads and earn coins',
                            style: const TextStyle(
                                fontWeight: FontWeight.w500,
                                fontSize: 13),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    widget.onConfirm();
                  },
                  icon: const Icon(Icons.verified_outlined),
                  label: Text(
                      'Confirm / update this space  ·  earn ${AppConfig.coinsConfirmVenue} coins'),
                ),
                if (_creditsLine() != null) ...[
                  const SizedBox(height: 18),
                  Row(children: [
                    const Icon(Icons.explore_outlined,
                        size: 14, color: Brand.inkFaint),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_creditsLine()!,
                          style: const TextStyle(
                              fontSize: 12, color: Brand.inkFaint)),
                    ),
                  ]),
                ],
                const SizedBox(height: 30),
              ]),
        ),
      ]),
        ),
      ),
    );
  }

  /// "Discovered by Anna · First screened by Lucas" (or the
  /// shorter variants when only one is known / both are the same).
  String? _creditsLine() {
    final d = _discoveredBy, s = _screenedBy;
    if (d == null && s == null) return null;
    if (d != null && s != null) {
      if (d == s) return 'Discovered and first screened by $d';
      return 'Discovered by $d · First screened by $s';
    }
    if (d != null) return 'Discovered by $d';
    return 'First screened by $s';
  }

  // ---------- widgets ----------

  Widget _carousel(double height) {
    if (_photos.isEmpty) {
      return InkWell(
        onTap: () {
          Navigator.pop(context);
          widget.onConfirm();
        },
        child: Container(
          height: 150,
          color: Brand.goldTint,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.add_a_photo_outlined,
                  size: 34, color: Brand.goldLink),
              const SizedBox(height: 8),
              const Text('No photos yet. Tap to add one & earn coins',
                  style: TextStyle(
                      color: Brand.goldTextDark,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: Stack(children: [
        PageView.builder(
          itemCount: _photos.length,
          onPageChanged: (i) => setState(() => _photoIndex = i),
          itemBuilder: (_, i) => Image.network(
            _photos[i],
            fit: BoxFit.cover,
            width: double.infinity,
            errorBuilder: (_, __, ___) => Container(
                color: Brand.lightGrey,
                child: const Center(
                    child: Icon(Icons.broken_image_outlined,
                        color: Colors.grey))),
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : Container(
                    color: Brand.lightGrey,
                    child: const Center(
                        child: CircularProgressIndicator(
                            color: Brand.red, strokeWidth: 2))),
          ),
        ),
        // dots
        Positioned(
          bottom: 10,
          left: 0,
          right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
                _photos.length.clamp(0, 12),
                (i) => Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _photoIndex
                            ? Colors.white
                            : Colors.white.withValues(alpha: .45),
                      ),
                    )),
          ),
        ),
      ]),
    );
  }

  Widget _wifiHero() {
    final speed = venue.wifiSpeedMbps;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(
            color: speed != null
                ? Brand.red.withValues(alpha: .35)
                : Colors.grey.shade300),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        Icon(Icons.wifi,
            size: 34, color: speed != null ? Brand.red : Colors.grey),
        const SizedBox(width: 14),
        if (speed != null) ...[
          Text('$speed',
              style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  height: 1,
                  color: Brand.charcoal)),
          const SizedBox(width: 6),
          const Padding(
            padding: EdgeInsets.only(bottom: 3),
            child: Text('Mbps',
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: Brand.charcoal)),
          ),
          const Spacer(),
          if (venue.confirmedAgoLabel != null)
            Text('updated\n${venue.confirmedAgoLabel}',
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontSize: 11, color: Colors.grey.shade600)),
        ] else
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('WiFi speed not measured yet',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  Text('Sitting there right now? Test it below.',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600)),
                ]),
          ),
      ]),
    );
  }

  Widget _wifiLoginCard() {
    // Signed out: invite to sign in (the login may or may not exist).
    if (!_supabase.signedIn) {
      return _wifiLoginShell(
        icon: Icons.lock_outline,
        child: Row(children: [
          Expanded(
            child: Text('Sign in to see or share this space\'s WiFi login',
                style: TextStyle(
                    fontSize: 13, color: Colors.grey.shade700)),
          ),
          TextButton(
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const AuthScreen()))
                  .then((_) {
                if (mounted) setState(() {});
                _loadWifiLogin();
              }),
              child: const Text('Sign in')),
        ]),
      );
    }

    final w = _wifiLogin;
    if (w == null) {
      return _wifiLoginShell(
        icon: Icons.key_outlined,
        child: Row(children: [
          Expanded(
            child: Text('Know the WiFi login here?',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800)),
          ),
          TextButton(
              onPressed: _shareWifiLogin,
              child:
                  Text('Share it · +${AppConfig.coinsWifiLogin}')),
        ]),
      );
    }

    Widget copyRow(String label, String value) => Row(children: [
          Text('$label  ',
              style: TextStyle(
                  fontSize: 12, color: Colors.grey.shade600)),
          Expanded(
            child: Text(value,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 14)),
          ),
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  duration: const Duration(seconds: 1),
                  content: Text('$label copied')));
            },
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.copy, size: 16, color: Brand.red),
            ),
          ),
        ]);

    return _wifiLoginShell(
      icon: Icons.key,
      child:
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        copyRow('Network', w['ssid'] ?? ''),
        if (w['password'] != null) ...[
          const SizedBox(height: 4),
          copyRow('Password', w['password']),
        ] else
          Text('Open network, no password',
              style:
                  TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        const SizedBox(height: 2),
        Row(children: [
          const Spacer(),
          InkWell(
            onTap: _shareWifiLogin,
            child: Text('Wrong? Update it · +${AppConfig.coinsWifiLogin}',
                style: const TextStyle(
                    fontSize: 11,
                    color: Brand.red,
                    fontWeight: FontWeight.w600)),
          ),
        ]),
      ]),
    );
  }

  Widget _wifiLoginShell({required IconData icon, required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
          color: Brand.lightGrey, borderRadius: BorderRadius.circular(14)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Icon(icon, size: 20, color: Brand.charcoal),
        const SizedBox(width: 10),
        Expanded(child: child),
      ]),
    );
  }

  Future<void> _shareWifiLogin() async {
    final ssid = TextEditingController();
    final pass = TextEditingController();
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: const Text('Share the WiFi login'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: ssid,
                    decoration: const InputDecoration(
                        labelText: 'Network name (SSID)')),
                const SizedBox(height: 10),
                TextField(
                    controller: pass,
                    decoration: const InputDecoration(
                        labelText: 'Password',
                        helperText: 'Leave empty for open networks')),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(
                        'Share · +${AppConfig.coinsWifiLogin} coins')),
              ],
            ));
    if (ok != true || ssid.text.trim().isEmpty || !mounted) return;
    final pos = await LocationService.current();
    if (pos == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Location is needed to verify you\'re at the space.')));
      }
      return;
    }
    double? distance;
    if (venue.lat != null && venue.lng != null) {
      distance = Venue.haversineM(
          pos.latitude, pos.longitude, venue.lat!, venue.lng!);
    }
    final netHash = await _supabase.networkFingerprint();
    await _supabase.submit(
      kind: 'wifi_login',
      venueId: venue.id,
      payload: {
        'ssid': ssid.text.trim(),
        'password': pass.text.trim(),
        if (netHash != null) 'network_hash': netHash,
      },
      gpsLat: pos.latitude,
      gpsLng: pos.longitude,
      gpsDistanceM: distance,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Thanks! +${AppConfig.coinsWifiLogin} coins after verification. '
            '(Once per space per month.)')));
    // If GPS verified it instantly, the login appears right away.
    await Future.delayed(const Duration(seconds: 2));
    _loadWifiLogin();
  }

  Widget _wifiTestButton() {
    if (_testingWifi) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
            color: Brand.amber.withValues(alpha: .18),
            borderRadius: BorderRadius.circular(14)),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Brand.charcoal)),
          const SizedBox(width: 10),
          Text(_testPhase,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, color: Brand.charcoal)),
        ]),
      );
    }
    return PrimaryCta(
      label: venue.wifiSpeedMbps == null
          ? 'Test the WiFi here'
          : 'Re-test the WiFi',
      coins: '+${AppConfig.coinsWifiTest}',
      navy: true,
      icon: Icons.speed,
      onPressed: _testWifi,
    );
  }

  Future<void> _testWifi() async {
    if (!_supabase.signedIn) {
      final ok = await Navigator.push<bool>(context,
          MaterialPageRoute(builder: (_) => const AuthScreen()));
      if (ok != true) return;
    }
    if (!mounted) return;

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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'You\'re on mobile data. Connect to the space\'s WiFi first, then retest.')));
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

    _wifiConnType = connType;
    setState(() {
      _testingWifi = true;
      _testPhase = 'Starting…';
    });
    final mbps = await SpeedTestService.measureMbps(
        onPhase: (p) => mounted ? setState(() => _testPhase = p) : null);
    if (!mounted) return;
    setState(() => _testingWifi = false);
    if (mbps == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Could not measure. Check the connection and retry.')));
      return;
    }
    Analytics.capture('wifi_test_measured',
        {'venue': venue.name, 'mbps': mbps, 'connection': _wifiConnType});
    final submit = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: Row(children: [
                const Icon(Icons.wifi, color: Brand.red),
                const SizedBox(width: 8),
                Text('$mbps Mbps'),
              ]),
              content: Text(
                  'Measured on the connection you\'re using right now. '
                  'Submit it for ${venue.name}?'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Discard')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(
                        'Submit  ·  +${AppConfig.coinsWifiTest} coins')),
              ],
            ));
    if (submit != true || !mounted) return;
    final pos = await LocationService.current();
    if (pos == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Location is needed to verify you\'re at the space.')));
      }
      return;
    }
    double? distance;
    if (venue.lat != null && venue.lng != null) {
      distance = Venue.haversineM(
          pos.latitude, pos.longitude, venue.lat!, venue.lng!);
    }
    // Which network was this measured on? Same cafe WiFi = same
    // fingerprint, so later tests can be cross-checked automatically.
    final netHash = await _supabase.networkFingerprint();
    await _supabase.submit(
      kind: 'wifi_test',
      venueId: venue.id,
      payload: {
        'wifi_speed_mbps': mbps,
        // Audit trail: what the browser could tell about the connection.
        'connection_type': _wifiConnType,
        if (netHash != null) 'network_hash': netHash,
      },
      gpsLat: pos.latitude,
      gpsLng: pos.longitude,
      gpsDistanceM: distance,
    );
    if (!mounted) return;
    showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              title: Row(children: [
                const Icon(Icons.monetization_on, color: Brand.amber),
                const SizedBox(width: 8),
                Text('+${AppConfig.coinsWifiTest} coins'),
              ]),
              content: const Text(
                  'Thanks! Coins are credited after verification, '
                  'usually within 5 minutes. (WiFi tests pay once per '
                  'space per month.)'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Nice!'))
              ],
            ));
  }

  Widget _freshnessBadge() {
    final ago = venue.confirmedAgoLabel;
    final stale = venue.infoIsStale;
    final (text, color) = ago == null
        ? ('Not yet confirmed', Brand.amber)
        : stale
            ? ('Confirmed $ago · needs a refresh', Brand.amber)
            : ('Confirmed $ago', Colors.green.shade700);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(10)),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w700)),
    );
  }

  List<Widget> _fallbackHourLines() {
    const names = {
      'mon': 'Monday',
      'tue': 'Tuesday',
      'wed': 'Wednesday',
      'thu': 'Thursday',
      'fri': 'Friday',
      'sat': 'Saturday',
      'sun': 'Sunday',
    };
    return names.entries
        .where((e) => venue.fallbackHours![e.key] != null)
        .map((e) => Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text('${e.value}: ${venue.fallbackHours![e.key]}',
                style: const TextStyle(fontSize: 13))))
        .toList();
  }

  Widget _feature(String label, bool? value, {bool highlight = false}) {
    final (icon, color, text) = switch (value) {
      true => (Icons.check_circle, Colors.green.shade600, 'Yes'),
      false => (Icons.cancel, Brand.red, 'No'),
      null => (Icons.help_outline, Colors.grey.shade400, 'Unknown'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 10),
        Expanded(
            child: Text(label,
                style: TextStyle(
                    fontWeight:
                        highlight ? FontWeight.w700 : FontWeight.w400))),
        Text(text,
            style: TextStyle(
                color: value == null ? Colors.grey.shade500 : color,
                fontWeight: FontWeight.w500)),
      ]),
    );
  }
}
