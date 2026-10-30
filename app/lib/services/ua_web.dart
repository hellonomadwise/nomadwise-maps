// ignore: deprecated_member_use
import 'dart:html' as html;
// ignore: deprecated_member_use
import 'dart:js_util' as js_util;

/// Web: the browser's user agent string.
String userAgent() => html.window.navigator.userAgent;

/// Web: true when the browser is driven by automation (bots,
/// crawlers, test harnesses set this flag).
bool isWebdriver() => html.window.navigator.webdriver == true;

/// Web: the page the visitor came from, as the browser reports it
/// (often only the origin for cross-site links).
String referrer() => html.document.referrer;

/// Web: the time zone the device's clock is set to, as the browser
/// names it ("Asia/Bangkok"); empty when it cannot be read. A VPN
/// moves where a connection seems to be, not this.
String timeZone() {
  try {
    final intl = js_util.getProperty<Object?>(html.window, 'Intl');
    if (intl == null) return '';
    final format = js_util.callMethod<Object?>(intl, 'DateTimeFormat', []);
    if (format == null) return '';
    final options =
        js_util.callMethod<Object?>(format, 'resolvedOptions', []);
    if (options == null) return '';
    final zone = js_util.getProperty<Object?>(options, 'timeZone');
    return zone is String ? zone : '';
  } catch (_) {
    return '';
  }
}

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

/// Web: true when the visitor turned on "Reduce motion" on their
/// device (the browser's prefers-reduced-motion).
bool prefersReducedMotion() {
  try {
    return html.window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  } catch (_) {
    return false;
  }
}

// ---- the browser's Back and Forward on a form with steps ----

void Function(int? depth)? _stepPop;
bool _stepPopWired = false;

/// Web: adds a browser history entry for a step of a form (the claim
/// page), so the browser's Back goes to the step before instead of
/// leaving the page. Added while the visitor taps, so Chrome does not
/// skip it on Back. Marked as the app framework's own kind of entry
/// ('flutter': true), which it leaves alone. Returns true on the web.
bool pushStep(int depth) {
  try {
    html.window.history.pushState(
        {'flutter': true, 'claimStep': depth}, '', html.window.location.href);
    return true;
  } catch (_) {
    return false;
  }
}

/// Web: moves [delta] entries through the browser history (-1 is Back).
void goHistory(int delta) => html.window.history.go(delta);

/// Web: [cb] gets the step of the entry the browser moved to with Back
/// or Forward: the depth given to [pushStep], or null for the page's
/// own entry. The very first entry ('origin') is the app framework's,
/// which turns it into a back event of its own, so it is skipped here.
void setStepPopHandler(void Function(int? depth)? cb) {
  _stepPop = cb;
  if (_stepPopWired) return;
  _stepPopWired = true;
  // Capturing, so it runs before the app framework's own listener, and
  // stops these events there: only the origin entry is the framework's
  // to handle (it turns it into a back event).
  html.window.addEventListener('popstate', (e) {
    final s = (e as html.PopStateEvent).state;
    if (s is! Map || s['flutter'] != true) return;
    e.stopImmediatePropagation();
    final d = s['claimStep'];
    _stepPop?.call(d is num ? d.toInt() : null);
  }, true);
}

/// Web: the step depth of the history entry the page is on now (after
/// a reload, or back from Stripe), or null.
int? currentStep() {
  try {
    final s = html.window.history.state;
    final d = s is Map ? s['claimStep'] : null;
    return d is num ? d.toInt() : null;
  } catch (_) {
    return null;
  }
}
