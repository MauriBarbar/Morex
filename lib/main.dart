import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/config/theme.dart';
import 'package:morex/features/dashboard/dashboard_screen.dart';
import 'package:morex/features/signals/signals_screen.dart';
import 'package:morex/features/trade_log/trade_log_screen.dart';

Future<void> main() async {
  await dotenv.load(fileName: '.env');
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

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  static const _screens = [
    DashboardScreen(),
    SignalsScreen(),
    TradeLogScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard),
            label: 'Portfolio',
          ),
          NavigationDestination(
            icon: Icon(Icons.radar),
            label: 'Signals',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long),
            label: 'Trades',
          ),
        ],
      ),
    );
  }
}
