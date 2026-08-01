import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';

/// Who this phone belongs to. Chosen once on first launch via the name picker
/// and stored on the device, so a SINGLE shared APK serves the whole crew —
/// no per-person rebuild. The stored id is read even by the headless geofence
/// task (when the app process is dead), so punches are always attributed right.
class Identity {
  static const _idKey = 'employee_id';
  static const _nameKey = 'employee_name';

  /// The employee UUID this phone reports as. Falls back to the compiled-in
  /// Config.employeeId only if nothing has been picked yet.
  static Future<String> effectiveId() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_idKey);
    return (v == null || v.isEmpty) ? Config.employeeId : v;
  }

  static Future<bool> isChosen() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_idKey);
    return v != null && v.isNotEmpty;
  }

  static Future<String?> name() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_nameKey);
  }

  static Future<void> choose(String id, String name) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_idKey, id);
    await p.setString(_nameKey, name);
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_idKey);
    await p.remove(_nameKey);
    await p.remove(_tokenKey);
  }

  // --- Device token ----------------------------------------------------------
  //
  // Proves this handset is the one that belongs to the chosen crew member.
  //
  // WHY IT EXISTS
  // -------------
  // Every phone runs the same APK with the same public key, and the name picker
  // hands every phone every crew member's id. So an id proves nothing — it is a
  // username the whole crew shares a copy of. Reading hours needed something a
  // phone has and other phones do not.
  //
  // The server mints this the first time a phone asks for its hours, and hands
  // it back exactly once. It is a password for one endpoint, so it lives beside
  // the employee id and is wiped by clear() along with everything else.
  //
  // It guards READING hours and nothing else. It is deliberately not part of
  // punching: a punch that failed because a token went missing would be a lost
  // hour of somebody's pay, and no privacy gain is worth that trade.
  static const _tokenKey = 'device_token';

  static Future<String?> deviceToken() async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    return p.getString(_tokenKey);
  }

  static Future<void> setDeviceToken(String token) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_tokenKey, token);
  }

  /// Active crew (id + full_name only) from the read-only roster view.
  /// Requires the crew-roster-policy.sql grant to be applied in Supabase.
  static Future<List<CrewMember>> fetchCrew() async {
    final rows = await Supabase.instance.client
        .from('crew_roster')
        .select('id, full_name')
        .order('full_name');
    return (rows as List)
        .map((r) => CrewMember(
              id: r['id'] as String,
              name: (r['full_name'] ?? '') as String,
            ))
        .toList();
  }
}

class CrewMember {
  final String id;
  final String name;
  const CrewMember({required this.id, required this.name});
}
