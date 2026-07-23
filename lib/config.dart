/// Per-install configuration. In the beta each tester's APK is built (or
/// first-run configured) with their own employeeId. The zone matches the
/// locked build spec.
class Config {
  // --- Supabase (from your project's Settings > API) ---
  static const String supabaseUrl  = 'https://jidfnenvbtpzvtbruojg.supabase.co';
  static const String supabaseAnon = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImppZGZuZW52YnRwenZ0YnJ1b2pnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ3NTU5NTQsImV4cCI6MjEwMDMzMTk1NH0.R2SCsgiuFhsqi2DBUbB6vSjQxMQVLwIKUs_SRnQO5zg';   // anon (public) key

  // --- Fallback employee (employees.id UUID) ---
  // With the name picker, each phone chooses its person on first launch and
  // that choice is stored on the device. This value is only a fallback used
  // if somehow nothing was picked yet. One shared APK now serves everyone.
  static const String employeeId = 'b6623746-83a4-4ef8-97df-72ed1ec35c2c';

  // --- Shop geofence (locked spec) ---
  static const double zoneLat = 53.513522;
  static const double zoneLon = -113.357603;
  static const double clockInRadiusM = 100;   // enter -> clock in
  // clock-out uses the same geofence with a loitering exit; the 125 m buffer
  // is enforced by bg_geo's exit debounce + our server keeps the raw evidence.
  static const String geofenceId = 'ppc-shop';
}
