// ignore: deprecated_member_use
import 'dart:html' as html_lib;
// ignore: deprecated_member_use
import 'dart:js_util' as js_util;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

/// On the web: the styled email exactly as it is sent (the same HTML),
/// in a frame of its own so its styles do not touch the app. The frame
/// grows to the email's full height and lets the page scroll over it.
/// With a mouse, the words can be selected and the links open in a new
/// tab (Jonathan, 22 Oct 2026); the mouse wheel is handed back to the
/// page so scrolling over the email still scrolls the screen. On a
/// touch screen the frame stays untouchable, so a swipe always scrolls.
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
    final doc = _withNewTabLinks(widget.html);
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      final mouse = html_lib.window.matchMedia('(pointer: fine)').matches;
      final frame = html_lib.IFrameElement()
        ..srcdoc = doc
        ..style.border = '0'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.pointerEvents = mouse ? 'auto' : 'none';
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
          if (mouse && d != null) _passWheelToPage(frame, d);
        } catch (_) {}
      });
      return frame;
    });
  }

  /// Links in the email open in a new tab, never inside the preview.
  static String _withNewTabLinks(String html) {
    const base = '<base target="_blank">';
    final i = html.toLowerCase().indexOf('<head>');
    return i < 0
        ? base + html
        : html.substring(0, i + 6) + base + html.substring(i + 6);
  }

  /// The frame is as tall as the email, so it never scrolls itself; a
  /// wheel turn over it is sent on to the page, which scrolls instead.
  static void _passWheelToPage(html_lib.IFrameElement frame, Object doc) {
    num n(Object e, String k) =>
        (js_util.getProperty<Object?>(e, k) as num?) ?? 0;
    bool b(Object e, String k) =>
        js_util.getProperty<Object?>(e, k) == true;
    js_util.callMethod<void>(doc, 'addEventListener', [
      'wheel',
      js_util.allowInterop((Object e) {
        js_util.callMethod<void>(e, 'preventDefault', const []);
        final r = frame.getBoundingClientRect();
        frame.dispatchEvent(html_lib.WheelEvent('wheel',
            deltaX: n(e, 'deltaX'),
            deltaY: n(e, 'deltaY'),
            deltaMode: n(e, 'deltaMode').toInt(),
            clientX: (n(e, 'clientX') + r.left).round(),
            clientY: (n(e, 'clientY') + r.top).round(),
            ctrlKey: b(e, 'ctrlKey'),
            shiftKey: b(e, 'shiftKey')));
      }),
      js_util.jsify({'passive': false}),
    ]);
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
