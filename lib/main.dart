import 'package:flutter/material.dart';
import 'package:background_fetch/background_fetch.dart' as bf;
import 'package:geolocator/geolocator.dart' as geo;
import 'package:permission_handler/permission_handler.dart' as ph;
// supabase_flutter re-exports a `Presence` class from realtime_client, which
// collides with our own Presence reporter. We never use the realtime one.
import 'package:supabase_flutter/supabase_flutter.dart' hide Presence;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'config.dart';
import 'crew_hours.dart';
import 'dispute.dart';
import 'geofence.dart';
import 'punch_queue.dart';
import 'presence.dart';
import 'identity.dart';
import 'wifi_scanning.dart';

const _pblue = Color(0xFF17457F);
const _pred = Color(0xFFC8202F);
const _pgreen = Color(0xFF1B7F3B);
const _pamber = Color(0xFFB57200);

void main() {
  runApp(const PpcApp());
  // The periodic backstop while the app is dead.
  //
  // Note what is NOT registered here any more: a headless task for geofence
  // crossings. Those no longer arrive through this app at all — Android
  // delivers them to a broadcast receiver declared in the manifest, which
  // starts the app and calls shopFenceTriggered. The callback is wired up when
  // the fence is created, not at launch.
  bf.BackgroundFetch.registerHeadlessTask(shopFetchHeadless);
}

class PpcApp extends StatelessWidget {
  const PpcApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Paragon Time Clock',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: _pblue),
        home: const HomeScreen(),
      );
}

enum _Phase { booting, picking, active }

/// One item in the setup checklist.
class _Check {
  final String title;
  final String detail;
  final bool ok;
  final bool warn;
  final String? fixLabel;
  final Future<void> Function()? fix;
  _Check(this.title, this.detail,
      {required this.ok, this.warn = false, this.fixLabel, this.fix});
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  _Phase _phase = _Phase.booting;
  String? _who;
  int _pendingPunches = 0;
  int _pendingPings = 0;
  bool _clockedIn = false;

  List<_Check> _checks = [];
  bool _checking = false;

  // What Android's Wi-Fi scanning dialog told us, the last time somebody
  // tapped the button on this screen.
  //
  // Held here rather than read fresh every time because the READ side of that
  // setting was deprecated in API 29 while the FIX side was not — see
  // wifi_scanning.dart. The dialog's own result is the most trustworthy answer
  // this app can get, so when we have one, we keep it.
  //
  // null = nobody has tapped yet and isScanAlwaysAvailable() had no opinion.
  bool? _scanningOn;

  List<CrewMember> _crew = [];
  bool _loadingCrew = false;
  String? _crewError;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await Supabase.initialize(
        url: Config.supabaseUrl, anonKey: Config.supabaseAnon);
    if (await Identity.isChosen()) {
      _who = await Identity.name();
      await _startTracking();
    } else {
      setState(() => _phase = _Phase.picking);
      await _loadCrew();
    }
  }

  Future<void> _loadCrew() async {
    setState(() {
      _loadingCrew = true;
      _crewError = null;
    });
    try {
      final crew = await Identity.fetchCrew();
      setState(() {
        _crew = crew;
        _loadingCrew = false;
      });
    } catch (e) {
      setState(() {
        _loadingCrew = false;
        _crewError =
            'Could not load the crew list. Check your connection and try again.';
      });
    }
  }

  Future<void> _pick(CrewMember m) async {
    await Identity.choose(m.id, m.name);
    _who = m.name;
    await _startTracking();
  }

  Future<void> _startTracking() async {
    setState(() => _phase = _Phase.active);

    // Permissions must be granted BEFORE the fences are handed to the OS —
    // registering without background location throws, and previously that threw
    // silently and left the phone with no fences at all.
    await _askPermissions();
    try {
      await ShopFence.init();
    } catch (_) {}

    Connectivity().onConnectivityChanged.listen((_) {
      PunchQueue.flush();
      Presence.flush();
    });
    await _runChecks();
  }

  /// Ask for everything, in the order Android requires.
  ///
  /// "While using the app" is requested first; Android will not even show the
  /// "Allow all the time" option until the basic permission is held. Asking for
  /// them the other way round silently fails, which is a fine way to ship a
  /// clock that never runs.
  Future<void> _askPermissions() async {
    try {
      if (!await ph.Permission.location.isGranted) {
        await ph.Permission.location.request();
      }
      if (!await ph.Permission.locationAlways.isGranted) {
        await ph.Permission.locationAlways.request();
      }
      // Android 13+ denies notifications by default, and the foreground service
      // that the geofence callback promotes to needs one to display.
      if (!await ph.Permission.notification.isGranted) {
        await ph.Permission.notification.request();
      }
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  //  Setup checklist. Everything the phone needs in order for this to work,
  //  each with a button that fixes it.
  // -------------------------------------------------------------------------
  Future<void> _runChecks() async {
    setState(() => _checking = true);

    // Opening the app, or pulling to refresh, also asks "where am I really?"
    // and corrects the clock if it disagrees.
    try {
      await ShopFence.recheck(reason: 'app-opened');
    } catch (_) {}

    final out = <_Check>[];

    // 1. Location permission — must be "Allow all the time".
    bool always = false;
    try {
      always = await ph.Permission.locationAlways.isGranted;
    } catch (_) {}
    out.add(_Check(
      'Location: allow all the time',
      always
          ? 'Granted.'
          : 'The clock cannot see the shop unless location is set to "Allow all '
              'the time". "While using the app" is not enough — the app is '
              'never open.',
      ok: always,
      fixLabel: always ? null : 'Grant',
      fix: always
          ? null
          : () async {
              await ph.Permission.location.request();
              final r = await ph.Permission.locationAlways.request();
              if (r.isPermanentlyDenied) await ph.openAppSettings();
              await ShopFence.registerFences();
            },
    ));

    // 2. Location services switched on at all.
    bool servicesOn = true;
    try {
      servicesOn = await geo.Geolocator.isLocationServiceEnabled();
    } catch (_) {}
    out.add(_Check(
      'Location services on',
      servicesOn ? 'On.' : 'Location is switched off on this phone.',
      ok: servicesOn,
      fixLabel: servicesOn ? null : 'Open settings',
      fix: servicesOn
          ? null
          : () async {
              await geo.Geolocator.openLocationSettings();
            },
    ));

    // 3. THE FENCES THEMSELVES.
    //
    //    This is the check that matters under the new design, and it replaces
    //    the old "Clock running" row. That row asked whether this app was
    //    running — which is now the wrong question, because the app is
    //    SUPPOSED to be closed almost all the time. The right question is
    //    whether Android is still holding our two fences on our behalf.
    //
    //    It is also the only row here that reads a fact back out of the
    //    operating system rather than reporting a setting we asked for.
    List<String>? fences;
    try {
      fences = await ShopFence.registeredFenceIds();
    } catch (_) {}
    final armed =
        fences != null && fences.contains(kFenceIn) && fences.contains(kFenceOut);
    out.add(_Check(
      'Shop fence armed',
      armed
          ? 'Android is watching the shop boundary for this phone. It will '
              'start the app and record your punch even if the app is closed '
              'or the phone has been restarted.'
          : fences == null
              ? 'Could not ask Android whether the shop boundary is being '
                  'watched. Tap Re-arm.'
              : fences.isEmpty
                  ? 'Android is not watching the shop boundary. Your hours '
                      'will not record. This almost always means the location '
                      'permission above needs fixing first.'
                  : 'Only part of the shop boundary is registered '
                      '(${fences.join(", ")}). Tap Re-arm.',
      ok: armed,
      fixLabel: armed ? null : 'Re-arm',
      fix: armed
          ? null
          : () async {
              await ShopFence.init();
            },
    ));

    // 4. Notifications.
    //
    //    Still needed: when a fence fires, the callback promotes itself to a
    //    foreground service to make the network call that writes the punch, and
    //    Android requires a foreground service to be able to show a
    //    notification. Less critical than it was — there is no longer a
    //    permanent service to keep alive — but a blocked notification can still
    //    cut the punch write short.
    bool notifOk = true;
    try {
      notifOk = await ph.Permission.notification.isGranted;
    } catch (_) {}
    out.add(_Check(
      'Allow notifications',
      notifOk
          ? 'Granted.'
          : 'Blocked. When you arrive or leave, the app wakes for a few seconds '
              'to record it, and Android needs this permission to let it '
              'finish. Without it a punch can be cut off part-way.',
      ok: notifOk,
      fixLabel: notifOk ? null : 'Allow',
      fix: notifOk
          ? null
          : () async {
              final r = await ph.Permission.notification.request();
              if (r.isPermanentlyDenied) await ph.openAppSettings();
            },
    ));

    // 5. Battery optimisation.
    //
    //    Downgraded from blocker to advisory, and that is a real change worth
    //    being clear about. Under the old design this was the single biggest
    //    cause of lost hours, because Doze would sleep the app and the app WAS
    //    the clock. Now the OS holds the fence and delivering a geofence event
    //    is something Android does regardless of Doze. It still helps — the few
    //    seconds of work after the wake-up are smoother — but it is no longer
    //    the difference between working and not.
    bool ignoring = false;
    try {
      ignoring = await ph.Permission.ignoreBatteryOptimizations.isGranted;
    } catch (_) {}
    out.add(_Check(
      'Battery: unrestricted',
      ignoring
          ? 'This app is exempt from battery optimisation.'
          : 'Recommended, not required. The shop fence is watched by Android '
              'itself now, so this no longer stops your hours recording — but '
              'it gives the app the few seconds it needs to save a punch '
              'cleanly.',
      ok: true,
      warn: !ignoring,
      fixLabel: ignoring ? null : 'Fix now',
      fix: ignoring
          ? null
          : () async {
              await ph.Permission.ignoreBatteryOptimizations.request();
            },
    ));

    // 6. Manufacturer power manager (Samsung / Xiaomi / Huawei / OnePlus).
    out.add(_Check(
      'Phone maker\'s battery saver',
      'Samsung, Xiaomi, Huawei and OnePlus run their own app-killer on top of '
          'Android. Adding Paragon Time Clock to its allowed list is worth '
          'doing, though the shop fence now survives without it.',
      ok: true,
      warn: true,
      fixLabel: 'Open',
      fix: () async {
        await ph.openAppSettings();
      },
    ));

    // 7. WI-FI SCANNING. The one setting that quietly decides whether the
    //    shop fence can work at all.
    //
    //    THIS ROW REPLACED ONE THAT WAS WRONG. The old row said "leave Wi-Fi
    //    switched on" and told people the fence relied on it. It does not.
    //    Android locates the phone by SCANNING — listening for the names of
    //    nearby access points and matching that pattern against Google's
    //    database. It never joins them. Wi-Fi can be switched off and the
    //    fence still works perfectly, PROVIDED scanning is left on.
    //
    //    So the old row asked the crew to do a thing that was not the thing,
    //    and it went amber every afternoon for anyone driving between sites
    //    with nothing to join. A checklist that cries wolf is one people stop
    //    reading, and this one was crying about the wrong animal.
    //
    //    From Google's geofencing troubleshooting guide, which is what makes
    //    this worth a row at all: "On most devices, the geofence service uses
    //    only network location for geofence triggering", and with Wi-Fi
    //    positioning unavailable "your application might never get geofence
    //    alerts." Accuracy goes from 20-50 m to hundreds of metres or worse —
    //    against a 150 m ring, that is the difference between working and not.
    //
    //    THE STATUS IS DELIBERATELY ALLOWED TO BE "UNKNOWN".
    //    Android deprecated isScanAlwaysAvailable() in API 29 but left
    //    ACTION_REQUEST_SCAN_ALWAYS_AVAILABLE alone. We can fix it reliably;
    //    we cannot read it reliably. So this never paints red off a value it
    //    cannot stand behind — it says "not checked" and keeps the fix one tap
    //    away. An empty result is not evidence. That mistake, in a different
    //    file, is what produced 33 punches in one day.
    if (WifiScanning.supported) {
      // Only ask the OS if the dialog has not already given us a better answer.
      _scanningOn ??= await WifiScanning.isOn();
      final scanning = _scanningOn;

      out.add(_Check(
        'Wi-Fi scanning',
        scanning == true
            ? 'On. This is what lets your phone notice the shop — it listens '
                'for nearby Wi-Fi names as landmarks. It never joins them and '
                'it needs no password.\n\n'
                'Wi-Fi itself can stay switched off. Only this matters.'
            : scanning == false
                ? 'Off. Your phone cannot work out where it is well enough to '
                    'notice the shop, so your hours may not record at all.\n\n'
                    'Tap below and say yes to Android\'s question. It takes one '
                    'tap and does not use battery or data.'
                : 'Your phone will not tell us whether this is on, which is '
                    'normal on newer Android and is not a fault.\n\n'
                    'It is on by default. Tap below to be sure — Android will '
                    'ask you once and that is the whole job.',
        // AMBER, NEVER RED — including when the phone says it is off.
        //
        // ok:true is what keeps it out of the red band, and that is on purpose:
        // the read behind it was deprecated in API 29, so a red "your hours
        // will not record" could be painted off a value Android no longer
        // promises to keep current. Amber says look at this; red says your pay
        // is broken. Only one of those is safe to claim from a deprecated call.
        ok: true,
        warn: scanning != true,
        // Different words for different states. "Turn on" is a lie when we do
        // not know it is off, and a button that misdescribes what it is about
        // to do is how people learn to ignore buttons.
        fixLabel: scanning == true
            ? null
            : scanning == false
                ? 'Turn on'
                : 'Check',
        fix: scanning == true
            ? null
            : () async {
                final r = await WifiScanning.request();
                // Only believe a definite answer. Null means the dialog was
                // not available and we sent them to Location settings instead,
                // where we have no way to see what they did — so we keep
                // saying "not checked" rather than inventing a result.
                if (r != null) _scanningOn = r;
              },
      ));
    }

    // 8. THE "SHOP WI-FI BACKUP" ROW USED TO BE HERE. REMOVED 2 AUGUST 2026.
    //
    //    THE SIGNAL STILL RUNS. Only the row is gone. Being joined to the shop
    //    network is still a presence signal in geofence.dart — it still starts
    //    a shift when GPS cannot see through the roof, and it still vetoes a
    //    departure while the phone is sitting on the shop network. Deleting a
    //    checklist row does not touch any of that, and nobody's hours change
    //    because of this edit.
    //
    //    Why it went: it told the crew nothing they could act on. The row said
    //    "nothing to do" in almost every state it could be in, and the one
    //    state that needed doing something about was an admin's job, not
    //    theirs. Worse, it sat directly beneath a Wi-Fi row and invited exactly
    //    the wrong conclusion — that joining the shop network helps the fence.
    //    It does not. The fence positions the phone by SCANNING for nearby
    //    network names as landmarks and never joins anything. Two Wi-Fi rows
    //    side by side, one of them irrelevant to the fence, is how that
    //    misunderstanding got made in the first place.
    //
    //    A checklist earns its place by listing things a person can fix. This
    //    row was inventory.

    final pp = await PunchQueue.pendingCount();
    final pg = await Presence.pendingCount();
    final ci = await PunchQueue.isClockedIn();

    setState(() {
      _checks = out;
      _pendingPunches = pp;
      _pendingPings = pg;
      _clockedIn = ci;
      _checking = false;
    });
  }

  Future<void> _runFix(_Check c) async {
    if (c.fix == null) return;
    await c.fix!();
    await Future.delayed(const Duration(milliseconds: 600));
    await _runChecks();
  }

  // -------------------------------------------------------------------------
  //  "How many hours have I got?"
  //
  //  ON DEMAND ONLY. Nothing here polls, refreshes itself, or runs unless a
  //  person taps the button. It reads and never writes, and it cannot touch a
  //  punch or the clocked-in flag. That restraint is the whole design: the two
  //  worst failures this app has had were both helpful-looking code running on
  //  its own schedule near the punch path.
  //
  //  If every line of this is wrong, the cost is a wrong number on a screen —
  //  not a wrong number on a paycheque.
  // -------------------------------------------------------------------------
  bool _hoursLoading = false;
  CrewHours? _hours;
  String? _hoursError;

  Future<void> _loadHours() async {
    setState(() {
      _hoursLoading = true;
      _hoursError = null;
    });
    try {
      final h = await CrewHours.fetch();
      if (!mounted) return;
      setState(() {
        _hours = h;
        _hoursLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Tell the two failures apart. "Not registered" is a real answer that a
      // person can act on — it means this handset is not the one bound to that
      // name, which is what happens on a replacement phone. "Try again later"
      // sent for that case would have somebody tapping a button forever.
      final refused = e.toString().contains('not registered');
      setState(() {
        // Show the failure. A zero here would be believed.
        _hoursError = refused
            ? 'This phone is not registered to your name — ask Kent to reset '
                'it for your new phone.'
            : 'Could not reach the server. Try again in a minute.';
        _hoursLoading = false;
      });
    }
  }

  Widget _hoursCard() {
    final h = _hours;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('My hours',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                if (_hoursLoading)
                  const SizedBox(
                      height: 15,
                      width: 15,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else
                  SizedBox(
                    height: 32,
                    child: OutlinedButton(
                      onPressed: _loadHours,
                      child: Text(h == null ? 'Show my hours' : 'Refresh'),
                    ),
                  ),
              ],
            ),
            if (h == null && _hoursError == null && !_hoursLoading) ...[
              const SizedBox(height: 6),
              const Text(
                'Your pay-period total, straight from the office system.',
                style: TextStyle(fontSize: 12.5, color: Colors.black54),
              ),
            ],
            if (_hoursError != null) ...[
              const SizedBox(height: 8),
              Text(_hoursError!,
                  style: const TextStyle(fontSize: 12.5, color: Colors.red)),
            ],
            if (h != null) ...[
              const SizedBox(height: 10),
              Text(h.periodLine,
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(h.paidHours.toStringAsFixed(1),
                      style: const TextStyle(
                          fontSize: 30, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 5),
                  const Text('hrs',
                      style: TextStyle(fontSize: 13, color: Colors.black54)),
                  const Spacer(),
                  Text('${h.daysWorked} day${h.daysWorked == 1 ? '' : 's'}',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.black54)),
                ],
              ),
              if (h.otHours > 0)
                Text(
                  'Regular ${h.regHours.toStringAsFixed(1)} · '
                  'Overtime ${h.otHours.toStringAsFixed(1)}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              const Divider(height: 18),
              Text('Today: ${h.todayLine}',
                  style: const TextStyle(fontSize: 12.5)),
              // The 31 July failure, made visible instead of silent. Punches in
              // the database that nobody has turned into hours read as 0.0 —
              // identical to having worked nothing. Never let that pass as an
              // answer.
              if (h.looksUncomputed) ...[
                const SizedBox(height: 8),
                const Text(
                  'Your days have not been totalled up yet. This is not zero '
                  'hours — it means the office system has not run. Tell Kent '
                  'if it stays like this.',
                  style: TextStyle(fontSize: 12, color: Color(0xFFB26A00)),
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                'Today is not final until the day is closed. If a number looks '
                'wrong, use "Report a problem" below.',
                style: TextStyle(fontSize: 11.5, color: Colors.black45),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  //  "Something's wrong with my hours"
  //
  //  The crew's way of raising a hand. It files a note for the admin and
  //  changes nothing by itself — see dispute.dart for why that limit is real
  //  rather than cautious.
  //
  //  Deliberately NOT a punch button. Giving people a way to clock themselves
  //  in and out is the thing that quietly turns an automatic clock into a worse
  //  honour system, because it is what everyone reaches for the moment the
  //  fence is a minute slow.
  // -------------------------------------------------------------------------
  Future<void> _reportProblem() async {
    final noteCtl = TextEditingController();
    final inCtl = TextEditingController();
    final outCtl = TextEditingController();
    var forDate = DateTime.now();

    final sent = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text("Report a problem"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This sends a note to Kent. It does not change your hours by '
                  'itself — he reviews it and fixes the day.',
                  style: TextStyle(fontSize: 12.5, color: Colors.black54),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Text('Which day?',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    TextButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: forDate,
                          firstDate: DateTime.now()
                              .subtract(const Duration(days: 45)),
                          lastDate: DateTime.now(),
                        );
                        if (picked != null) setLocal(() => forDate = picked);
                      },
                      child: Text(
                        '${forDate.year}-${forDate.month.toString().padLeft(2, '0')}-${forDate.day.toString().padLeft(2, '0')}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: noteCtl,
                  minLines: 3,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'What happened?',
                    hintText: 'e.g. I was here until 5 but it clocked me out '
                        'at 2:40',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('If you know the right times (optional)',
                    style: TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: inCtl,
                        decoration: const InputDecoration(
                          labelText: 'Started',
                          hintText: '07:30',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: outCtl,
                        decoration: const InputDecoration(
                          labelText: 'Finished',
                          hintText: '17:00',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _pblue),
              onPressed: () async {
                if (noteCtl.text.trim().isEmpty) return;
                final ok = await Dispute.file(
                  workDate: forDate,
                  note: noteCtl.text,
                  claimedIn: inCtl.text,
                  claimedOut: outCtl.text,
                );
                if (ctx.mounted) Navigator.pop(ctx, ok);
              },
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );

    if (!mounted || sent == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: sent ? _pgreen : _pred,
      content: Text(sent
          ? 'Sent. Kent will see it on the dashboard.'
          : 'Could not send — no connection. Try again when you have signal.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Paragon Time Clock'),
        backgroundColor: _pblue,
        foregroundColor: Colors.white,
        actions: [
          if (_phase == _Phase.active)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _checking ? null : _runChecks,
              tooltip: 'Re-check',
            ),
        ],
      ),
      body: switch (_phase) {
        _Phase.booting => const Center(child: CircularProgressIndicator()),
        _Phase.picking => _buildPicker(),
        _Phase.active => _buildActive(),
      },
    );
  }

  Widget _buildPicker() {
    if (_loadingCrew) return const Center(child: CircularProgressIndicator());
    if (_crewError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.wifi_off, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(_crewError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadCrew,
                style: FilledButton.styleFrom(backgroundColor: _pblue),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _pred, width: 3)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Who is this phone?',
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold, color: _pblue)),
              SizedBox(height: 4),
              Text('Tap your name once. You only do this the first time.',
                  style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
        Expanded(
          child: _crew.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No active crew found. Ask your admin to add you in the '
                      'dashboard, then tap "Try again".',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: _crew.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final m = _crew[i];
                    return ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: _pblue,
                        child: Icon(Icons.person, color: Colors.white),
                      ),
                      title: Text(m.name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _pick(m),
                    );
                  },
                ),
        ),
        if (_crew.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextButton(
                onPressed: _loadCrew, child: const Text('Refresh list')),
          ),
      ],
    );
  }

  Widget _buildActive() {
    final blockers = _checks.where((c) => !c.ok).length;
    final covered = blockers == 0;

    return RefreshIndicator(
      onRefresh: _runChecks,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // --- Headline state -------------------------------------------
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: covered ? _pgreen : _pred,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                Icon(covered ? Icons.verified : Icons.warning_amber_rounded,
                    color: Colors.white, size: 40),
                const SizedBox(height: 10),
                Text(
                  covered
                      ? 'You\'re covered'
                      : '$blockers thing${blockers == 1 ? '' : 's'} need'
                          '${blockers == 1 ? 's' : ''} fixing',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  covered
                      ? 'Your hours are recorded automatically at the shop.'
                      : 'Until these are fixed your hours may not record '
                          'correctly.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          if (_who != null)
            Card(
              child: ListTile(
                leading: const CircleAvatar(
                    backgroundColor: _pblue,
                    child: Icon(Icons.person, color: Colors.white)),
                title: Text(_who!,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(_clockedIn
                    ? 'On the clock at the shop'
                    : 'Off the clock'),
                trailing: Icon(
                  _clockedIn ? Icons.play_circle : Icons.pause_circle,
                  color: _clockedIn ? _pgreen : Colors.grey,
                ),
              ),
            ),

          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text('Setup',
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16, color: _pblue)),
          ),

          if (_checking)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            ..._checks.map((c) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          c.ok
                              ? (c.warn
                                  ? Icons.info_outline
                                  : Icons.check_circle)
                              : Icons.error_outline,
                          color: c.ok
                              ? (c.warn ? _pamber : _pgreen)
                              : _pred,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(c.title,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              Text(c.detail,
                                  style: const TextStyle(
                                      fontSize: 12.5, color: Colors.black54)),
                              if (c.fixLabel != null) ...[
                                const SizedBox(height: 10),
                                SizedBox(
                                  height: 34,
                                  child: FilledButton(
                                    onPressed: () => _runFix(c),
                                    style: FilledButton.styleFrom(
                                        backgroundColor:
                                            c.ok ? _pblue : _pred),
                                    child: Text(c.fixLabel!),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                )),

          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Sync',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text('Punches waiting to send: $_pendingPunches',
                      style: const TextStyle(fontSize: 12.5)),
                  Text('Position reports waiting: $_pendingPings',
                      style: const TextStyle(fontSize: 12.5)),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 34,
                    child: OutlinedButton(
                      onPressed: () async {
                        await PunchQueue.flush();
                        await Presence.flush();
                        await _runChecks();
                      },
                      child: const Text('Send now'),
                    ),
                  ),
                ],
              ),
            ),
          ),


          const SizedBox(height: 12),
          _hoursCard(),

          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Hours not right?',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  const Text(
                    'Tell Kent rather than letting it go through wrong. You '
                    'are the only one who knows what actually happened.',
                    style: TextStyle(fontSize: 12.5, color: Colors.black54),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 34,
                    child: OutlinedButton.icon(
                      onPressed: _reportProblem,
                      icon: const Icon(Icons.flag_outlined, size: 17),
                      label: const Text('Report a problem'),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 18),
          const Text(
            'Leave the app installed and leave location on "Allow all the '
            'time". It clocks you in and out on its own — there is nothing to '
            'tap each day, and it is fine to close it.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
