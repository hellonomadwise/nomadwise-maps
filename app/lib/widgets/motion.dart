import 'package:flutter/widgets.dart';

import '../services/ua_stub.dart' if (dart.library.html) '../services/ua_web.dart'
    as ua;

/// The app's motion rules in one place (Jonathan, 28 Oct 2026):
/// UI motion stays short (about 150 to 250ms), eases out, never
/// bounces, and nothing moves for someone who turned on "Reduce
/// motion" on their device: it simply appears.
class Motion {
  Motion._();

  static bool? _web;

  /// True when the device asks for less motion: the setting Flutter
  /// passes on, or the browser's prefers-reduced-motion on the web.
  static bool reduced(BuildContext context) {
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return true;
    return _web ??= ua.prefersReducedMotion();
  }

  /// [d], or no time at all when motion is reduced.
  static Duration of(BuildContext context, Duration d) =>
      reduced(context) ? Duration.zero : d;

  /// Scroll a list to [offset]: a short glide, or a jump when motion
  /// is reduced (a scroll animation cannot take no time).
  static Future<void> scrollTo(
      BuildContext context, ScrollController c, double offset,
      {Duration duration = const Duration(milliseconds: 220),
      Curve curve = Curves.easeOut}) {
    if (!c.hasClients) return Future.value();
    if (reduced(context)) {
      c.jumpTo(offset);
      return Future.value();
    }
    return c.animateTo(offset, duration: duration, curve: curve);
  }

  /// Turn a page of a PageView: a short slide, or straight there when
  /// motion is reduced.
  static Future<void> toPage(
      BuildContext context, PageController c, int page,
      {Duration duration = const Duration(milliseconds: 220),
      Curve curve = Curves.easeOutCubic}) {
    if (!c.hasClients) return Future.value();
    if (reduced(context)) {
      c.jumpToPage(page);
      return Future.value();
    }
    return c.animateToPage(page, duration: duration, curve: curve);
  }
}
