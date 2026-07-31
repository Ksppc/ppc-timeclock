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
    // Which layer caught this crossing — 'fence-enter', 'fetch-departure',
    // 'app-opened-arrival'. Rides along in device_id so the dashboard can show
    // it without a schema change. If fences quietly stop working on one
    // handset, this is what makes it visible before payroll does.
    String mechanism = 'unknown',
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
      'device_id': 'android:$mechanism',
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

  /// Make the phone's idea of "on the clock" agree with the database.
  ///
  /// WHY THIS EXISTS
  /// ---------------
  /// 30 July 2026. The server-side reconciler closed a shift at 12:49 after a
  /// lunch trip and wrote the clock-out straight into punch_events. It never
  /// told the phone. The phone only clears this flag when the PHONE writes a
  /// clock-out, so it spent the whole afternoon believing a shift was still
  /// open — and recordArrival() begins with "if already clocked in, do
  /// nothing". Every fifteen minutes the app woke, correctly saw itself at the
  /// shop, correctly decided a clock-in was needed, and declined.
  ///
  /// The phone was right about the world and wrong about itself.
  ///
  /// So: the database is the source of truth and this flag is a cache of it.
  /// Anything that can change the truth — the reconciler, an admin editing a
  /// day, a punch from another install — now heals itself within one check
  /// instead of silently wedging the app.
  ///
  /// Two things it deliberately will NOT do:
  ///   - It does not run while punches are still queued locally. Those have not
  ///     reached the server yet, so the server's answer is out of date and
  ///     trusting it would erase them.
  ///   - It does not touch the flag if the query fails. Offline is not
  ///     evidence of anything.
  static Future<void> syncClockedInFromServer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if ((prefs.getStringList(_key) ?? []).isNotEmpty) return; // unsent work

      final rows = await Supabase.instance.client
          .from('punch_events')
          .select('direction')
          .eq('employee_id', await Identity.effectiveId())
          .order('event_time', ascending: false)
          .limit(1);

      // AN EMPTY RESULT IS NOT EVIDENCE. LEAVE THE FLAG ALONE.
      //
      // This line used to read "no punches at all means never clocked in —
      // that is a real answer", and set the flag to false. On 31 July that
      // clocked Kent in THIRTY-THREE times in one day.
      //
      // The read comes back empty for several reasons that have nothing to do
      // with the person's actual state: a permissions rule on punch_events, a
      // query error, or — exactly what happened — a wiped database and a fresh
      // employee ID after a clean start. Each time the read returned nothing,
      // the app concluded "not clocked in", the periodic check saw the shop
      // 15 m away, and it clocked in again. Every quarter of an hour.
      //
      // "I could not see any punches" is not "there are no punches". That
      // distinction is the entire point of this project and I wrote a comment
      // asserting the opposite without ever testing the empty case.
      //
      // So: only ever CORRECT the flag from a punch we actually read. Never
      // clear it from silence.
      if (rows.isEmpty) return;
      await setClockedIn((rows.first as Map)['direction'] == 'in');
    } catch (_) {
      // Could not ask. Leave the flag alone.
    }
  }

  // --- Runaway guard ---------------------------------------------------------
  //
  // A hard cap on how often the same direction can be written, whatever the
  // cause. The sync bug above is fixed, but 33 identical punches got written
  // before anyone noticed, and the only reason it was not worse is that a
  // unique index happened to be in the way.
  //
  // Any single fault should cost one wrong punch, not a day of them. This
  // stops the bleeding regardless of which mistake causes it next time.
  static const _lastKey = 'last_punch_';
  static const Duration _minGap = Duration(minutes: 10);

  /// True if we already wrote this direction within the last few minutes.
  static Future<bool> tooSoonFor(String direction) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final ms = prefs.getInt('$_lastKey$direction');
    if (ms == null) return false;
    final since =
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    return since < _minGap && !since.isNegative;
  }

  static Future<void> markPunched(String direction) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        '$_lastKey$direction', DateTime.now().millisecondsSinceEpoch);
  }
}
