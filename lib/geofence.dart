import 'dart:math';
import 'package:background_fetch/background_fetch.dart' as bf;
import 'package:geolocator/geolocator.dart' as geo;
// The native package also exports a class called `Geofence`, so it is always
// prefixed. Learned from the `Presence` collision that cost three builds.
import 'package:native_geofence/native_geofence.dart' as ng;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Presence;
import 'config.dart';
import 'notify.dart';
import 'punch_queue.dart';
import 'presence.dart';

// =============================================================================
//  THE CLOCK — rebuilt on the operating system's own geofencing.
//
//  WHAT CHANGED AND WHY
//  --------------------
//  The previous three versions ran a tracking engine INSIDE this app and needed
//  the app to stay alive to notice a boundary crossing. It didn't. On 29 July
//  the app reported enabled=true at 07:22, the process then died, and eleven
//  hours passed with no exit, no heartbeat and no periodic check. Every fix
//  attempted — a wider radius, heartbeatInterval, background_fetch, a foreground
//  service, battery exemptions — was an attempt to keep a process alive that
//  Android had already decided to kill.
//
//  Android's Geofencing API does not work that way. You hand the fence to the
//  OS, the OS watches it with its own machinery, and when it is crossed the OS
//  STARTS THIS APP to deliver the event. From Google's own documentation:
//
//    "The Geofencing API delivers the events to an IntentService in your app,
//     which removes the need to have a service running in the background for
//     geofencing purposes."
//
//  The app being dead is the expected state, not a failure. Same on iOS, where
//  CLLocationManager region monitoring relaunches a terminated app.
//
//  The tell was in our own config all along: `geofenceProximityRadius`. A fence
//  watched by the OS needs no proximity radius. That setting only existed
//  because the old library polled from inside this process. It was tuned from
//  400 to 2000 instead of being questioned.
// =============================================================================

/// Fence identifiers. Two fences, not one, so the clock-in radius can be tight
/// while the clock-out radius is generous — the band between them is what stops
/// GPS jitter at the boundary punching someone in and out all day.
const String kFenceIn = 'ppc-shop-in';
const String kFenceOut = 'ppc-shop-out';

// -----------------------------------------------------------------------------
//  THE CALLBACK
//
//  Top-level, not a static method, and annotated vm:entry-point — the OS looks
//  this up by handle and calls it in a fresh isolate where nothing is
//  initialised. Everything it needs must be set up here.
// -----------------------------------------------------------------------------
@pragma('vm:entry-point')
Future<void> shopFenceTriggered(ng.GeofenceCallbackParams params) async {
  // ---------------------------------------------------------------------------
  //  DO NOT PROMOTE TO A FOREGROUND SERVICE HERE.
  //
  //  This callback used to start with promoteToForeground(), on the package's
  //  suggestion that anything heavier than a notification should run as a
  //  foreground service. On 29 July that turned every single geofence crossing
  //  into "Paragon Time Clock keeps stopping". The fence was firing perfectly;
  //  the app died before it could write anything, which is why the trail looked
  //  like a fence that never triggered.
  //
  //  Modern Android does not allow an app woken by a broadcast to start a
  //  foreground service on a whim. Since Android 12 a background start throws
  //  ForegroundServiceStartNotAllowedException, and since Android 14 a service
  //  must declare a foregroundServiceType or the system refuses it outright.
  //  Either way the system kills the process.
  //
  //  Note the old code had this call wrapped in try/catch and it made no
  //  difference — the exception is raised by the system against the service's
  //  own lifecycle, not returned to the Dart caller. A Dart catch block cannot
  //  save you from the platform deciding to kill your process. That is a
  //  general lesson worth keeping: try/catch protects you from your code, not
  //  from the operating system.
  //
  //  It is not needed anyway. A broadcast receiver gets roughly ten seconds,
  //  and writing one punch is a single row into SharedPreferences followed by
  //  one HTTP POST. If the POST is cut short the punch is ALREADY saved locally
  //  and the queue flushes it later. That is what the offline queue is for.
  // ---------------------------------------------------------------------------
  try {
    await ShopFence.ensureSupabase();

    final ids = params.geofences.map((g) => g.id).toSet();
    // Dwell counts as arriving. It is the same news, delivered late by a fence
    // that was not confident enough at the moment of crossing.
    final entering = (params.event == ng.GeofenceEvent.enter ||
            params.event == ng.GeofenceEvent.dwell) &&
        ids.contains(kFenceIn);
    final leaving = params.event == ng.GeofenceEvent.exit &&
        ids.contains(kFenceOut);

    final lat = params.location?.latitude;
    final lon = params.location?.longitude;

    if (entering) {
      await ShopFence.recordArrival(lat: lat, lon: lon, why: 'fence-enter');
    } else if (leaving) {
      await ShopFence.recordDeparture(lat: lat, lon: lon, why: 'fence-exit');
    } else {
      // A trigger we don't act on — the wrong fence for this direction. Record
      // it anyway so the trail explains itself later.
      await Presence.ping(
        insideGeofence: params.event == ng.GeofenceEvent.enter,
        lat: lat,
        lon: lon,
        reason: 'fence-${params.event.name}-ignored',
        appState: 'ids=${ids.join(",")}',
      );
    }
  } catch (_) {
    // Never let the callback throw — the OS may not deliver again.
  }
}

/// Periodic backstop. Fires roughly every 15 minutes if Android permits, and
/// exists only to catch the case where a fence event was genuinely lost. The
/// fences are the primary mechanism now; this is belt to their braces.
@pragma('vm:entry-point')
Future<void> shopFetchHeadless(bf.HeadlessEvent event) async {
  if (event.timeout) {
    await bf.BackgroundFetch.finish(event.taskId);
    return;
  }
  try {
    await ShopFence.ensureSupabase();
    await ShopFence.loadZone();
    await ShopFence.recheck(reason: 'fetch');
  } catch (_) {
  } finally {
    await bf.BackgroundFetch.finish(event.taskId);
  }
}

class ShopFence {
  static double _lat = Config.zoneLat;
  static double _lon = Config.zoneLon;
  static double _radiusIn = Config.clockInRadiusM;
  static double _radiusOut = Config.clockOutRadiusM;
  static String? _wifiSsid = Config.shopWifiSsid;

  static String? get wifiSsid => _wifiSsid;
  static double get radiusIn => _radiusIn;
  static double get radiusOut => _radiusOut;

  /// Safe from any isolate; the callback runs where nothing is initialised.
  static Future<void> ensureSupabase() async {
    try {
      Supabase.instance.client;
    } catch (_) {
      try {
        await Supabase.initialize(
            url: Config.supabaseUrl, anonKey: Config.supabaseAnon);
      } catch (_) {}
    }
  }

  /// Live shop zone from the dashboard-editable table. Falls back to the
  /// compiled-in values, so a network failure never leaves us fenceless.
  static Future<void> loadZone() async {
    try {
      final rows = await Supabase.instance.client
          .from('zone_config')
          .select(
              'center_lat, center_lon, clock_in_radius_m, clock_out_radius_m, wifi_ssid')
          .eq('active', true)
          .limit(1);
      if (rows.isNotEmpty) {
        final z = rows.first as Map;
        _lat = (z['center_lat'] as num).toDouble();
        _lon = (z['center_lon'] as num).toDouble();
        _radiusIn = (z['clock_in_radius_m'] as num).toDouble();
        final ro = z['clock_out_radius_m'];
        _radiusOut = ro == null ? _radiusIn + 100 : (ro as num).toDouble();
        if (_radiusOut <= _radiusIn) _radiusOut = _radiusIn + 100;
        _wifiSsid = z['wifi_ssid'] as String?;
      }
    } catch (_) {
      // Keep the compiled-in fallbacks.
    }
  }

  // ---------------------------------------------------------------------------
  //  SETUP
  // ---------------------------------------------------------------------------
  static Future<void> init() async {
    await ensureSupabase();
    await loadZone();
    await ng.NativeGeofenceManager.instance.initialize();
    await registerFences();
    await _initPeriodic();
  }

  /// Hand both fences to the OS.
  ///
  /// `initialTriggers: {enter}` is the elegant part: if the phone is already
  /// inside the zone when the fence is registered, Android fires ENTER straight
  /// away. That removes the whole class of "already at the shop when the app
  /// started, so no crossing ever happened" bug we hit repeatedly.
  static Future<void> registerFences() async {
    // Clear stale fences first so a moved zone or changed radius takes effect,
    // including the identifiers used by earlier builds.
    for (final id in [kFenceIn, kFenceOut, 'ppc-shop']) {
      try {
        await ng.NativeGeofenceManager.instance.removeGeofenceById(id);
      } catch (_) {}
    }

    final loc = ng.Location(latitude: _lat, longitude: _lon);

    await ng.NativeGeofenceManager.instance.createGeofence(
      ng.Geofence(
        id: kFenceIn,
        location: loc,
        radiusMeters: _radiusIn,
        // DWELL as well as ENTER, on Google's own advice. Dwell fires once
        // someone has settled inside for the loitering delay rather than only
        // at the instant of crossing, which gives a second chance at an arrival
        // the enter transition fumbled — and arriving is the half that went
        // missing after lunch on 30 July.
        triggers: {ng.GeofenceEvent.enter, ng.GeofenceEvent.dwell},
        iosSettings: ng.IosGeofenceSettings(initialTrigger: true),
        androidSettings: ng.AndroidGeofenceSettings(
          initialTriggers: {ng.GeofenceEvent.enter},
          // Someone who is still here two minutes later is here.
          loiteringDelay: const Duration(minutes: 2),
          // Payroll wants promptness over battery. Note Google's caveat: a low
          // value is a request, not a promise. Their documented latency is 2-3
          // minutes typically and up to 6 if the phone has been sitting still —
          // which is exactly why the periodic check now backs this up.
          notificationResponsiveness: const Duration(minutes: 1),
        ),
      ),
      shopFenceTriggered,
    );

    await ng.NativeGeofenceManager.instance.createGeofence(
      ng.Geofence(
        id: kFenceOut,
        location: loc,
        radiusMeters: _radiusOut,
        triggers: {ng.GeofenceEvent.exit},
        iosSettings: ng.IosGeofenceSettings(initialTrigger: false),
        androidSettings: ng.AndroidGeofenceSettings(
          initialTriggers: const {},
          notificationResponsiveness: const Duration(minutes: 1),
        ),
      ),
      shopFenceTriggered,
    );
  }

  /// Which fences the OS says it is currently watching.
  ///
  /// This is the health question that actually matters now. "Is the app
  /// running?" is no longer meaningful — the app is *supposed* to be dead most
  /// of the time. What matters is whether the OS still holds our fences.
  ///
  /// Returns NULL when we could not ask — which is not the same as an empty
  /// list, and the difference matters. An empty list means Android told us it
  /// is watching nothing, and someone's hours are about to go missing. Null
  /// means the question failed, most likely because we are in a background
  /// isolate where the plugin was never initialised. Collapsing the two would
  /// make the app report a false alarm every time the periodic check ran.
  static Future<List<String>?> registeredFenceIds() async {
    try {
      return await ng.NativeGeofenceManager.instance.getRegisteredGeofenceIds();
    } catch (_) {
      return null;
    }
  }

  static Future<void> _initPeriodic() async {
    try {
      await bf.BackgroundFetch.configure(
        bf.BackgroundFetchConfig(
          minimumFetchInterval: 15,
          stopOnTerminate: false,
          startOnBoot: true,
          enableHeadless: true,
          requiresBatteryNotLow: false,
          requiresCharging: false,
          requiresStorageNotLow: false,
          requiresDeviceIdle: false,
          requiredNetworkType: bf.NetworkType.NONE,
          forceAlarmManager: true,
        ),
        (String taskId) async {
          try {
            await recheck(reason: 'fetch');
          } catch (_) {}
          await bf.BackgroundFetch.finish(taskId);
        },
        (String taskId) async => bf.BackgroundFetch.finish(taskId),
      );
      await bf.BackgroundFetch.start();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  //  A NOTE ON TRUSTING THE EVENT LOCATION, 29 July 2026
  //
  //  A test run produced two punches 96 seconds apart: ENTER at the shop, then
  //  EXIT carrying coordinates 11.5 km away at the person's house. The first
  //  reading of that here was "Android handed us a stale fix and ended a shift
  //  14 minutes early", and a whole verify-with-a-fresh-fix layer was written
  //  to defend against it.
  //
  //  It was wrong. The test used a mock-location app; when its route finished
  //  the mock switched off and the phone snapped back to its real position.
  //  Android was correct on both events. There was no bug.
  //
  //  The defensive layer was then deleted rather than shipped, because it
  //  spent five to eight seconds of a ten-second callback budget on a GPS read
  //  in order to guard against something that had not been shown to happen —
  //  trading a real risk (callback killed, punch never written) for an
  //  imaginary one. If a genuine stale-location case ever turns up in the
  //  trail, it is in the git history and can come back with evidence behind it.
  //
  //  Recorded because the wrong conclusion was reached first, from coordinates
  //  alone, without knowing how the test had been run. Data does not interpret
  //  itself.
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  //  PUNCHES
  // ---------------------------------------------------------------------------
  static Future<void> recordArrival(
      {double? lat, double? lon, double? accuracy, required String why}) async {
    if (await PunchQueue.isClockedIn()) return; // already on the clock
    final at = DateTime.now();
    // Flip the state BEFORE writing, so a second callback arriving a
    // millisecond later sees "already clocked in" and stops.
    await PunchQueue.setClockedIn(true);
    await PunchQueue.add(
      direction: 'in',
      // Pass the position through exactly as given. If Android delivered the
      // geofence event without one, these stay null — previously they fell
      // back to the shop's own coordinates, which fabricates a precise fix at
      // the shop that nothing ever measured.
      lat: lat,
      lon: lon,
      accuracy: accuracy,
      crossedAt: at,
      insideGeofence: true,
      mechanism: why,
    );
    // AFTER the punch is safely queued, never before.
    await Notify.punch(direction: 'in', at: at, mechanism: why);
    await Presence.ping(
      insideGeofence: true,
      insideWifi: await Presence.onShopWifi(_wifiSsid),
      lat: lat,
      lon: lon,
      reason: why,
      appState: await describeState(),
    );
  }

  static Future<void> recordDeparture(
      {double? lat, double? lon, double? accuracy, required String why}) async {
    if (!await PunchQueue.isClockedIn()) return; // already off the clock

    // A departure while still on the shop network is GPS drift, not someone
    // going home. Don't end a shift over it.
    final wifi = await Presence.onShopWifi(_wifiSsid);
    if (wifi == true) {
      await Presence.ping(
        insideGeofence: true,
        insideWifi: true,
        lat: lat,
        lon: lon,
        reason: '$why-suppressed-wifi',
        appState: await describeState(),
      );
      return;
    }

    final at = DateTime.now();
    await PunchQueue.setClockedIn(false);
    await PunchQueue.add(
      direction: 'out',
      lat: lat,
      lon: lon,
      accuracy: accuracy,
      crossedAt: at,
      insideGeofence: false,
      mechanism: why,
    );
    // AFTER the punch is safely queued, never before.
    await Notify.punch(direction: 'out', at: at, mechanism: why);
    await Presence.ping(
      insideGeofence: false,
      insideWifi: wifi,
      lat: lat,
      lon: lon,
      reason: why,
      appState: await describeState(),
    );
  }

  // ---------------------------------------------------------------------------
  //  BACKSTOP
  // ---------------------------------------------------------------------------
  /// How many consecutive checks have seen the person CLEARLY off site.
  /// Persisted, because each periodic run is a fresh isolate with no memory.
  static const _awayKey = 'consecutive_away_checks';

  /// A fix worse than this tells us nothing useful about which side of a
  /// 150/250 m boundary someone is standing on.
  static const double _usableAccuracyM = 100;

  /// Two agreeing checks, roughly fifteen minutes apart, before a shift ends.
  static const int _awayChecksNeeded = 2;

  /// Read the current position and make the clock agree with reality.
  ///
  /// Runs whether or not we think we are on the clock: arriving unnoticed costs
  /// someone their morning, leaving unnoticed costs them their afternoon.
  ///
  /// PROMOTED 30 July 2026 — this may now end a shift, not just start one.
  ///
  /// It used to clock people IN but never OUT, on the reasoning that a single
  /// stray fix must not cost someone their afternoon. That reasoning was right;
  /// the conclusion was too strong. Google's own geofencing guidance says an
  /// alert can take up to six minutes when a device has been sitting still, and
  /// that the service leans on network location rather than GPS. A lunch run is
  /// shorter than that window, so on 30 July both the leaving and the returning
  /// went unseen by the fence. Making the fence the only thing allowed to end a
  /// shift means short trips are simply lost.
  ///
  /// So this can end one — but it has to earn it three times over:
  ///
  ///   1. The fix must be usable at all. Worse than 100 m and we say nothing.
  ///   2. The distance must clear the exit ring BY MORE THAN THE ACCURACY, so
  ///      the person is outside even in the fix's own worst case. "Outside if
  ///      this reading happens to be perfect" is not evidence.
  ///   3. Two consecutive checks must agree, about fifteen minutes apart. One
  ///      bad reading proves nothing; two, half an hour apart, both clearly off
  ///      site, is a departure.
  ///
  /// A reading that puts them back on site resets the count immediately. An
  /// ambiguous reading — poor accuracy, or in the band between the rings —
  /// leaves the count alone, because no evidence is not counter-evidence.
  ///
  /// The cost when the fence DID work is nothing: the fence gets there first.
  /// The cost when it didn't is up to fifteen minutes of imprecision, against a
  /// whole afternoon under the old behaviour.
  static Future<void> recheck({required String reason}) async {
    await PunchQueue.flush();
    await Presence.flush();

    // The database is the truth; this flag is a cache of it. Do this before
    // deciding anything, or we repeat 30 July — an app that can see the shop
    // in front of it and still refuses to clock in.
    await PunchQueue.syncClockedInFromServer();

    final wifi = await Presence.onShopWifi(_wifiSsid);
    final clockedIn = await PunchQueue.isClockedIn();
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    var away = prefs.getInt(_awayKey) ?? 0;

    try {
      final pos = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          // Always high now. This reading may end someone's shift, so it is
          // worth the battery — and it runs four times an hour, not always.
          accuracy: geo.LocationAccuracy.high,
          timeLimit: Duration(seconds: 30),
        ),
      );
      final metres = distanceM(pos.latitude, pos.longitude, _lat, _lon);
      final acc = pos.accuracy;
      final usable = acc > 0 && acc <= _usableAccuracyM;

      // Arrivals need a usable fix too.
      //
      // This gate was missing until 30 July, and its absence was a real hole:
      // departures were carefully guarded — a fix has to clear the ring by more
      // than its own error before it can end a shift — while arrivals accepted
      // any reading at all. A fix carrying 500 m of error that happens to
      // compute as 140 m from the shop is not evidence that anyone is at the
      // shop, and it would have started a shift.
      //
      // Connecteam discards anything worse than 300 m in both directions for
      // the same reason. Guarding only the frightening direction is not
      // caution, it is an oversight wearing caution's clothes.
      //
      // Wi-Fi still overrides: being joined to the shop network is its own
      // evidence and does not depend on GPS at all.
      final inside = (usable && metres <= _radiusIn) || wifi == true;
      // Outside even if this fix is as wrong as it admits it might be.
      final clearlyOutside =
          usable && wifi != true && (metres - acc) > _radiusOut;

      if (inside) {
        away = 0;
      } else if (clearlyOutside) {
        away += 1;
      }
      await prefs.setInt(_awayKey, away);

      await Presence.ping(
        insideGeofence: metres <= _radiusOut,
        insideWifi: wifi,
        lat: pos.latitude,
        lon: pos.longitude,
        accuracy: pos.accuracy,
        reason: reason,
        appState: '${await describeState()} '
            'd=${metres.round()} acc=${acc.round()} away=$away',
      );

      if (inside && !clockedIn) {
        await recordArrival(
            lat: pos.latitude,
            lon: pos.longitude,
            accuracy: pos.accuracy,
            why: '$reason-arrival');
      } else if (clockedIn && away >= _awayChecksNeeded) {
        // Two agreeing checks. End the shift, and reset so a later return
        // starts the count fresh.
        await prefs.setInt(_awayKey, 0);
        await recordDeparture(
            lat: pos.latitude,
            lon: pos.longitude,
            accuracy: pos.accuracy,
            why: '$reason-departure');
      }
    } catch (_) {
      if (wifi != null) {
        await Presence.ping(
          insideGeofence: wifi,
          insideWifi: wifi,
          reason: '$reason-nofix',
          appState: await describeState(),
        );
      }
    }
  }

  /// A one-line snapshot for the ping trail.
  ///
  /// The important field is now `fences` — whether the OS still holds our
  /// geofences. That, not "is the app running", is the health question under
  /// this architecture.
  static Future<String> describeState() async {
    final bits = <String>[];
    final ids = await registeredFenceIds();
    bits.add('fences=${ids == null ? "?" : (ids.isEmpty ? "NONE" : ids.join("/"))}');
    try {
      bits.add('locPerm=${await geo.Geolocator.checkPermission()}');
      bits.add('locOn=${await geo.Geolocator.isLocationServiceEnabled()}');
    } catch (_) {}
    bits.add('rIn=${_radiusIn.toStringAsFixed(0)}');
    bits.add('rOut=${_radiusOut.toStringAsFixed(0)}');
    return bits.join(' ');
  }

  /// Great-circle distance in metres (haversine).
  static double distanceM(
      double lat1, double lon1, double lat2, double lon2) {
    const earthR = 6371000.0;
    const rad = pi / 180.0;
    final dLat = (lat2 - lat1) * rad;
    final dLon = (lon2 - lon1) * rad;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * rad) * cos(lat2 * rad) * sin(dLon / 2) * sin(dLon / 2);
    return earthR * 2 * atan2(sqrt(a), sqrt(1 - a));
  }
}
