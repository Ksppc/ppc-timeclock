import 'package:flutter/material.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart'
    as bg;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'config.dart';
import 'geofence.dart';
import 'punch_queue.dart';

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
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1F5FA8)),
        home: const HomeScreen(),
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _status = 'Starting…';
  int _pending = 0;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await Supabase.initialize(
        url: Config.supabaseUrl, anonKey: Config.supabaseAnon);
    await Geofence.init();

    // Flush the offline queue whenever connectivity returns.
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
      appBar: AppBar(title: const Text('Paragon Time Clock')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.location_on, size: 64, color: Color(0xFF1F5FA8)),
              const SizedBox(height: 16),
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
      ),
    );
  }
}
