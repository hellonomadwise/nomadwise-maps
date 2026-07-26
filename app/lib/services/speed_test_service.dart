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

  /// The measurement runs for a genuine window of this many seconds:
  /// downloads repeat until the window is filled, and the reported
  /// speed is total bytes over total time across all of them. A "10
  /// second test" that finished in one second produced numbers nobody
  /// should trust, and trust is the product.
  static const measureWindowSecs = 10;

  /// Runs a warm-up download (ignored, wakes the connection up) and
  /// then measures for the full window. [onProgress] is time-based,
  /// so the bar reflects the real test duration.
  /// Returns Mbps, or null if the connection failed.
  static Future<double?> measureMbps(
      {void Function(String phase)? onPhase,
      void Function(double progress)? onProgress}) async {
    try {
      onPhase?.call('Warming up…');
      onProgress?.call(0);
      final t0 = DateTime.now().millisecondsSinceEpoch;
      await _timedDownload(t0,
          onProgress: (f) => onProgress?.call(f * 0.15));
      onProgress?.call(0.15);

      onPhase?.call('Measuring ($measureWindowSecs s)…');
      final window = Stopwatch()..start();
      var totalBytes = 0;
      var round = 1;
      while (window.elapsed.inSeconds < measureWindowSecs &&
          round <= 12) {
        final before = window.elapsedMilliseconds;
        totalBytes += await _timedDownloadBytes(t0 + round,
            onProgress: (_) => onProgress?.call((0.15 +
                    0.85 *
                        window.elapsedMilliseconds /
                        (measureWindowSecs * 1000))
                .clamp(0.0, 0.99)));
        // A download that returned instantly (tiny file, cache edge
        // case) must not spin the loop; give the clock a beat.
        if (window.elapsedMilliseconds - before < 50) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        round++;
      }
      window.stop();
      final secs = window.elapsedMilliseconds / 1000.0;
      if (totalBytes == 0 || secs <= 0) return null;
      onProgress?.call(1);
      final mbps = totalBytes * 8 / secs / 1e6;
      return double.parse(mbps.toStringAsFixed(1));
    } catch (_) {
      return null;
    }
  }

  /// Like [_timedDownload] but returns the byte count, so the caller
  /// can aggregate across rounds.
  static Future<int> _timedDownloadBytes(int cacheBust,
      {void Function(double frac)? onProgress}) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', _testUrl(cacheBust))
        ..headers['Cache-Control'] = 'no-store';
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
      return received;
    } finally {
      client.close();
    }
  }
}
