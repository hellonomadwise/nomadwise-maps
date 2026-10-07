import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:share_plus/share_plus.dart';

import '../models/venue.dart';
import 'analytics_service.dart';

/// Sharing a space as a link that opens that exact place on the map.
/// Works for any place Google knows, screened or not: the link carries
/// the place's Google id and the app finds it and flies there.
class SpaceShare {
  static String link(String? placeId) {
    if (placeId == null || placeId.isEmpty) return 'https://nomadmaps.io/';
    // Short on purpose: the app finds the space and flies there itself.
    return 'https://nomadmaps.io/?p=${Uri.encodeComponent(placeId)}';
  }

  /// The message that goes with a shared space: its name, and where it
  /// is only when the name does not already say (region and country).
  static String venueText(Venue venue) {
    final name = venue.name.trim();
    final region = (venue.city ?? '').trim();
    final country =
        ('${venue.raw['country'] ?? venue.live?.country ?? ''}').trim();
    final hood = (venue.neighbourhood ?? '').trim();
    final plainName = plain(name);
    final saysWhere = [hood, region, country]
        .where((x) => x.length >= 3)
        .any((x) => plainName.contains(plain(x)));
    final where = saysWhere
        ? ''
        : [region, country].where((x) => x.isNotEmpty).join(', ');
    final wifi =
        venue.wifiTested ? ' WiFi ${venue.wifiSpeedLabel} Mbps.' : '';
    return '$name${where.isEmpty ? '' : ', $where'}.$wifi\n'
        '${link(venue.googlePlaceId)}';
  }

  /// A place nobody has screened yet: we only know its name.
  static String placeText(String name, String placeId) =>
      '${name.trim()}\n${link(placeId)}';

  /// Lower case without accents, so "São Bento" matches "Sao Bento".
  static String plain(String s) {
    const from = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿ';
    const to = 'aaaaaaceeeeiiiinooooouuuuyy';
    final lower = s.toLowerCase();
    final b = StringBuffer();
    for (final ch in lower.split('')) {
      final i = from.indexOf(ch);
      b.write(i >= 0 ? to[i] : ch);
    }
    return b.toString();
  }

  /// Phones have a share sheet (WhatsApp, Messages and so on). On a
  /// computer the useful thing is the link itself, ready to paste.
  static bool get _hasShareSheet =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  /// Share from a card on the map: the words and the link, no picture.
  static Future<void> send(
    BuildContext context, {
    required String name,
    required String text,
    required String link,
    required bool screened,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    Analytics.capture('space_shared',
        {'venue': name, 'from': 'card', 'screened': screened});
    if (_hasShareSheet) {
      try {
        await Share.share(text);
        return;
      } catch (_) {
        // No share sheet after all: fall through to copying the link.
      }
    }
    try {
      await Clipboard.setData(ClipboardData(text: link));
      messenger?.showSnackBar(const SnackBar(
          content: Text('Link copied. Paste it wherever you like.')));
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(link)));
    }
  }
}
