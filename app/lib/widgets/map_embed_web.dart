// ignore: deprecated_member_use
import 'dart:html' as html_lib;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

/// On the web: the Google map as the live page shows it, in a frame
/// (Google's free embed, no key, no charge). With a mouse it can be
/// moved and zoomed like on the page; on a touch screen it stays
/// untouchable, so a swipe over it still scrolls the screen.
class MapEmbedView extends StatefulWidget {
  final String url;
  final double height;
  final Widget fallback; // unused on the web
  const MapEmbedView(
      {super.key, required this.url, this.height = 260, required this.fallback});

  @override
  State<MapEmbedView> createState() => _MapEmbedViewState();
}

// One view type per address, registered once (the registry cannot
// take a name twice).
final Map<String, String> _types = {};

class _MapEmbedViewState extends State<MapEmbedView> {
  String _typeFor(String url) => _types.putIfAbsent(url, () {
        final t = 'nw-map-embed-${_types.length}';
        ui_web.platformViewRegistry.registerViewFactory(t, (int _) {
          final mouse = html_lib.window.matchMedia('(pointer: fine)').matches;
          return html_lib.IFrameElement()
            ..src = url
            ..style.border = '0'
            ..style.width = '100%'
            ..style.height = '100%'
            ..style.pointerEvents = mouse ? 'auto' : 'none'
            ..setAttribute('loading', 'lazy')
            ..setAttribute('referrerpolicy', 'no-referrer-when-downgrade');
        });
        return t;
      });

  @override
  Widget build(BuildContext context) {
    final t = _typeFor(widget.url);
    return SizedBox(
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: HtmlElementView(key: ValueKey(t), viewType: t),
      ),
    );
  }
}
