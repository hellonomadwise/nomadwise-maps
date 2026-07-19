import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/venue.dart';

/// Draws a 1080x1920 Instagram-story style card for a space:
/// photo (or brand gradient) background, the space's work facts in
/// glassy rows, and the app link. Every share is a little advert.
class StoryCard {
  static const double _w = 1080, _h = 1920;

  static Future<Uint8List?> build(Venue v, {ui.Image? photo}) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    const rect = Rect.fromLTWH(0, 0, _w, _h);

    // ---- background ----
    if (photo != null) {
      paintImage(
          canvas: c, rect: rect, image: photo, fit: BoxFit.cover);
      // Darken for text legibility, heavier at the bottom.
      c.drawRect(
          rect,
          Paint()
            ..shader = ui.Gradient.linear(
                const Offset(0, 0), const Offset(0, _h), [
              const Color(0x66000000),
              const Color(0x40000000),
              const Color(0xB3000000),
            ], [
              0.0,
              0.45,
              1.0
            ]));
    } else {
      c.drawRect(
          rect,
          Paint()
            ..shader = ui.Gradient.linear(
                Offset.zero, const Offset(_w, _h), [
              const Color(0xFFFF5A63),
              const Color(0xFFF4303C),
            ]));
    }

    // ---- logo + wordmark ----
    try {
      final data = await rootBundle.load('assets/brand/app_icon.png');
      final codec = await ui.instantiateImageCodec(
          data.buffer.asUint8List(),
          targetWidth: 150);
      final icon = (await codec.getNextFrame()).image;
      paintImage(
          canvas: c,
          rect: const Rect.fromLTWH(_w / 2 - 75, 110, 150, 150),
          image: icon,
          fit: BoxFit.contain);
    } catch (_) {}
    _text(c, 'nomadwise maps', 42, FontWeight.w700, Colors.white,
        y: 285);

    // ---- headline ----
    var y = _text(c, 'I found a place to work', 40, FontWeight.w500,
        Colors.white.withValues(alpha: .85),
        y: 720);
    y = _text(c, v.name, 76, FontWeight.w700, Colors.white,
        y: y + 16, maxLines: 2);
    if (v.rating != null) {
      y = _text(
          c,
          '★ ${v.rating}${v.reviewCount != null ? ' (${v.reviewCount})' : ''}',
          38,
          FontWeight.w600,
          const Color(0xFFF4B23E),
          y: y + 14);
    }

    // ---- glassy fact rows ----
    final place = [
      if (v.neighbourhood != null && v.neighbourhood!.isNotEmpty)
        v.neighbourhood!,
      if (v.city != null && v.city!.isNotEmpty) v.city!,
    ].join(', ');
    final rows = <(String, String)>[
      ('Where', place.isEmpty ? 'On the nomad map' : place),
      (
        'WiFi',
        v.wifiSpeedMbps != null
            ? '${v.wifiSpeedMbps} Mbps'
            : 'Not tested yet'
      ),
      (
        'Laptops',
        switch (v.laptopsAllowed) {
          true => 'Welcome',
          false => 'Not allowed',
          null => 'Unknown',
        }
      ),
    ];
    var ry = y + 60;
    for (final (label, value) in rows) {
      final rr = RRect.fromRectAndRadius(
          Rect.fromLTWH(80, ry, _w - 160, 96),
          const Radius.circular(28));
      c.drawRRect(
          rr, Paint()..color = Colors.white.withValues(alpha: .22));
      _text(c, label, 36, FontWeight.w500,
          Colors.white.withValues(alpha: .9),
          y: ry + 27, x: 120, align: TextAlign.left);
      _text(c, value, 36, FontWeight.w700, Colors.white,
          y: ry + 27, x: 120, align: TextAlign.right);
      ry += 116;
    }

    // ---- link pill ----
    final pill = RRect.fromRectAndRadius(
        Rect.fromLTWH(90, _h - 300, _w - 180, 104),
        const Radius.circular(52));
    c.drawRRect(pill, Paint()..color = Colors.white);
    _text(
        c,
        'hellonomadwise.github.io/nomadwise-maps',
        37,
        FontWeight.w700,
        const Color(0xFF142032),
        y: _h - 300 + 31);
    _text(
        c,
        'Find work-friendly cafes worldwide. Earn coins for helping.',
        30,
        FontWeight.w500,
        Colors.white.withValues(alpha: .9),
        y: _h - 160);

    final img =
        await rec.endRecording().toImage(_w.toInt(), _h.toInt());
    final bytes =
        await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  }

  /// Draws a line (or two) of text; returns the y just below it.
  static double _text(Canvas c, String s, double size, FontWeight w,
      Color color,
      {required double y,
      double x = 80,
      TextAlign align = TextAlign.center,
      int maxLines = 1}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(
              fontFamily: 'InstrumentSans',
              fontSize: size,
              fontWeight: w,
              color: color,
              height: 1.25)),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: _w - 2 * x);
    final dx = switch (align) {
      TextAlign.left => x,
      TextAlign.right => _w - x - tp.width,
      _ => (_w - tp.width) / 2,
    };
    tp.paint(c, Offset(dx, y));
    return y + tp.height;
  }
}
