import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

/// Measures the wifi's download speed by timing real downloads of a
/// 4 MB test file served alongside the app. The user never types a
/// number, so results can't be invented.
class SpeedTestService {
  static Uri _testUrl(int cacheBust) {
    if (kIsWeb) {
      // Same origin as the app itself.
      return Uri.base.resolve('speedtest.bin?cb=$cacheBust');
    }
    return Uri.parse(
        'https://nomadmaps.io/speedtest.bin?cb=$cacheBust');
  }

  static Future<double> _timedDownload(int cacheBust) async {
    final sw = Stopwatch()..start();
    final resp = await http.get(_testUrl(cacheBust),
        headers: {'Cache-Control': 'no-store'});
    sw.stop();
    if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
      throw Exception('download failed');
    }
    final secs = sw.elapsedMilliseconds / 1000.0;
    return resp.bodyBytes.length * 8 / secs / 1e6; // Mbps
  }

  /// Runs the test (a warm-up plus two timed rounds, best result wins).
  /// Returns Mbps, or null if the connection failed.
  static Future<double?> measureMbps(
      {void Function(String phase)? onPhase}) async {
    try {
      onPhase?.call('Warming up…');
      final t0 = DateTime.now().millisecondsSinceEpoch;
      await _timedDownload(t0);
      double best = 0;
      for (var i = 1; i <= 2; i++) {
        onPhase?.call('Measuring download ($i/2)…');
        final m = await _timedDownload(t0 + i);
        if (m > best) best = m;
      }
      return double.parse(best.toStringAsFixed(1));
    } catch (_) {
      return null;
    }
  }
}
