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
  /// radius: the 25 m band between the two is what stops GPS jitter at the
  /// boundary from punching you out and back in all day.
  ///
  /// This is now a real second geofence (see geofence.dart). It is NOT, as an
  /// earlier build's comment here claimed, handled by the plugin's exit
  /// debounce — `loiteringDelay` applies to DWELL events only and never had
  /// any effect on exits. The buffer did not exist until this build.
  static const double clockOutRadiusM = 125;

  /// Shop Wi-Fi network. A phone joined to this SSID counts as on site even
  /// when GPS is useless indoors. Empty string = GPS only.
  static const String shopWifiSsid = 'PPC-SHOP';

  /// How often a CLOCKED-IN phone reports its position, in seconds. Pings stop
  /// entirely when off the clock, so this costs battery during the workday and
  /// nothing overnight.
  static const int heartbeatSeconds = 900; // 15 min

  /// How far from the shop the plugin keeps the geofence actively monitored.
  /// The old value of 400 m was the single biggest cause of missed clock-outs:
  /// it left only a few hundred metres of travel in which to detect the
  /// crossing, which a moving vehicle covers faster than Android delivers a
  /// geofence event.
  static const double geofenceProximityRadiusM = 2000;

  static const String geofenceIdIn  = 'ppc-shop-in';
  static const String geofenceIdOut = 'ppc-shop-out';

  /// Identifier used by builds 1-7. Removed at startup so an upgraded phone
  /// doesn't keep firing the old single geofence alongside the new pair.
  static const String legacyGeofenceId = 'ppc-shop';
}
