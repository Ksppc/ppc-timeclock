/// Per-install configuration. In the beta each tester's APK is built (or
/// first-run configured) with their own employeeId. The zone matches the
/// locked build spec.
class Config {
  // --- Supabase (from your project's Settings > API) ---
  static const String supabaseUrl  = 'https://jidfnenvbtpzvtbruojg.supabase.co';
  static const String supabaseAnon = 'YOUR-ANON-KEY';   // paste before the real build

  // --- Who this phone belongs to (employees.id UUID) ---
  static const String employeeId = 'REPLACE-WITH-EMPLOYEE-UUID';

  // --- Shop geofence (locked spec) ---
  static const double zoneLat = 53.513522;
  static const double zoneLon = -113.357603;
  static const double clockInRadiusM = 100;   // enter -> clock in
  // clock-out uses the same geofence with a loitering exit; the 125 m buffer
  // is enforced by bg_geo's exit debounce + our server keeps the raw evidence.
  static const String geofenceId = 'ppc-shop';
}
