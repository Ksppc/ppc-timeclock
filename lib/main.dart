import 'package:flutter/material.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'config.dart';
import 'geofence.dart';
import 'punch_queue.dart';
import 'presence.dart';
import 'identity.dart';

const _pblue = Color(0xFF17457F);
const _pred = Color(0xFFC8202F);
const _pgreen = Color(0xFF1B7F3B);
const _pamber = Color(0xFFB57200);

void main() {
  runApp(const PpcApp());
  bg.BackgroundGeolocation.registerHeadlessTask(Geofence.headlessTask);
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
    await Geofence.init();
    Connectivity().onConnectivityChanged.listen((_) {
      PunchQueue.flush();
      Presence.flush();
    });
    await _runChecks();
  }

  // -------------------------------------------------------------------------
  //  Setup checklist. Everything the phone needs in order for this to work,
  //  each with a button that fixes it. Previously all of this was manual
  //  Android-settings work that only ever got done on the test phone.
  // -------------------------------------------------------------------------
  Future<void> _runChecks() async {
    setState(() => _checking = true);
    final out = <_Check>[];

    // 1. Location permission — must be "Allow all the time".
    int status = bg.ProviderChangeEvent.AUTHORIZATION_STATUS_NOT_DETERMINED;
    bool servicesOn = true;
    try {
      final state = await bg.BackgroundGeolocation.providerState;
      status = state.status;
      servicesOn = state.enabled;
    } catch (_) {}
    final alwaysOn =
        status == bg.ProviderChangeEvent.AUTHORIZATION_STATUS_ALWAYS;
    out.add(_Check(
      'Location: allow all the time',
      alwaysOn
          ? 'Granted.'
          : 'The clock cannot see the shop unless location is set to "Allow all '
              'the time". "While using the app" is not enough — the app is '
              'never open.',
      ok: alwaysOn,
      fixLabel: alwaysOn ? null : 'Grant',
      fix: alwaysOn
          ? null
          : () async {
              await bg.BackgroundGeolocation.requestPermission();
            },
    ));

    // 2. Location services switched on at all.
    out.add(_Check(
      'Location services on',
      servicesOn ? 'On.' : 'Location is switched off on this phone.',
      ok: servicesOn,
      fixLabel: servicesOn ? null : 'Open settings',
      fix: servicesOn
          ? null
          : () async {
              await bg.BackgroundGeolocation.requestPermission();
            },
    ));

    // 3. Battery optimisation — the big one. Android will otherwise put the
    //    app to sleep mid-shift and the clock-out never happens.
    bool ignoring = false;
    try {
      ignoring = await bg.DeviceSettings.isIgnoringBatteryOptimizations;
    } catch (_) {}
    out.add(_Check(
      'Battery: unrestricted',
      ignoring
          ? 'This app is exempt from battery optimisation.'
          : 'Android is allowed to sleep this app. This is the most common '
              'reason a clock-out goes missing.',
      ok: ignoring,
      fixLabel: ignoring ? null : 'Fix now',
      fix: ignoring
          ? null
          : () async {
              final req =
                  await bg.DeviceSettings.showIgnoreBatteryOptimizations();
              await bg.DeviceSettings.show(req);
            },
    ));

    // 4. Manufacturer power manager (Samsung / Xiaomi / Huawei / OnePlus).
    //    These kill background apps on their own schedule regardless of what
    //    Android itself permits.
    out.add(_Check(
      'Phone maker\'s battery saver',
      'Samsung, Xiaomi, Huawei and OnePlus run their own app-killer on top of '
          'Android. If your phone is one of those, add Paragon Time Clock to '
          'its allowed list.',
      ok: true,
      warn: true,
      fixLabel: 'Open',
      fix: () async {
        try {
          final req = await bg.DeviceSettings.showPowerManager();
          await bg.DeviceSettings.show(req);
        } catch (_) {}
      },
    ));

    // 5. Shop Wi-Fi — the backup presence signal.
    final ssid = Geofence.wifiSsid;
    final onWifi = await Presence.onShopWifi(ssid);
    out.add(_Check(
      'Shop Wi-Fi backup',
      ssid == null || ssid.isEmpty
          ? 'No shop network configured — running on GPS alone.'
          : onWifi == true
              ? 'Connected to $ssid. Presence confirmed even without GPS.'
              : onWifi == false
                  ? 'Not on $ssid right now. Join it at the shop and this '
                      'phone stays covered indoors where GPS fails.'
                  : 'Cannot read the Wi-Fi name on this phone. GPS only.',
      ok: onWifi == true || ssid == null || ssid.isEmpty,
      warn: onWifi != true,
    ));

    // 6. Tracking actually running.
    bool enabled = false;
    try {
      final s = await bg.BackgroundGeolocation.state;
      enabled = s.enabled;
    } catch (_) {}
    out.add(_Check(
      'Clock running',
      enabled ? 'Tracking is active.' : 'Tracking is not running.',
      ok: enabled,
      fixLabel: enabled ? null : 'Start',
      fix: enabled
          ? null
          : () async {
              await bg.BackgroundGeolocation.start();
            },
    ));

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

          const SizedBox(height: 18),
          const Text(
            'Leave the app installed and leave location on "Allow all the '
            'time". It clocks you in and out on its own — there is nothing to '
            'tap each day.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
