// ignore: deprecated_member_use
import 'dart:html' as html_lib;
// ignore: deprecated_member_use
import 'dart:js_util' as js_util;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

/// On the web: the styled email exactly as it is sent (the same HTML),
/// in a frame of its own so its styles do not touch the app. The frame
/// grows to the email's full height and lets the page scroll over it.
class EmailHtmlView extends StatefulWidget {
  final String html;
  final String text;
  final double height;
  const EmailHtmlView(
      {super.key, required this.html, required this.text, this.height = 560});

  @override
  State<EmailHtmlView> createState() => _EmailHtmlViewState();
}

int _views = 0;

class _EmailHtmlViewState extends State<EmailHtmlView> {
  late String _viewType;
  double? _measured;

  void _register() {
    _viewType = 'nw-email-preview-${_views++}';
    final doc = widget.html;
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      final frame = html_lib.IFrameElement()
        ..srcdoc = doc
        ..style.border = '0'
        ..style.width = '100%'
        ..style.height = '100%'
        // a preview: the page scrolls over it, nothing in it is pressed
        ..style.pointerEvents = 'none';
      frame.onLoad.listen((_) {
        try {
          final d = js_util.getProperty<Object?>(frame, 'contentDocument');
          final el =
              d == null ? null : js_util.getProperty<Object?>(d, 'documentElement');
          final h = el == null
              ? null
              : (js_util.getProperty<Object?>(el, 'scrollHeight') as num?);
          if (h != null && h > 0 && mounted) {
            setState(() => _measured = h.toDouble() + 8);
          }
        } catch (_) {}
      });
      return frame;
    });
  }

  @override
  void initState() {
    super.initState();
    _register();
  }

  @override
  void didUpdateWidget(EmailHtmlView old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) {
      _measured = null;
      _register();
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: _measured ?? widget.height,
        child: HtmlElementView(key: ValueKey(_viewType), viewType: _viewType),
      );
}
