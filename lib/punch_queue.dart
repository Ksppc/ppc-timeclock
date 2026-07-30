import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'identity.dart';

/// Offline-first punch queue. A crossing is written here immediately with its
/// TRUE crossing time, then pushed to Supabase. If the phone is offline the
/// punch waits and flushes on the next connection — so the recorded time is
/// always the real crossing time, never the upload time.
class PunchQueue {
  static const _key = 'pending_punches';

  /// Guards against two flushes running at once *inside one isolate*.
  ///
  /// Deliberately not the whole answer: the geofence callback runs in a
  /// SEPARATE isolate from the UI, and a static field is not shared between
  /// isolates. See the comment on flush() for the rest of the defence.
  static bool _flushing = false;

  /// Build a punch row matching the punch_events schema and try to send it.
  ///
  /// `lat`/`lon`/`accuracy` are nullable on purpose. Android does not always
  /// hand us a position with a geofence event, and writing the shop's own
  /// coordinates in that case would be inventing evidence — a punch that looks
  /// like a precise GPS fix at the shop when nothing of the sort was measured.
  /// A blank position is honest and the reconciler reads presence_pings for
  /// location anyway.
  static Future<void> add({
    required String direction, // 'in' | 'out'
    double? lat,
    double? lon,
    double? accuracy,
    required DateTime crossedAt,
    bool insideGeofence = true,
  }) async {
    final row = {
      'employee_id': await Identity.effectiveId(),
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

  /// Push everything queued; keep whatever genuinely failed for a later attempt.
  ///
  /// WHY THIS IS WRITTEN THE AWKWARD WAY
  /// -----------------------------------
  /// On 29 July one clock-in was recorded TWICE — same employee, same
  /// direction, same timestamp to the millisecond, two rows. It was not two
  /// crossings. It was one queued punch sent twice, because the old flush read
  /// the pending list, sent it, and only then wrote back what was left. Two
  /// flushes overlapping in that window both see the same punch and both send
  /// it. The geofence callback triggers one flush and opening the app triggers
  /// another, so the overlap is not hypothetical.
  ///
  /// Duplicate clock-INs are survivable — the day's hours use first-in and
  /// last-out. A duplicate clock-OUT would not be. This is payroll.
  ///
  /// Three layers now, because the outer two cannot be made airtight across
  /// isolates:
  ///   1. _flushing — stops the overlap within one isolate.
  ///   2. Claim first, send second — the queue is emptied BEFORE anything is
  ///      sent, so a competing flush finds nothing to send. Failures go back.
  ///   3. A unique index in Postgres on (employee_id, event_time, direction).
  ///      This is the layer that actually guarantees it. The database refuses
  ///      the second copy no matter what this code does wrong.
  static Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final claimed = prefs.getStringList(_key) ?? [];
      if (claimed.isEmpty) return;

      // Take the batch before sending any of it.
      await prefs.setStringList(_key, const []);

      final failed = <String>[];
      for (final item in claimed) {
        try {
          await Supabase.instance.client
              .from('punch_events')
              .insert(jsonDecode(item));
        } on PostgrestException catch (e) {
          // 23505 = unique_violation. The database already holds this punch,
          // so it is DONE, not failed. Retrying forever would jam the queue
          // and block every punch behind it — which is how a safety net turns
          // into the outage.
          if (e.code != '23505') failed.add(item);
        } catch (_) {
          failed.add(item); // offline, or the server is unhappy — try later
        }
      }

      if (failed.isNotEmpty) {
        // Put failures back, in front of anything queued while we were busy.
        final current = prefs.getStringList(_key) ?? [];
        await prefs.setStringList(_key, [...failed, ...current]);
      }
    } finally {
      _flushing = false;
    }
  }

  static Future<int> pendingCount() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? []).length;
  }

  // --- Clock state -----------------------------------------------------------
  // Tracks whether this phone is currently counted as "at the shop", so a
  // startup presence-check doesn't double-punch on every app restart.
  static const _clockedKey = 'clocked_in';

  static Future<bool> isClockedIn() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // another isolate may have changed it
    return prefs.getBool(_clockedKey) ?? false;
  }

  static Future<void> setClockedIn(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_clockedKey, v);
  }
}
