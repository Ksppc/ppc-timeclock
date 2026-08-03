import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// Wi-Fi scanning — the one phone setting that quietly decides whether the
/// shop fence works.
///
/// WHY THIS FILE EXISTS
/// --------------------
/// Android's geofencing does not use GPS. From Google's own troubleshooting
/// guide: "On most devices, the geofence service uses only network location for
/// geofence triggering", and "if Wi-Fi is turned off, your application might
/// never get geofence alerts."
///
/// But "Wi-Fi turned off" is NOT the setting that matters, and the app used to
/// say it was. The phone locates itself by SCANNING — listening for the names
/// of nearby access points and matching that pattern against Google's database.
/// It never joins any of them. It does not need a password and does not care
/// whose networks they are. A phone with Wi-Fi switched off but scanning left
/// on positions itself exactly as well as one that is connected.
///
/// So the old row asked crew to do a thing that was not the thing. This is the
/// thing: Settings > Location > Wi-Fi scanning.
///
/// WHAT ANDROID GIVES US, AND WHAT IT TOOK AWAY
/// -------------------------------------------
/// Two APIs, and only one of them is still supported — which shapes everything
/// below:
///
///   ACTION_REQUEST_SCAN_ALWAYS_AVAILABLE  (API 18, NOT deprecated)
///       Shows Android's own dialog: "allow scanning even with Wi-Fi off?".
///       Returns RESULT_OK if it is now on. This is the one tap.
///
///   isScanAlwaysAvailable()               (API 18, DEPRECATED since API 29)
///       Reads the current state. Still present, but deprecated, so it may
///       return a stale or fixed value on some builds.
///
/// The consequence: we can reliably FIX it but not reliably READ it. So the
/// row never claims a red status it cannot stand behind. It reports what the
/// dialog told us the last time somebody tapped, and otherwise says "not
/// checked" — which is honest, and still gets the fix one tap away.
///
/// That distinction is the whole lesson of the 33-punch bug in miniature: a
/// value you could not actually read is not evidence, and treating it as
/// evidence is how a screen full of green ends up lying to somebody about
/// their pay.
///
/// SAFETY
/// ------
/// Nothing here runs on its own and nothing here is anywhere near the punch
/// path. Every method is called from a button on the setup screen and every
/// failure degrades to "open the settings page and tell them what to tap".
/// The worst case is a wasted tap, never a lost hour.
class WifiScanning {
  static const MethodChannel _ch =
      MethodChannel('ca.paragonprotectivecoatings/wifi_scanning');

  /// Only Android has a user-facing Wi-Fi scanning setting at all. iOS has no
  /// equivalent switch and no API, so the row is hidden there rather than
  /// showing a check nobody can act on.
  static bool get supported => Platform.isAndroid;

  /// Best-effort read of the current setting.
  ///
  /// true  = scanning is on
  /// false = scanning is off
  /// null  = we could not tell, and will not guess
  ///
  /// Null is the common answer on newer Android and is NOT a failure. See the
  /// deprecation note above.
  static Future<bool?> isOn() async {
    if (!supported) return null;
    try {
      return await _ch.invokeMethod<bool>('isScanningOn');
    } catch (_) {
      return null;
    }
  }

  /// Show Android's own scanning dialog. One tap, no settings maze.
  ///
  /// true  = they allowed it, scanning is now on
  /// false = they declined
  /// null  = this phone has no such dialog, so we opened Location settings
  ///         instead and the caller should say what to tap
  static Future<bool?> request() async {
    if (!supported) return null;
    try {
      final r = await _ch.invokeMethod<bool>('requestScanning');
      // A null from the native side means ActivityNotFoundException — some
      // manufacturers ship Android without that system activity. Fall back
      // rather than leaving a button that visibly does nothing.
      if (r == null) await openLocationSettings();
      return r;
    } catch (_) {
      // MissingPluginException lands here if the native half ever fails to
      // build in. Deliberately still useful: the person gets to the right
      // settings screen either way.
      await openLocationSettings();
      return null;
    }
  }

  /// The fallback destination: Android's Location settings, where Wi-Fi
  /// scanning lives under "Location services" on most builds.
  static Future<void> openLocationSettings() async {
    try {
      await _ch.invokeMethod('openLocationSettings');
    } catch (_) {
      // Last resort. Not the same screen, but it is a real screen and it is
      // one the permission_handler package is already proven to open.
      await ph.openAppSettings();
    }
  }
}
