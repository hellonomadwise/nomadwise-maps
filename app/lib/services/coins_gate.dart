/// Coins are for remote workers (Customers) only. An account in the
/// Owners group (it runs a cafe, coworking or coliving space) never
/// sees coin counts, coin rewards or coin wording (29 Sep 2026).
/// Set from the signed-in profile; false for everyone else.
class CoinsGate {
  static bool off = false;

  /// [withCoins] for Customers, [without] for Owners.
  static String t(String withCoins, String without) =>
      off ? without : withCoins;
}
