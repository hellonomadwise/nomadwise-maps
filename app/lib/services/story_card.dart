import 'dart:math' as math;
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
      // Star drawn by hand: the bundled font has no star glyph.
      final ratingText =
          '${v.rating}${v.reviewCount != null ? ' (${v.reviewCount})' : ''}';
      final tp = TextPainter(
        text: TextSpan(
            text: ratingText,
            style: const TextStyle(
                fontFamily: 'InstrumentSans',
                fontSize: 38,
                fontWeight: FontWeight.w600,
                color: Color(0xFFF4B23E),
                height: 1.25)),
        textDirection: TextDirection.ltr,
      )..layout();
      const starR = 20.0;
      final total = starR * 2 + 14 + tp.width;
      final x0 = (_w - total) / 2;
      final rowY = y + 14;
      _star(
          c,
          Offset(x0 + starR, rowY + tp.height / 2),
          starR,
          const Color(0xFFF4B23E));
      tp.paint(c, Offset(x0 + starR * 2 + 14, rowY));
      y = rowY + tp.height;
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
        v.wifiTested
            ? '${v.wifiSpeedLabel} Mbps'
            : 'Not tested yet'
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

    // ---- green pills: one per upside the space has ----
    // Only what is known to be true is shown; a space with nothing
    // checked yet gets one quiet grey pill instead of a list of
    // unknowns. "No laptops" is the one downside worth saying.
    final ups = <String>[
      if (v.laptopsAllowed == true) 'Laptops welcome',
      if (v.powerOutlets == true) 'Plug sockets',
      if (v.goodForCalls == true) 'Good for calls',
      if (v.quietSpace == true) 'Quiet',
      if (v.comfortableSeating == true) 'Comfy seats',
      if (v.aircon == true) 'Aircon',
      if (v.access24h == true) '24h access',
      if (v.callRoom == true) 'Call room',
      if (v.monitorAvailable == true) 'Monitor',
      if (v.officeChairs == true) 'Office chairs',
      if (v.cozy == true) 'Cozy',
    ];
    if (v.laptopsAllowed == false) {
      _pills(c, ['No laptops'], ry + 16, const Color(0xFFD64545));
    } else if (ups.isEmpty) {
      _pills(c, ['Facts not checked yet'], ry + 16,
          Colors.white.withValues(alpha: .22));
    } else {
      _pills(c, ups, ry + 16, const Color(0xFF2E9E5B), tick: true);
    }

    // ---- link pill ----
    final pill = RRect.fromRectAndRadius(
        Rect.fromLTWH(90, _h - 250, _w - 180, 104),
        const Radius.circular(52));
    c.drawRRect(pill, Paint()..color = Colors.white);
    _text(
        c,
        'nomadmaps.io',
        37,
        FontWeight.w700,
        const Color(0xFF142032),
        y: _h - 250 + 31);

    final img =
        await rec.endRecording().toImage(_w.toInt(), _h.toInt());
    final bytes =
        await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  }

  /// Rounded pills laid out in centred rows, at most three rows.
  static void _pills(Canvas c, List<String> labels, double top, Color fill,
      {bool tick = false}) {
    const h = 78.0, pad = 30.0, gap = 18.0, size = 32.0;
    const tickW = 30.0;
    final painters = <TextPainter>[];
    final widths = <double>[];
    for (final s in labels) {
      final tp = TextPainter(
        text: TextSpan(
            text: s,
            style: const TextStyle(
                fontFamily: 'InstrumentSans',
                fontSize: size,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                height: 1.2)),
        textDirection: TextDirection.ltr,
      )..layout();
      painters.add(tp);
      widths.add(pad + (tick ? tickW + 12 : 0) + tp.width + pad);
    }
    // Break into rows that fit the card width.
    final rows = <List<int>>[[]];
    var rowW = 0.0;
    for (var i = 0; i < labels.length; i++) {
      final w = widths[i] + (rows.last.isEmpty ? 0 : gap);
      if (rows.last.isNotEmpty && rowW + w > _w - 160) {
        if (rows.length == 3) break;
        rows.add([i]);
        rowW = widths[i];
      } else {
        rows.last.add(i);
        rowW += w;
      }
    }
    var y = top;
    for (final row in rows) {
      final total = row.fold(0.0, (a, i) => a + widths[i]) +
          gap * (row.length - 1);
      var x = (_w - total) / 2;
      for (final i in row) {
        c.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(x, y, widths[i], h),
                const Radius.circular(h / 2)),
            Paint()..color = fill);
        var tx = x + pad;
        if (tick) {
          final p = Path()
            ..moveTo(tx + 3, y + h / 2 + 1)
            ..lineTo(tx + 11, y + h / 2 + 9)
            ..lineTo(tx + tickW - 4, y + h / 2 - 11);
          c.drawPath(
              p,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 5
                ..strokeCap = StrokeCap.round
                ..strokeJoin = StrokeJoin.round
                ..color = Colors.white);
          tx += tickW + 12;
        }
        painters[i].paint(c, Offset(tx, y + (h - painters[i].height) / 2));
        x += widths[i] + gap;
      }
      y += h + 16;
    }
  }

  /// A five-point star, filled.
  static void _star(Canvas c, Offset center, double r, Color color) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final rad = i.isEven ? r : r * .45;
      final a = -math.pi / 2 + i * math.pi / 5;
      final p = Offset(center.dx + rad * math.cos(a),
          center.dy + rad * math.sin(a));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    c.drawPath(path, Paint()..color = color);
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
