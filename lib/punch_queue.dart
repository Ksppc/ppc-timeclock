import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';

/// Offline-first punch queue. A geofence crossing is written here immediately
/// with its TRUE crossing time, then pushed to Supabase. If the phone is
/// offline the punch waits in the queue and flushes on the next connection —
/// so the recorded time is always the real crossing time, never the upload time.
class PunchQueue {
  static const _key = 'pending_punches';

  /// Build a punch row matching the punch_events schema and try to send it.
  static Future<void> add({
    required String direction, // 'in' | 'out'
    required double lat,
    required double lon,
    required double accuracy,
    required DateTime crossedAt,
    bool insideGeofence = true,
  }) async {
    final row = {
      'employee_id': Config.employeeId,
      'event_time': crossedAt.toUtc().toIso8601String(),
      'direction': direction,
      'latitude': lat,
      'longitude': lon,
      'gps_accuracy_m': accuracy,
      'source': 'gps',
      'inside_geofence': insideGeofence,
      'device_id': 'android-beta',
    };
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    list.add(jsonEncode(row));
    await prefs.setStringList(_key, list);
    await flush(); // best-effort immediate send
  }

  /// Push everything queued; keep whatever fails for the next attempt.
  static Future<void> flush() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    if (list.isEmpty) return;
    final remaining = <String>[];
    for (final item in list) {
      try {
        await Supabase.instance.client
            .from('punch_events')
            .insert(jsonDecode(item));
      } catch (_) {
        remaining.add(item); // still offline / rejected — retry later
      }
    }
    await prefs.setStringList(_key, remaining);
  }

  static Future<int> pendingCount() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? []).length;
  }
}
