/// Per-install configuration and compiled-in fallbacks.
///
/// Everything below is a FALLBACK only. The live values are read from the
/// `zone_config` table at startup, so the shop zone and its radii can be
/// changed from the dashboard without rebuilding the APK.
class Config {
  // --- Supabase (from your project's Settings > API) ---
  static const String supabaseUrl  = 'https://jidfnenvbtpzvtbruojg.supabase.co';
  static const String supabaseAnon = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImppZGZuZW52YnRwenZ0YnJ1b2pnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ3NTU5NTQsImV4cCI6MjEwMDMzMTk1NH0.R2SCsgiuFhsqi2DBUbB6vSjQxMQVLwIKUs_SRnQO5zg';   // anon (public) key

  // --- Fallback employee (employees.id UUID) ---
  // With the name picker, each phone chooses its person on first launch and
  // that choice is stored on the device. This value is only a fallback used
  // if somehow nothing was picked yet. One shared APK serves everyone.
  static const String employeeId = 'b6623746-83a4-4ef8-97df-72ed1ec35c2c';

  // --- Shop geofence fallbacks ---
  static const double zoneLat = 53.513522;
  static const double zoneLon = -113.357603;

  /// Enter this radius -> clock in.
  static const double clockInRadiusM = 100;

  /// Leave THIS radius -> clock out. Deliberately larger than the clock-in
  /// radius: the band between the two is what stops GPS jitter at the boundary
  /// punching someone in and out all day.
  ///
  /// Android's own guidance is to use a radius of at least 100 m, and to expect
  /// larger radii to be more reliable. 200 m costs a few seconds of paid time
  /// while driving off the property and buys a materially more dependable exit.
  static const double clockOutRadiusM = 200;

  /// Shop Wi-Fi network. A phone joined to this SSID counts as on site even
  /// when GPS is useless indoors. Empty string = GPS only.
  static const String shopWifiSsid = 'PPC-SHOP';

  // ---------------------------------------------------------------------------
  //  REMOVED ON 29 JULY 2026, and worth recording why.
  //
  //  `geofenceProximityRadiusM` used to live here, set to 2000 m after being
  //  tuned up from 400. It was the tell that the whole design was wrong, and it
  //  went unquestioned for three days.
  //
  //  A geofence registered with the operating system needs no proximity radius:
  //  the OS watches the boundary itself and starts the app when it is crossed.
  //  That setting only existed because the old library ran its own tracking
  //  engine inside this app's process, and had to decide when to bother
  //  watching. The right response was to ask why the setting existed at all,
  //  not to keep raising the number.
  //
  //  `heartbeatSeconds` is gone for a related reason: it never fired on Android
  //  while the phone was stationary, which is precisely the case that mattered.
  //
  //  Fence identifiers now live next to the code that registers them, in
  //  geofence.dart (kFenceIn / kFenceOut).
  // ---------------------------------------------------------------------------
}
