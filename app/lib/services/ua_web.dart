// ignore: deprecated_member_use
import 'dart:html' as html;

/// Web: the browser's user agent string.
String userAgent() => html.window.navigator.userAgent;

/// Web: true when the browser is driven by automation (bots,
/// crawlers, test harnesses set this flag).
bool isWebdriver() => html.window.navigator.webdriver == true;

/// Web: the page the visitor came from, as the browser reports it
/// (often only the origin for cross-site links).
String referrer() => html.document.referrer;

/// Web: "phone" or "desktop", from the browser identity.
String deviceKind() {
  final u = html.window.navigator.userAgent.toLowerCase();
  return RegExp(r'iphone|android|mobile|ipad').hasMatch(u) ? 'phone' : 'desktop';
}

void Function()? _pageHide;
bool _pageHideWired = false;

/// Web: run [cb] when the visitor leaves the page (closes the tab,
/// goes to another site, follows a link). Pass null to stop.
void setPageHideHandler(void Function()? cb) {
  _pageHide = cb;
  if (!_pageHideWired) {
    _pageHideWired = true;
    html.window.addEventListener('pagehide', (_) => _pageHide?.call());
  }
}

/// Web: a small POST the browser finishes even after the page is gone
/// (fetch with keepalive), for the "left the page" event.
bool sendBeacon(String url, String body, [Map<String, String>? headers]) {
  try {
    html.window.fetch(url, {
      'method': 'POST',
      'keepalive': true,
      'headers': {'Content-Type': 'application/json', ...?headers},
      'body': body,
    });
    return true;
  } catch (_) {
    return false;
  }
}
