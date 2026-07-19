import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import '../config.dart';

class LocationService {
  /// Rough location from the internet connection (city level, no
  /// permission popup). VPN users get their VPN's city; the precise
  /// GPS fix corrects that when granted.
  static Future<(double, double)?> ipLocate() async {
    try {
      final res = await http
          .get(Uri.parse('https://get.geojs.io/v1/ip/geo.json'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final lat = double.tryParse('${j['latitude']}');
      final lng = double.tryParse('${j['longitude']}');
      if (lat == null || lng == null) return null;
      return (lat, lng);
    } catch (_) {
      return null;
    }
  }

  /// Returns the user's position, or null if permission is denied /
  /// unavailable. Callers fall back to the Lisbon default centre.
  static Future<Position?> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
    } catch (_) {
      return null;
    }
  }

  static (double, double) fallback() =>
      (AppConfig.fallbackLat, AppConfig.fallbackLng);
}
