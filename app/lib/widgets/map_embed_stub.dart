import 'package:flutter/material.dart';

/// Away from the web there is no frame to show the map in: the drawn
/// stand-in is shown instead.
class MapEmbedView extends StatelessWidget {
  final String url;
  final double height;
  final Widget fallback;
  const MapEmbedView(
      {super.key, required this.url, this.height = 260, required this.fallback});

  @override
  Widget build(BuildContext context) => fallback;
}
