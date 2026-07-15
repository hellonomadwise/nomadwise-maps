import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/venue.dart';
import '../theme.dart';

class VenueDetailScreen extends StatelessWidget {
  final Venue venue;
  final VoidCallback onConfirm;
  const VenueDetailScreen(
      {super.key, required this.venue, required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    final closing =
        venue.closingLabel(soonMinutes: AppConfig.closingSoonMinutes);
    return Scaffold(
      appBar: AppBar(title: Text(venue.name)),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        // ---- header: type + neighbourhood + distance ----
        Row(children: [
          Chip(
              label: Text(
                  venue.type == 'coworking' ? 'Coworking' : 'Cafe',
                  style: const TextStyle(fontSize: 12))),
          const SizedBox(width: 8),
          if (venue.neighbourhood != null)
            Text(venue.neighbourhood!,
                style: TextStyle(color: Colors.grey.shade600)),
          const Spacer(),
          Text(venue.distanceLabel(),
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 12),

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
                            fontSize: 20, fontWeight: FontWeight.w900)),
                    const SizedBox(width: 6),
                    if (venue.reviewCount != null)
                      Text('${venue.reviewCount} reviews',
                          style: TextStyle(color: Colors.grey.shade600)),
                  ] else
                    Text('No Google rating yet',
                        style: TextStyle(color: Colors.grey.shade600)),
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
                  ...venue.live!.weekdayDescriptions!.map((d) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(d,
                          style: const TextStyle(fontSize: 13)))),
                ] else if (venue.fallbackHours != null) ...[
                  const Divider(height: 24),
                  ..._fallbackHourLines(),
                ],
              ]),
        ),
        const SizedBox(height: 20),

        // ---- Nomadwise work-friendliness block ----
        const Text('CAN I WORK HERE?',
            style: TextStyle(
                color: Brand.red,
                fontWeight: FontWeight.w900,
                fontSize: 13,
                letterSpacing: 1)),
        const SizedBox(height: 10),
        _feature('Laptops allowed', venue.laptopsAllowed,
            highlight: true),
        _wifiRow(),
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
        const SizedBox(height: 16),

        // ---- links ----
        if (venue.website != null || venue.instagram != null)
          Row(children: [
            if (venue.website != null)
              TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse(venue.website!),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.language, size: 18),
                  label: const Text('Website')),
            if (venue.instagram != null)
              TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse(venue.instagram!),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.camera_alt_outlined, size: 18),
                  label: const Text('Instagram')),
          ]),
        const SizedBox(height: 12),

        // ---- confirm & earn ----
        ElevatedButton.icon(
          onPressed: () {
            Navigator.pop(context);
            onConfirm();
          },
          icon: const Icon(Icons.verified_outlined),
          label: Text(
              'Confirm / update this venue  ·  earn ${AppConfig.coinsConfirmVenue} coins'),
        ),
        const SizedBox(height: 30),
      ]),
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

  Widget _wifiRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        const Icon(Icons.wifi, size: 20, color: Brand.charcoal),
        const SizedBox(width: 10),
        const Expanded(child: Text('WiFi speed')),
        venue.wifiSpeedMbps != null
            ? Text('${venue.wifiSpeedMbps} Mbps',
                style: const TextStyle(fontWeight: FontWeight.w700))
            : Text('Not measured yet',
                style: TextStyle(color: Colors.grey.shade500)),
      ]),
    );
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
