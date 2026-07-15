import 'package:geolocator/geolocator.dart';
import '../config.dart';

class LocationService {
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
