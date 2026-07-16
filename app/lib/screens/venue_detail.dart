import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/venue.dart';
import '../services/places_service.dart';
import '../services/supabase_service.dart';
import '../theme.dart';

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
  List<String> _photos = [];
  int _photoIndex = 0;

  Venue get venue => widget.venue;

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    // Google's listing photos first (curated), community photos after.
    final google = (venue.live?.photoNames ?? [])
        .take(6)
        .map((n) => PlacesService.photoUrl(n))
        .toList();
    final community = await _supabase.venuePhotoUrls(venue.id);
    if (mounted) setState(() => _photos = [...google, ...community]);
  }

  Future<void> _openDirections() async {
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
    return Scaffold(
      appBar: AppBar(title: Text(venue.name)),
      body: ListView(padding: EdgeInsets.zero, children: [
        // ---- photo carousel ----
        _carousel(),

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
                    Expanded(
                      child: OutlinedButton.icon(
                          onPressed: () => launchUrl(
                              Uri.parse(venue.website!),
                              mode: LaunchMode.externalApplication),
                          icon: const Icon(Icons.language, size: 20),
                          label: const Text('Website')),
                    ),
                  ],
                ]),
                const SizedBox(height: 16),

                // ---- wifi hero ----
                _wifiHero(),
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
                            '— help other nomads and earn coins',
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
                      'Confirm / update this venue  ·  earn ${AppConfig.coinsConfirmVenue} coins'),
                ),
                const SizedBox(height: 30),
              ]),
        ),
      ]),
    );
  }

  // ---------- widgets ----------

  Widget _carousel() {
    if (_photos.isEmpty) {
      return Container(
        height: 150,
        decoration: const BoxDecoration(gradient: Brand.gradient),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Image.asset('assets/brand/logo_mark.png',
                height: 46, color: Colors.white),
            const SizedBox(height: 8),
            const Text('No photos yet — add one & earn coins',
                style: TextStyle(color: Colors.white, fontSize: 13)),
          ]),
        ),
      );
    }
    return SizedBox(
      height: 220,
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
                  Text(
                      'Know it? Confirm this venue and earn ${AppConfig.coinsConfirmVenue} coins.',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600)),
                ]),
          ),
      ]),
    );
  }

  Widget _freshnessBadge() {
    final ago = venue.confirmedAgoLabel;
    final stale = venue.infoIsStale;
    final (text, color) = ago == null
        ? ('Not yet confirmed', Brand.amber)
        : stale
            ? ('Confirmed $ago — needs a refresh', Brand.amber)
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
