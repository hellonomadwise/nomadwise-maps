// ignore: deprecated_member_use
import 'dart:html' as html;

/// Web: changes the address in the browser's bar without loading
/// anything, so a reload opens the same screen (Jonathan, 22 Oct 2026:
/// reloading the control centre took him to the map). The browser's
/// own state and any #part are kept, so Back keeps working.
void setAddress(String pathAndQuery) {
  try {
    final loc = html.window.location;
    final now = '${loc.pathname}${loc.search}';
    if (now == pathAndQuery) return;
    html.window.history
        .replaceState(html.window.history.state, '', '$pathAndQuery${loc.hash}');
  } catch (_) {}
}
