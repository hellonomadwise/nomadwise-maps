/// Central configuration for Nomadwise Maps.
///
/// These values are injected at build time with --dart-define, so no secret
/// lives in the source code. The GitHub Actions workflow passes them in from
/// repository secrets. For local runs you can pass them on the command line:
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Google Maps / Places key used for Places API details (rating, hours).
  /// The map widget itself gets its key from the platform config
  /// (AndroidManifest.xml / AppDelegate / index.html).
  static const googlePlacesKey = String.fromEnvironment('GOOGLE_PLACES_KEY');

  /// Deep-link used for OAuth (Google sign-in) redirects on mobile.
  static const authRedirect = 'com.nomadwise.maps://login-callback/';

  // ---- Coin economy ----
  /// Reviewing/screening a space that isn't listed yet (identity comes
  /// from Google, so it's easier than the old "add a venue" — hence 50).
  static const coinsNewVenue = 50;
  static const coinsConfirmVenue = 30;
  static const cashOutThreshold = 5000; // coins
  static const cashOutValueEuro = 50; // €

  /// Max distance (metres) from a venue for a submission's GPS check to pass.
  static const gpsVerifyRadiusM = 150.0;

  /// "Closing soon" threshold.
  static const closingSoonMinutes = 60;

  /// "Open late" filter = closes at or after this hour (22:00).
  static const openLateHour = 22;

  /// Default map centre when location is unavailable: Lisbon.
  static const fallbackLat = 38.7223;
  static const fallbackLng = -9.1393;
}
