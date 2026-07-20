// ignore: deprecated_member_use
import 'dart:html' as html;

/// Web: the browser's user agent string.
String userAgent() => html.window.navigator.userAgent;

/// Web: true when the browser is driven by automation (bots,
/// crawlers, test harnesses set this flag).
bool isWebdriver() => html.window.navigator.webdriver == true;
