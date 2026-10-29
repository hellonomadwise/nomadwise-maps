// ignore: deprecated_member_use
import 'dart:html' as html;
// ignore: deprecated_member_use
import 'dart:js_util' as js_util;

Object? _ctx;

/// Web: one soft piano-like note through the browser's Web Audio
/// (a sine with a faint octave and twelfth, fast attack, long decay).
/// Jonathan, 29 Oct 2026: "a high key pitch piano ... bing, bong",
/// and a chime when a bead lands. Browsers only play sound after the
/// person has tapped something, so the first Replay is silent until
/// Sound is switched on with a tap.
void playNote(double hz, double seconds, double volume, {double delay = 0}) {
  try {
    final w = html.window;
    _ctx ??= js_util.callConstructor(
        js_util.getProperty(w, 'AudioContext') ??
            js_util.getProperty(w, 'webkitAudioContext'),
        []);
    final ctx = _ctx;
    if (ctx == null) return;
    if (js_util.getProperty(ctx, 'state') == 'suspended') {
      js_util.callMethod(ctx, 'resume', []);
    }
    final now = (js_util.getProperty(ctx, 'currentTime') as num).toDouble() + delay;
    final dest = js_util.getProperty(ctx, 'destination');
    for (final part in [(1.0, 1.0), (2.0, .25), (3.0, .06)]) {
      final o = js_util.callMethod(ctx, 'createOscillator', []);
      final g = js_util.callMethod(ctx, 'createGain', []);
      js_util.setProperty(o, 'type', 'sine');
      js_util.setProperty(js_util.getProperty(o, 'frequency'), 'value', hz * part.$1);
      final gain = js_util.getProperty(g, 'gain');
      js_util.callMethod(gain, 'setValueAtTime', [.0001, now]);
      js_util.callMethod(gain, 'exponentialRampToValueAtTime', [volume * part.$2, now + .008]);
      js_util.callMethod(gain, 'exponentialRampToValueAtTime', [.0001, now + seconds]);
      js_util.callMethod(js_util.callMethod(o, 'connect', [g]), 'connect', [dest]);
      js_util.callMethod(o, 'start', [now]);
      js_util.callMethod(o, 'stop', [now + seconds]);
    }
  } catch (_) {}
}
