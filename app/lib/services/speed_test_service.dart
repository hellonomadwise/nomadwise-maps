import 'dart:async';

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

  /// One timed download. Reports byte progress where the platform
  /// allows streaming, and gives up rather than hang: 20 s to make
  /// the connection, 25 s of mid-download silence, 60 s overall.
  static Future<double> _timedDownload(int cacheBust,
      {void Function(double frac)? onProgress}) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', _testUrl(cacheBust))
        ..headers['Cache-Control'] = 'no-store';
      final sw = Stopwatch()..start();
      final resp =
          await client.send(req).timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) throw Exception('download failed');
      final total = resp.contentLength ?? 4194304;
      var received = 0;
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      await for (final chunk
          in resp.stream.timeout(const Duration(seconds: 25))) {
        received += chunk.length;
        if (total > 0) {
          onProgress?.call((received / total).clamp(0.0, 1.0));
        }
        if (DateTime.now().isAfter(deadline)) break;
      }
      sw.stop();
      if (received == 0) throw Exception('empty download');
      final secs = sw.elapsedMilliseconds / 1000.0;
      return received * 8 / secs / 1e6; // Mbps
    } finally {
      client.close();
    }
  }

  /// Runs the test (a warm-up plus up to two timed rounds, best
  /// result wins). [onProgress] receives the overall 0..1 across all
  /// rounds. On very slow connections the second round is skipped:
  /// one honest measurement beats a five minute wait.
  /// Returns Mbps, or null if the connection failed.
  static Future<double?> measureMbps(
      {void Function(String phase)? onPhase,
      void Function(double progress)? onProgress}) async {
    try {
      onPhase?.call('Warming up…');
      onProgress?.call(0);
      final t0 = DateTime.now().millisecondsSinceEpoch;
      await _timedDownload(t0,
          onProgress: (f) => onProgress?.call(f / 3));
      onProgress?.call(1 / 3);
      double best = 0;
      var tookSecs = 0;
      for (var i = 1; i <= 2; i++) {
        if (i == 2 && tookSecs > 20) break; // slow wifi: one round is enough
        onPhase?.call('Measuring download ($i/2)…');
        final sw = Stopwatch()..start();
        final m = await _timedDownload(t0 + i,
            onProgress: (f) => onProgress?.call((i + f) / 3));
        sw.stop();
        tookSecs = sw.elapsed.inSeconds;
        onProgress?.call((i + 1) / 3);
        if (m > best) best = m;
      }
      onProgress?.call(1);
      return double.parse(best.toStringAsFixed(1));
    } catch (_) {
      return null;
    }
  }
}
