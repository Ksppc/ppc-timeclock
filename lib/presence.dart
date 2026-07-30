import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'identity.dart';

/// Presence reporting — the safety net under the geofence.
///
/// A geofence EXIT on Android is best-effort: the OS batches it, Doze throttles
/// it, OEM battery managers kill the service, and a phone with no fresh fix at
/// the moment of crossing produces no event at all. Any design that trusts that
/// event will eventually lose a whole day's hours with no way to recover it.
///
/// So while a phone is clocked in it also reports WHERE IT IS on a heartbeat.
/// The server reconciles that stream into a clock-out (see
/// backend/presence-reconciliation.sql). A missed geofence event then costs one
/// heartbeat of precision instead of the entire shift.
///
/// Pings are cheap and stop completely when off the clock.
class Presence {
  static const _key = 'pending_pings';

  /// Queue a position report and try to send it. Offline-safe: the recorded
  /// time is always the real observation time, never the upload time.
  static Future<void> ping({
    required bool insideGeofence,
    bool? insideWifi,
    double? lat,
    double? lon,
    double? accuracy,
    DateTime? at,
    String reason = 'heartbeat',
    String? appState,
  }) async {
    final row = {
      'employee_id': await Identity.effectiveId(),
      'ping_time': (at ?? DateTime.now()).toUtc().toIso8601String(),
      'latitude': lat,
      'longitude': lon,
      'gps_accuracy_m': accuracy,
      'inside_geofence': insideGeofence,
      'inside_wifi': insideWifi,
      'reason': reason,
      // What the tracking engine itself was doing at this moment. Without it,
      // a silent phone is indistinguishable from a phone that is simply at
      // home — and we spent an evening guessing between those two.
      'app_state': appState,
      'device_id': 'android',
    };
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    list.add(jsonEncode(row));
    // Never let the queue grow without bound if the phone is offline for days.
    if (list.length > 500) list.removeRange(0, list.length - 500);
    await prefs.setStringList(_key, list);
    await flush();
  }

  /// Push everything queued; keep whatever fails for the next attempt.
  ///
  /// Claim-then-send, for the same reason as PunchQueue.flush(): the old
  /// read-send-then-write order let two overlapping flushes send the same row
  /// twice, and on 29 July that duplicated a clock-in. Pings matter less than
  /// punches — they are evidence, not pay — but a doubled evidence trail is
  /// still a trail that lies about how often the phone reported in.
  static bool _flushing = false;

  static Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final claimed = prefs.getStringList(_key) ?? [];
      if (claimed.isEmpty) return;
      await prefs.setStringList(_key, const []);

      final failed = <String>[];
      for (final item in claimed) {
        try {
          await Supabase.instance.client
              .from('presence_pings')
              .insert(jsonDecode(item));
        } catch (_) {
          failed.add(item);
        }
      }
      if (failed.isNotEmpty) {
        final current = prefs.getStringList(_key) ?? [];
        var merged = [...failed, ...current];
        if (merged.length > 500) {
          merged = merged.sublist(merged.length - 500);
        }
        await prefs.setStringList(_key, merged);
      }
    } finally {
      _flushing = false;
    }
  }

  static Future<int> pendingCount() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? []).length;
  }

  // --- Wi-Fi presence ------------------------------------------------------
  // Second, independent signal. Inside a steel building GPS is unreliable and
  // can read as "outside the zone" while the person is standing in the shop.
  // Being joined to the shop's own network is near-proof of presence, costs
  // essentially no battery, and works where GPS does not.

  /// True  = joined to the shop network.
  /// False = joined to some other network, or no Wi-Fi.
  /// Null  = we could not tell (no permission, no SSID configured, error).
  ///         Null is important: the server treats it as "no opinion" rather
  ///         than as evidence of absence.
  static Future<bool?> onShopWifi(String? shopSsid) async {
    if (shopSsid == null || shopSsid.trim().isEmpty) return null;
    try {
      final raw = await NetworkInfo().getWifiName();
      if (raw == null) return false; // Wi-Fi off or not connected
      final ssid = _clean(raw);
      if (ssid.isEmpty || ssid == 'unknown ssid') return null;
      return ssid.toLowerCase() == _clean(shopSsid).toLowerCase();
    } catch (_) {
      return null; // no permission / platform refused — say nothing
    }
  }

  /// The network this phone is joined to right now, or null if we cannot tell.
  ///
  /// Display only. The app deliberately cannot WRITE the shop network: it runs
  /// on the public anon key, so the database has no way to tell one crew member
  /// from another. If any phone could set the shop SSID, anyone could point it
  /// at their own home network and be counted on site from their couch — and
  /// the reconciler would faithfully back that up. Setting the shop network is
  /// an admin action, done from the dashboard behind a real login.
  static Future<String?> currentSsid() async {
    try {
      final raw = await NetworkInfo().getWifiName();
      if (raw == null) return null;
      final ssid = _clean(raw);
      if (ssid.isEmpty || ssid.toLowerCase() == 'unknown ssid') return null;
      return ssid;
    } catch (_) {
      return null;
    }
  }

  /// Android returns the SSID wrapped in quotes, sometimes with whitespace.
  static String _clean(String s) {
    var v = s.trim();
    if (v.startsWith('"') && v.endsWith('"') && v.length >= 2) {
      v = v.substring(1, v.length - 1);
    }
    return v.trim();
  }
}
