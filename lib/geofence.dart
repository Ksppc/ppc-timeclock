import 'dart:math';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'punch_queue.dart';

/// Background geofencing. Uses flutter_background_geolocation, which detects
/// enter/exit even when the app is killed (Android headless task), is battery
/// friendly, and persists across reboots.
class Geofence {
  // The active shop zone. Defaults to the compiled-in values, then gets
  // refreshed from the database at startup so the admin can move the geofence
  // from the dashboard WITHOUT rebuilding the APK.
  static double _lat = Config.zoneLat;
  static double _lon = Config.zoneLon;
  static double _radius = Config.clockInRadiusM;

  /// Headless handler — runs when the app process is NOT alive.
  @pragma('vm:entry-point')
  static Future<void> headlessTask(bg.HeadlessEvent event) async {
    if (event.name == bg.Event.GEOFENCE) {
      final bg.GeofenceEvent ev = event.event;
      await _record(ev);
    }
  }

  static Future<void> init() async {
    // Pull the live shop zone from the dashboard-editable table (falls back to
    // the compiled-in values if offline / not reachable).
    await _loadZone();

    // Fire the same handler when the app IS alive.
    bg.BackgroundGeolocation.onGeofence(_record);

    await bg.BackgroundGeolocation.ready(bg.Config(
      desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
      distanceFilter: 20,
      stopOnTerminate: false, // keep running after the app is closed
      startOnBoot: true, // resume after a reboot
      enableHeadless: true,
      // Debounce edge flicker: require the phone to actually loiter in/out.
      geofenceProximityRadius: 400,
      logLevel: bg.Config.LOG_LEVEL_OFF,
    ));

    // Re-register the shop zone with the latest coordinates (remove any stale
    // one first so a moved geofence takes effect).
    try {
      await bg.BackgroundGeolocation.removeGeofence(Config.geofenceId);
    } catch (_) {}
    await bg.BackgroundGeolocation.addGeofence(bg.Geofence(
      identifier: Config.geofenceId,
      radius: _radius,
      latitude: _lat,
      longitude: _lon,
      notifyOnEntry: true,
      notifyOnExit: true,
      loiteringDelay: 30000, // 30 s dwell before the crossing counts
    ));

    await bg.BackgroundGeolocation.start();

    // Handle "already at the shop when the app starts."
    await _syncInitialPresence();
  }

  /// Fetch the active shop zone from Supabase. Anon-readable via the
  /// zone-settings-policies.sql grant. Silent fallback to Config on any error.
  static Future<void> _loadZone() async {
    try {
      final rows = await Supabase.instance.client
          .from('zone_config')
          .select('center_lat, center_lon, clock_in_radius_m')
          .eq('active', true)
          .limit(1);
      if (rows is List && rows.isNotEmpty) {
        final z = rows.first as Map;
        _lat = (z['center_lat'] as num).toDouble();
        _lon = (z['center_lon'] as num).toDouble();
        _radius = (z['clock_in_radius_m'] as num).toDouble();
      }
    } catch (_) {
      // Keep the compiled-in fallback values.
    }
  }

  static Future<void> _record(bg.GeofenceEvent ev) async {
    if (ev.identifier != Config.geofenceId) return;
    final entering = ev.action == 'ENTER';
    final alreadyOnSite = await PunchQueue.isClockedIn();
    // Ignore duplicate same-direction crossings: GPS drift at the boundary can
    // re-fire an ENTER without you ever leaving (or an EXIT when already gone).
    if (entering && alreadyOnSite) return;
    if (!entering && !alreadyOnSite) return;
    await PunchQueue.setClockedIn(entering); // track on/off-site state
    final loc = ev.location;
    await PunchQueue.add(
      direction: entering ? 'in' : 'out',
      lat: loc.coords.latitude,
      lon: loc.coords.longitude,
      accuracy: loc.coords.accuracy,
      crossedAt: DateTime.parse(loc.timestamp),
      insideGeofence: entering,
    );
  }

  /// Geofences only fire on a boundary CROSSING. If the phone is already inside
  /// the shop zone when tracking starts (the normal "in office first" case),
  /// no ENTER event fires — so we check our current position here and record
  /// the clock-in ourselves. A stored on-site flag prevents double punches on
  /// later app restarts while still inside.
  static Future<void> _syncInitialPresence() async {
    try {
      final bg.Location loc = await bg.BackgroundGeolocation.getCurrentPosition(
        samples: 1,
        timeout: 30,
        maximumAge: 10000,
        desiredAccuracy: 40,
        persist: false,
      );
      final metres = _distanceM(
          loc.coords.latitude, loc.coords.longitude, _lat, _lon);
      final inside = metres <= _radius;
      final alreadyOnSite = await PunchQueue.isClockedIn();

      if (inside && !alreadyOnSite) {
        // At the shop, but no clock-in on record — punch in now.
        await PunchQueue.setClockedIn(true);
        await PunchQueue.add(
          direction: 'in',
          lat: loc.coords.latitude,
          lon: loc.coords.longitude,
          accuracy: loc.coords.accuracy,
          crossedAt: DateTime.now(),
          insideGeofence: true,
        );
      } else if (!inside && alreadyOnSite) {
        // Marked on-site but now outside — an exit was missed while the app was
        // dead. Reset the flag so the next real entry counts. (That day will be
        // flagged for review, since it has an in with no out.)
        await PunchQueue.setClockedIn(false);
      }
    } catch (_) {
      // No location fix available right now; a real crossing is still caught.
    }
  }

  /// Great-circle distance in metres (haversine).
  static double _distanceM(double lat1, double lon1, double lat2, double lon2) {
    const earthR = 6371000.0;
    const rad = pi / 180.0;
    final dLat = (lat2 - lat1) * rad;
    final dLon = (lon2 - lon1) * rad;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * rad) * cos(lat2 * rad) * sin(dLon / 2) * sin(dLon / 2);
    return earthR * 2 * atan2(sqrt(a), sqrt(1 - a));
  }
}
