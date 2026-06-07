import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/config/env.dart';
import 'package:morex/config/theme.dart';
import 'package:morex/features/dashboard/dashboard_screen.dart';
import 'package:morex/features/quick_trade/quick_trade_screen.dart';
import 'package:morex/features/signals/signals_screen.dart';
import 'package:morex/features/settings/settings_screen.dart';
import 'package:morex/features/trade_log/trade_log_screen.dart';
import 'package:morex/providers/signal_providers.dart';
import 'package:morex/providers/stream_providers.dart';
import 'package:morex/services/background_quick_trade_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await setupNotificationChannel();
  await initializeBackgroundService();
  runApp(const ProviderScope(child: MorexApp()));
}

class MorexApp extends StatelessWidget {
  const MorexApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Morex',
      theme: AppTheme.dark,
      debugShowCheckedModeBanner: false,
      home: const MainShell(),
    );
  }
}

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with WidgetsBindingObserver {
  int _index = 0;

  static const _screens = [
    DashboardScreen(),
    QuickTradeScreen(),
    SignalsScreen(),
    TradeLogScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final dataWs = ref.read(dataWebSocketProvider);
    final tradingWs = ref.read(tradingWebSocketProvider);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      dataWs.disconnect();
      tradingWs.disconnect();
    } else if (state == AppLifecycleState.resumed) {
      dataWs.connect();
      tradingWs.connect();
      // Reconcile any fills that arrived while the WebSocket was disconnected.
      FlutterBackgroundService().invoke('reconcile');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Bootstrap the periodic 20-min signal auto-scan so it runs even when the
    // user is not on the Signals tab.
    ref.watch(signalAutoScanProvider);
    final isLive = Env.isLiveTrading;

    return Scaffold(
      body: Column(
        children: [
          if (isLive)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 4),
              color: Colors.red.shade900,
              child: const Text(
                'LIVE TRADING — REAL MONEY',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          Expanded(child: _screens[_index]),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard),
            label: 'Portfolio',
          ),
          NavigationDestination(
            icon: Icon(Icons.bolt),
            label: 'Quick Trade',
          ),
          NavigationDestination(
            icon: Icon(Icons.radar),
            label: 'Signals',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long),
            label: 'Trades',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
