// ignore: deprecated_member_use
import 'dart:html' as html;
// ignore: deprecated_member_use
import 'dart:js_util' as js_util;

/// Web: puts a designed email on the clipboard as both HTML and plain
/// text, so pasting it into a mail program (Spark) keeps the button,
/// links and signature, and a plain-text field still gets the words.
/// False when the browser does not allow it; the caller then copies
/// the plain text.
Future<bool> copyRich(String htmlText, String text) async {
  try {
    final ctor = js_util.getProperty<Object?>(html.window, 'ClipboardItem');
    final clip =
        js_util.getProperty<Object?>(html.window.navigator, 'clipboard');
    if (ctor == null || clip == null) return false;
    final items = js_util.newObject<Object>();
    js_util.setProperty(items, 'text/html', html.Blob([htmlText], 'text/html'));
    js_util.setProperty(items, 'text/plain', html.Blob([text], 'text/plain'));
    final item = js_util.callConstructor<Object>(ctor, [items]);
    final list = js_util.callConstructor<Object>(
        js_util.getProperty<Object>(html.window, 'Array'), []);
    js_util.callMethod<Object?>(list, 'push', [item]);
    await js_util.promiseToFuture<Object?>(
        js_util.callMethod<Object>(clip, 'write', [list]));
    return true;
  } catch (_) {
    return false;
  }
}
