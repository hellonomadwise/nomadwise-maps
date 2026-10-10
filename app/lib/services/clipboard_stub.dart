/// Outside a browser there is no rich clipboard: the caller falls back
/// to plain text.
Future<bool> copyRich(String html, String text) async => false;
