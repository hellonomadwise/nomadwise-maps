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
/// The message is Miguel's wording (7 Oct 2026): "Hey, I want to share
/// [name] with you, a coworking space from Nomad Maps".
class SpaceShare {
  static final _idOk = RegExp(r'^[A-Za-z0-9_-]{10,200}$');

  /// nomadmaps.io/s/<Google place id>: a small page of the space's own
  /// (made at each build by scripts/share_pages.py) so the link shows
  /// the space's name, place and picture in WhatsApp and friends, and
  /// then opens the map there. A place with no page yet still opens.
  static String link(String? placeId) {
    if (placeId == null || placeId.isEmpty) return 'https://nomadmaps.io/';
    if (_idOk.hasMatch(placeId)) return 'https://nomadmaps.io/s/$placeId';
    return 'https://nomadmaps.io/?p=${Uri.encodeComponent(placeId)}';
  }

  /// "Hey, I want to share X with you, a coworking space from Nomad
  /// Maps." Without a kind (Google calls the place something else):
  /// "... with you, from Nomad Maps."
  static String _message(String name, String? kind, String link,
          {String extra = ''}) =>
      'Hey, I want to share ${name.trim()} with you, '
      '${kind == null ? '' : '$kind '}from Nomad Maps.$extra\n$link';

  /// The message that goes with a shared space. Where it is, and its
  /// picture, come with the link's own preview.
  static String venueText(Venue venue) => _message(
        venue.name,
        venue.type == 'coworking' ? 'a coworking space' : 'a cafe',
        link(venue.googlePlaceId),
        extra: venue.wifiTested
            ? ' WiFi tested at ${venue.wifiSpeedLabel} Mbps.'
            : '',
      );

  /// A place nobody has screened yet: its name and, when Google's type
  /// or the name itself says so, what it is.
  static String placeText(String name, String placeId,
      {String? primaryType}) {
    final t = primaryType ?? '';
    final String? kind =
        (t.contains('coworking') || name.toLowerCase().contains('cowork'))
            ? 'a coworking space'
            : (t == 'cafe' || t == 'coffee_shop')
                ? 'a cafe'
                : null;
    return _message(name, kind, link(placeId));
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
      await Clipboard.setData(ClipboardData(text: text));
      messenger?.showSnackBar(const SnackBar(
          content: Text('Copied. Paste it wherever you like.')));
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(link)));
    }
  }
}
