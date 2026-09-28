import 'package:flutter/material.dart';

import '../services/google_meter.dart';
import '../services/places_service.dart';

/// A Google photo (by photo name) or any image link, loaded the
/// cheap way: a photo whose free link is known shows straight away;
/// one that is not gets its link made once (PlacesService.linkFor),
/// which is then saved on the venue for everyone else.
class GooglePhoto extends StatelessWidget {
  final String name;
  final String? venueId;
  final int maxWidth;
  final double? height;
  final BoxFit fit;

  /// Called when the photo cannot be shown (an expired photo name).
  final VoidCallback? onBroken;
  final Widget loading;
  final Widget broken;

  const GooglePhoto(
    this.name, {
    super.key,
    this.venueId,
    this.maxWidth = 900,
    this.height,
    this.fit = BoxFit.cover,
    this.onBroken,
    required this.loading,
    required this.broken,
  });

  Widget _image(String url) => Image.network(
        url,
        fit: fit,
        width: double.infinity,
        height: height,
        errorBuilder: (_, __, ___) {
          onBroken?.call();
          return broken;
        },
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : loading,
      );

  @override
  Widget build(BuildContext context) {
    if (name.startsWith('http') || PlacesService.isResolved(name)) {
      return _image(PlacesService.photoUrl(name, maxWidth: maxWidth));
    }
    return FutureBuilder<String?>(
      future: PlacesService.linkFor(name, venueId: venueId),
      builder: (_, snap) {
        if (snap.connectionState != ConnectionState.done) return loading;
        if (snap.data == null) {
          // Paused by the daily Google limit: not a dead photo, so no
          // fresh names are fetched for it.
          if (!GoogleMeter.paused) onBroken?.call();
          return broken;
        }
        return _image(PlacesService.photoUrl(name, maxWidth: maxWidth));
      },
    );
  }
}
