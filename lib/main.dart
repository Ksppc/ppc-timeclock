import 'package:flutter/material.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'config.dart';
import 'geofence.dart';
import 'punch_queue.dart';
import 'identity.dart';

const _pblue = Color(0xFF17457F);
const _pred = Color(0xFFC8202F);

void main() {
  runApp(const PpcApp());
  // Register the headless handler so geofence events fire when the app is dead.
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

/// App phase: booting, needs the user to pick their name, or actively tracking.
enum _Phase { booting, picking, active }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  _Phase _phase = _Phase.booting;
  String _status = 'Starting…';
  String? _who;
  int _pending = 0;

  // Picker state
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
    setState(() {
      _phase = _Phase.active;
      _status = 'Starting…';
    });
    await Geofence.init();
    Connectivity().onConnectivityChanged.listen((_) => PunchQueue.flush());
    final n = await PunchQueue.pendingCount();
    setState(() {
      _status = 'Active — you are clocked automatically at the shop.';
      _pending = n;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Paragon Time Clock'),
        backgroundColor: _pblue,
        foregroundColor: Colors.white,
      ),
      body: switch (_phase) {
        _Phase.booting => const Center(child: CircularProgressIndicator()),
        _Phase.picking => _buildPicker(),
        _Phase.active => _buildActive(),
      },
    );
  }

  Widget _buildPicker() {
    if (_loadingCrew) {
      return const Center(child: CircularProgressIndicator());
    }
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
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: _pblue)),
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
                      'dashboard, then tap “Try again”.',
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.location_on, size: 64, color: _pblue),
            const SizedBox(height: 16),
            if (_who != null) ...[
              Text('Signed in as $_who',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold, color: _pblue)),
              const SizedBox(height: 8),
            ],
            Text(_status, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('Pending punches to sync: $_pending',
                style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 24),
            const Text(
              'Nothing to do — leave the app installed with location set to '
              '“Allow all the time.” It clocks you in and out on its own.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
