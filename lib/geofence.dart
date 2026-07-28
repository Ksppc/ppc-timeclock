import 'dart:math';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:background_fetch/background_fetch.dart' as bf;
import 'package:shared_preferences/shared_preferences.dart';
// supabase_flutter re-exports a `Presence` class from realtime_client, which
// collides with our own Presence reporter. We never use the realtime one.
import 'package:supabase_flutter/supabase_flutter.dart' hide Presence;
import 'config.dart';
import 'punch_queue.dart';
import 'presence.dart';

/// Background presence detection.
///
/// TWO layers, on purpose:
///
///  1. GEOFENCE events give an instant, accurate punch when they fire. This is
///     the happy path and it is what produces a clean record.
///
///  2. HEARTBEAT pings, sent only while clocked in, let the server reconstruct
///     a clock-out when the geofence event never arrives — which on Android it
///     regularly does not. See presence.dart and
///     backend/presence-reconciliation.sql.
///
/// Layer 1 alone was the original design. It lost a full shift the first time
/// an exit event went missing, and had no way to notice or recover.
class Geofence {
  // Active shop zone. Compiled-in defaults, refreshed from the database at
  // startup so the dashboard can move the zone without an APK rebuild.
  static double _lat = Config.zoneLat;
  static double _lon = Config.zoneLon;
  static double _radiusIn = Config.clockInRadiusM;
  static double _radiusOut = Config.clockOutRadiusM;
  static String? _wifiSsid = Config.shopWifiSsid;
  static int _heartbeatSeconds = Config.heartbeatSeconds;

  static const _lastPingKey = 'last_motion_ping_ms';

  // -------------------------------------------------------------------------
  //  Headless entry point — runs when the app process is NOT alive.
  //
  //  This isolate does not run main(), so nothing is initialised for us: the
  //  Supabase client and the zone both have to be set up here or every punch
  //  taken while the app is closed sits in the local queue until someone
  //  happens to open the app. Since nobody ever opens this app, that meant
  //  punches could lag for days.
  // -------------------------------------------------------------------------
  @pragma('vm:entry-point')
  static Future<void> headlessTask(bg.HeadlessEvent event) async {
    await _ensureSupabase();
    await _loadZone();

    switch (event.name) {
      case bg.Event.GEOFENCE:
        await _record(event.event as bg.GeofenceEvent);
        break;
      case bg.Event.HEARTBEAT:
        await _heartbeat();
        break;
      case bg.Event.TERMINATE:
      case bg.Event.BOOT:
        // Process restarting: say where we are so a crossing missed while dead
        // is still reconcilable server-side.
        await _reportPosition(reason: 'startup');
        break;
    }
  }

  // -------------------------------------------------------------------------
  //  THE GUARANTEED CLOCK.
  //
  //  `heartbeatInterval` does not fire on Android when the device is stationary
  //  — which is precisely when a phone is sitting in a shop all afternoon. On
  //  28 July 2026 it produced ZERO pings across a ten-hour shift, and a missed
  //  geofence exit had to be reconstructed from a single incidental motion ping.
  //
  //  `background_fetch` is Android's supported mechanism for work that must
  //  actually happen: it runs through Doze, through app termination, and after
  //  reboot. This is the floor under everything else.
  // -------------------------------------------------------------------------

  /// Headless entry point for the periodic task — runs with the app terminated.
  @pragma('vm:entry-point')
  static Future<void> fetchHeadlessTask(bf.HeadlessEvent event) async {
    if (event.timeout) {
      await bf.BackgroundFetch.finish(event.taskId);
      return;
    }
    try {
      await _ensureSupabase();
      await _loadZone();
      await _periodicCheck();
    } catch (_) {
    } finally {
      // Must always finish, or Android throttles us for overrunning.
      await bf.BackgroundFetch.finish(event.taskId);
    }
  }

  /// Register the periodic task. Call once from main().
  static Future<void> initPeriodic() async {
    try {
      await bf.BackgroundFetch.configure(
        bf.BackgroundFetchConfig(
          minimumFetchInterval: 15, // Android's floor; asking for less is ignored
          stopOnTerminate: false,
          startOnBoot: true,
          enableHeadless: true,
          requiresBatteryNotLow: false,
          requiresCharging: false,
          requiresStorageNotLow: false,
          requiresDeviceIdle: false,
          requiredNetworkType: bf.NetworkType.NONE,
          // JobScheduler throttles by battery and usage patterns. Payroll is not
          // a good place for "the OS decided to skip a few". AlarmManager costs
          // a little more battery and actually runs.
          forceAlarmManager: true,
        ),
        (String taskId) async {
          try {
            await _periodicCheck();
          } catch (_) {}
          await bf.BackgroundFetch.finish(taskId);
        },
        (String taskId) async {
          await bf.BackgroundFetch.finish(taskId);
        },
      );
      await bf.BackgroundFetch.start();
    } catch (_) {
      // Never let a scheduling failure take the app down — the geofence and
      // Wi-Fi layers still work without it.
    }
  }

  /// What the periodic task actually does: flush anything stuck, then — only if
  /// on the clock — report where this phone is.
  static Future<void> _periodicCheck() async {
    await PunchQueue.flush();
    await Presence.flush();
    if (!await PunchQueue.isClockedIn()) return; // off the clock: costs nothing
    await _reportPosition(reason: 'fetch');
  }

  /// Safe to call repeatedly and from any isolate.
  static Future<void> _ensureSupabase() async {
    try {
      Supabase.instance.client; // throws if not yet initialised
    } catch (_) {
      try {
        await Supabase.initialize(
            url: Config.supabaseUrl, anonKey: Config.supabaseAnon);
      } catch (_) {}
    }
  }

  static Future<void> init() async {
    await _loadZone();

    bg.BackgroundGeolocation.onGeofence(_record);
    bg.BackgroundGeolocation.onHeartbeat((_) => _heartbeat());

    // While moving, the plugin reports locations anyway — piggyback a ping so
    // the drive away from the shop is densely covered without extra GPS use.
    bg.BackgroundGeolocation.onLocation((bg.Location l) async {
      if (!await PunchQueue.isClockedIn()) return;
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_lastPingKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < 120000) return; // at most one motion ping every 2 min
      await prefs.setInt(_lastPingKey, now);
      await _pingFrom(l, reason: 'motion');
    });

    // Wi-Fi as a FIRST-CLASS signal, not an afterthought.
    //
    // For a fixed shop this is the best presence indicator there is: it changes
    // the instant you join or leave the network, it works inside a steel
    // building where GPS cannot, and it costs almost no battery. Joining or
    // dropping the shop network is a strong statement about where the phone is,
    // so record a ping the moment connectivity changes rather than waiting for
    // the next scheduled check.
    bg.BackgroundGeolocation.onConnectivityChange(
        (bg.ConnectivityChangeEvent e) async {
      if (!await PunchQueue.isClockedIn()) return;
      final wifi = await Presence.onShopWifi(_wifiSsid);
      if (wifi == null) return; // phone won't say — nothing to record
      await Presence.ping(
        insideGeofence: wifi,
        insideWifi: wifi,
        reason: wifi ? 'wifi-joined' : 'wifi-left',
      );
    });

    // If location services get switched off while someone is on the clock,
    // that is exactly the silent failure that loses a day. Record it.
    bg.BackgroundGeolocation.onProviderChange((bg.ProviderChangeEvent e) async {
      if (!e.enabled && await PunchQueue.isClockedIn()) {
        await Presence.ping(
          insideGeofence: true, // last known state; not evidence of leaving
          insideWifi: await Presence.onShopWifi(_wifiSsid),
          reason: 'location-off',
        );
      }
    });

    await bg.BackgroundGeolocation.ready(bg.Config(
      desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
      distanceFilter: 20,
      stopOnTerminate: false,
      startOnBoot: true,
      enableHeadless: true,
      // Keep the geofence actively monitored well beyond the zone. At the old
      // 400 m a vehicle left the monitored area faster than Android delivers a
      // geofence event, and the exit was simply never reported.
      geofenceProximityRadius: Config.geofenceProximityRadiusM.toInt(),
      geofenceModeHighAccuracy: true,
      // Heartbeat is what makes a missed exit recoverable.
      heartbeatInterval: _heartbeatSeconds,
      preventSuspend: true,
      // A foreground service is what stops the OEM battery managers from
      // quietly killing us mid-shift. The plugin supplies its own default
      // notification; customising the text is cosmetic and is deliberately
      // left alone here so this build has no unverified API surface in it.
      foregroundService: true,
      logLevel: bg.Config.LOG_LEVEL_OFF,
    ));

    await _registerZones();
    await bg.BackgroundGeolocation.start();
    await initPeriodic(); // the guaranteed 15-minute clock
    await _syncInitialPresence();
  }

  /// Register the entry and exit geofences as a PAIR.
  ///
  /// A single geofence cannot express "clock in at 100 m, clock out at 125 m" —
  /// it has one radius. That is why the 25 m anti-jitter buffer, which is in
  /// the spec and in the database schema and on the dashboard, did not
  /// previously exist in the app at all.
  static Future<void> _registerZones() async {
    for (final id in [
      Config.legacyGeofenceId,
      Config.geofenceIdIn,
      Config.geofenceIdOut
    ]) {
      try {
        await bg.BackgroundGeolocation.removeGeofence(id);
      } catch (_) {}
    }

    await bg.BackgroundGeolocation.addGeofence(bg.Geofence(
      identifier: Config.geofenceIdIn,
      radius: _radiusIn,
      latitude: _lat,
      longitude: _lon,
      notifyOnEntry: true,
      notifyOnExit: false,
    ));

    await bg.BackgroundGeolocation.addGeofence(bg.Geofence(
      identifier: Config.geofenceIdOut,
      radius: _radiusOut,
      latitude: _lat,
      longitude: _lon,
      notifyOnEntry: false,
      notifyOnExit: true,
    ));
  }

  /// Fetch the live shop zone. Silent fallback to Config on any error.
  static Future<void> _loadZone() async {
    try {
      final rows = await Supabase.instance.client
          .from('zone_config')
          .select(
              'center_lat, center_lon, clock_in_radius_m, clock_out_radius_m, wifi_ssid')
          .eq('active', true)
          .limit(1);
      if (rows is List && rows.isNotEmpty) {
        final z = rows.first as Map;
        _lat = (z['center_lat'] as num).toDouble();
        _lon = (z['center_lon'] as num).toDouble();
        _radiusIn = (z['clock_in_radius_m'] as num).toDouble();
        // Previously never read — the dashboard field was writing to a column
        // nothing consumed.
        final ro = z['clock_out_radius_m'];
        _radiusOut = ro == null
            ? _radiusIn + 25
            : (ro as num).toDouble();
        if (_radiusOut <= _radiusIn) _radiusOut = _radiusIn + 25;
        _wifiSsid = z['wifi_ssid'] as String?;
      }
    } catch (_) {
      // Keep the compiled-in fallbacks.
    }
  }

  // -------------------------------------------------------------------------
  //  Geofence crossings
  // -------------------------------------------------------------------------
  static Future<void> _record(bg.GeofenceEvent ev) async {
    final isEntry = ev.identifier == Config.geofenceIdIn && ev.action == 'ENTER';
    final isExit = ev.identifier == Config.geofenceIdOut && ev.action == 'EXIT';
    if (!isEntry && !isExit) return;

    final alreadyOnSite = await PunchQueue.isClockedIn();
    // Ignore duplicate same-direction crossings.
    if (isEntry && alreadyOnSite) return;
    if (isExit && !alreadyOnSite) return;

    // An exit while still joined to the shop Wi-Fi is GPS drift, not a
    // departure. Don't punch out someone standing inside the building.
    if (isExit) {
      final wifi = await Presence.onShopWifi(_wifiSsid);
      if (wifi == true) {
        await _pingFrom(ev.location, reason: 'exit-suppressed-wifi');
        return;
      }
    }

    await PunchQueue.setClockedIn(isEntry);
    final loc = ev.location;
    await PunchQueue.add(
      direction: isEntry ? 'in' : 'out',
      lat: loc.coords.latitude,
      lon: loc.coords.longitude,
      accuracy: loc.coords.accuracy,
      crossedAt: DateTime.parse(loc.timestamp),
      insideGeofence: isEntry,
    );
    await _pingFrom(loc, reason: isEntry ? 'clock-in' : 'clock-out');
  }

  // -------------------------------------------------------------------------
  //  Heartbeat — only while on the clock.
  // -------------------------------------------------------------------------
  static Future<void> _heartbeat() async {
    if (!await PunchQueue.isClockedIn()) return; // off the clock: cost nothing
    await PunchQueue.flush();
    await Presence.flush();
    await _reportPosition(reason: 'heartbeat');
  }

  /// Take a fresh fix and report it. The heartbeat event itself only carries a
  /// last-known location, which can be hours stale, so we ask for a real one.
  static Future<void> _reportPosition({required String reason}) async {
    final wifi = await Presence.onShopWifi(_wifiSsid);
    try {
      final loc = await bg.BackgroundGeolocation.getCurrentPosition(
        samples: 1,
        timeout: 30,
        maximumAge: 60000,
        desiredAccuracy: 40,
        persist: false,
      );
      await _pingFrom(loc, reason: reason, wifi: wifi);
    } catch (_) {
      // No fix available (indoors, GPS cold). Wi-Fi alone is still worth
      // reporting — it is often the only signal that works in the shop.
      if (wifi != null) {
        await Presence.ping(
          insideGeofence: wifi,
          insideWifi: wifi,
          reason: '$reason-nofix',
        );
      }
    }
  }

  static Future<void> _pingFrom(bg.Location loc,
      {required String reason, bool? wifi}) async {
    final metres = _distanceM(
        loc.coords.latitude, loc.coords.longitude, _lat, _lon);
    final w = wifi ?? await Presence.onShopWifi(_wifiSsid);
    await Presence.ping(
      insideGeofence: metres <= _radiusOut,
      insideWifi: w,
      lat: loc.coords.latitude,
      lon: loc.coords.longitude,
      accuracy: loc.coords.accuracy,
      reason: reason,
    );
  }

  // -------------------------------------------------------------------------
  //  Startup reconciliation
  // -------------------------------------------------------------------------
  /// Geofences only fire on a boundary CROSSING, so a phone that is already
  /// inside the zone when tracking starts produces no ENTER event.
  static Future<void> _syncInitialPresence() async {
    final wifi = await Presence.onShopWifi(_wifiSsid);
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
      final inside = metres <= _radiusIn || wifi == true;
      final alreadyOnSite = await PunchQueue.isClockedIn();

      await _pingFrom(loc, reason: 'startup', wifi: wifi);

      if (inside && !alreadyOnSite) {
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
        // An exit was missed while the app was dead.
        //
        // The previous build cleared the flag here and wrote NOTHING, so the
        // one mechanism meant to catch a missed exit was also the thing that
        // destroyed the evidence of it. The day stayed clocked-in forever.
        //
        // We do NOT write an out punch here either — we cannot know when they
        // left, and inventing a time is worse than not having one. Instead we
        // report the position and let the server place the clock-out at the
        // last moment it can actually prove the person was on site.
        await Presence.ping(
          insideGeofence: false,
          insideWifi: wifi,
          lat: loc.coords.latitude,
          lon: loc.coords.longitude,
          accuracy: loc.coords.accuracy,
          reason: 'recovery',
        );
        await PunchQueue.setClockedIn(false);
      }
    } catch (_) {
      // No fix right now. Still report Wi-Fi if it has an opinion.
      if (wifi != null) {
        await Presence.ping(
            insideGeofence: wifi, insideWifi: wifi, reason: 'startup-nofix');
      }
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

  // --- Exposed for the app's setup/health screen ---------------------------
  static double get zoneLat => _lat;
  static double get zoneLon => _lon;
  static double get radiusIn => _radiusIn;
  static double get radiusOut => _radiusOut;
  static String? get wifiSsid => _wifiSsid;
}
