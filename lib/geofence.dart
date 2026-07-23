import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'config.dart';
import 'punch_queue.dart';

/// Background geofencing. Uses flutter_background_geolocation, which detects
/// enter/exit even when the app is killed (Android headless task), is battery
/// friendly, and persists across reboots.
class Geofence {
  /// Headless handler — runs when the app process is NOT alive.
  @pragma('vm:entry-point')
  static Future<void> headlessTask(bg.HeadlessEvent event) async {
    if (event.name == bg.Event.GEOFENCE) {
      final bg.GeofenceEvent ev = event.event;
      await _record(ev);
    }
  }

  static Future<void> init() async {
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

    // Register the shop zone (enter -> in, exit -> out).
    await bg.BackgroundGeolocation.addGeofence(bg.Geofence(
      identifier: Config.geofenceId,
      radius: Config.clockInRadiusM,
      latitude: Config.zoneLat,
      longitude: Config.zoneLon,
      notifyOnEntry: true,
      notifyOnExit: true,
      loiteringDelay: 30000, // 30 s dwell before the crossing counts
    ));

    await bg.BackgroundGeolocation.start();
  }

  static Future<void> _record(bg.GeofenceEvent ev) async {
    if (ev.identifier != Config.geofenceId) return;
    final direction = ev.action == 'ENTER' ? 'in' : 'out';
    final loc = ev.location;
    await PunchQueue.add(
      direction: direction,
      lat: loc.coords.latitude,
      lon: loc.coords.longitude,
      accuracy: loc.coords.accuracy,
      crossedAt: DateTime.parse(loc.timestamp),
      insideGeofence: direction == 'in',
    );
  }
}
