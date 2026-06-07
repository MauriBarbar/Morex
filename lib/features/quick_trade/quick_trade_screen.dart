import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/core/logger.dart';
import 'package:morex/core/models/market_clock.dart';
import 'package:morex/core/models/trade_log.dart';
import 'package:morex/engine/quick_trade_engine.dart';
import 'package:morex/providers/alpaca_providers.dart';
import 'package:morex/providers/market_data_providers.dart';
import 'package:morex/providers/quick_trade_providers.dart';
import 'package:morex/providers/storage_providers.dart';

const _defaultWatchlist = [
  'AAPL', 'MSFT', 'GOOGL', 'AMZN', 'NVDA', 'META', 'TSLA',
  'AVGO', 'AMD', 'INTC', 'QCOM', 'ARM', 'SMCI',
  'ORCL', 'CRM', 'ADBE', 'NFLX', 'CRWD', 'PLTR', 'SNOW',
  'V', 'MA', 'PYPL', 'COIN',
  'JPM', 'GS', 'BAC',
  'JNJ', 'UNH', 'LLY', 'PFE',
  'WMT', 'COST', 'HD', 'MCD',
  'XOM', 'CVX',
  'BA', 'CAT', 'GE',
  'SPY', 'QQQ', 'IWM',
];

class QuickTradeScreen extends ConsumerStatefulWidget {
  const QuickTradeScreen({super.key});

  @override
  ConsumerState<QuickTradeScreen> createState() => _QuickTradeScreenState();
}

class _QuickTradeScreenState extends ConsumerState<QuickTradeScreen>
    with WidgetsBindingObserver {
  StreamSubscription? _emergencyStopSub;
  double _budget = 500.0;
  List<String> _watchlist = List.of(_defaultWatchlist);

  /// First-seen timestamps for each log fingerprint. We use a counter alongside
  /// the fingerprint to disambiguate identical-looking entries (e.g. multiple
  /// skip logs with null orderId at the same millisecond).
  final Map<String, DateTime> _firstSeenAt = {};
  Timer? _highlightFadeTimer;
  static const _highlightWindow = Duration(seconds: 5);

  /// Stable fingerprint for a log entry. Uses orderId when present; otherwise
  /// falls back to ticker+action so multiple skip logs (which share no
  /// orderId) collapse to the same base — disambiguated by a per-batch
  /// counter at the call site.
  String _logFingerprint(TradeLog log) {
    return log.orderId ?? '${log.ticker}|${log.action.name}';
  }

  void _trackNewLogs(List<TradeLog> logs) {
    final now = DateTime.now();
    final fingerprintCounts = <String, int>{};
    var newCount = 0;
    // Iterate in the same order _buildRecentTiles uses so #n counters align.
    for (final log in _sortedRecent(logs)) {
      final base = _logFingerprint(log);
      final n = fingerprintCounts[base] ?? 0;
      fingerprintCounts[base] = n + 1;
      final key = '$base#$n';
      if (!_firstSeenAt.containsKey(key)) {
        _firstSeenAt[key] = now;
        newCount++;
      }
    }
    if (_firstSeenAt.length > 200) {
      // Keep memory bounded; drop the oldest entries beyond a small cap.
      final entries = _firstSeenAt.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final remove = entries.take(_firstSeenAt.length - 200);
      for (final e in remove) {
        _firstSeenAt.remove(e.key);
      }
    }
    if (newCount > 0) {
      _highlightFadeTimer?.cancel();
      _highlightFadeTimer = Timer(_highlightWindow, () {
        if (mounted) setState(() {});
      });
    }
  }

  bool _isHighlighted(String key) {
    final ts = _firstSeenAt[key];
    if (ts == null) return false;
    return DateTime.now().difference(ts) < _highlightWindow;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    Future.microtask(() async {
      final store = await ref.read(hiveStoreProvider.future);
      final savedBudget = store.getSetting<double>('quick_trade_last_budget');
      if (savedBudget != null && savedBudget > 0) {
        setState(() => _budget = savedBudget);
      }
      final stored = store.getSetting<List>('quick_trade_watchlist');
      if (stored != null && stored.isNotEmpty) {
        final symbols = stored
            .map((s) => '$s'.trim().toUpperCase())
            .where((s) => s.isNotEmpty)
            .toList();
        if (symbols.isNotEmpty) setState(() => _watchlist = symbols);
      }
    });

    final service = FlutterBackgroundService();
    _emergencyStopSub = service.on('emergency_stop_complete').listen((event) {
      if (!mounted) return;
      final error = event?['error'] as String?;
      final cancelled = event?['cancelledCount'] as int? ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error != null
            ? 'Emergency stop failed: $error'
            : 'Stopped. Cancelled $cancelled orders.'),
        backgroundColor: error != null ? Colors.red : Colors.green,
      ));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(quickTradeServiceProvider).requestStatus();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _emergencyStopSub?.cancel();
    _highlightFadeTimer?.cancel();
    super.dispose();
  }

  Future<void> _start(QuickTradeServiceController controller) async {
    final budget = await _showBudgetSheet();
    if (budget == null || !mounted) return;
    setState(() => _budget = budget);
    unawaited(ref
        .read(hiveStoreProvider.future)
        .then((s) => s.setSetting('quick_trade_last_budget', budget)));

    if (_watchlist.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Watchlist is empty')));
      return;
    }

    try {
      final client = ref.read(alpacaClientProvider);
      final result = await client.validateSymbols(_watchlist);
      if (result.notFound.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Not found: ${result.notFound.join(", ")}'),
          duration: const Duration(seconds: 3),
        ));
      }
      if (result.tradable.isNotEmpty) {
        controller.start(result.tradable, budgetDollars: budget);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No tradable symbols')));
      }
    } catch (e) {
      Log.e('QuickTradeScreen', 'Validation failed', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<double?> _showBudgetSheet() {
    return showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _BudgetSheet(initial: _budget),
    );
  }

  void _showWatchlistSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _WatchlistSheet(
        symbols: _watchlist,
        onSave: (symbols) => setState(() => _watchlist = symbols),
      ),
    );
  }

  List<Widget> _buildRecentTiles(List<TradeLog> logs) {
    final sorted = _sortedRecent(logs);
    final fingerprintCounts = <String, int>{};
    final tiles = <Widget>[];
    for (final log in sorted) {
      final base = _logFingerprint(log);
      final n = fingerprintCounts[base] ?? 0;
      fingerprintCounts[base] = n + 1;
      final key = '$base#$n';
      tiles.add(_TradeTile(log: log, isNew: _isHighlighted(key)));
    }
    return tiles;
  }

  void _emergencyStop(QuickTradeServiceController controller) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_rounded, color: Colors.red, size: 22),
            SizedBox(width: 8),
            Text('Emergency Stop'),
          ],
        ),
        content: const Text(
          'This will stop all engines, cancel all open orders, '
          'and prevent auto-resume.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              controller.emergencyStop();
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Stop Everything'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(quickTradeServiceProvider);
    final statusAsync = ref.watch(quickTradeStatusProvider);
    final logs = ref.watch(quickTradeLogsProvider);
    final analytics = ref.watch(quickTradeAnalyticsProvider);
    final clock = ref.watch(marketClockProvider).valueOrNull;

    // Track first-seen timestamps from log-stream updates (not in build) so we
    // can flag freshly-arrived entries with a fading highlight.
    ref.listen<List<TradeLog>>(quickTradeLogsProvider, (_, next) {
      _trackNewLogs(next);
    });

    final status = statusAsync.valueOrNull ?? const QuickTradeStatus();
    final isRunning = status.state == QuickTradeEngineState.running;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quick Trade'),
        actions: [
          if (isRunning)
            IconButton(
              onPressed: () => _emergencyStop(controller),
              icon: const Icon(Icons.emergency, color: Colors.red, size: 20),
              tooltip: 'Emergency Stop',
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          // iOS warning
          if (Platform.isIOS && isRunning)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.phone_iphone, size: 14, color: Colors.orange),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Keep the app open — iOS may pause background trading.',
                      style: TextStyle(color: Colors.orange, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),

          // Market status
          if (clock != null && !isRunning) _MarketStatusBanner(clock: clock),

          // Main status hero
          _HeroCard(
            status: status,
            analytics: analytics,
            isRunning: isRunning,
          ),
          const SizedBox(height: 12),

          // Watchlist pill row
          _WatchlistRow(
            symbols: _watchlist,
            isRunning: isRunning,
            onEdit: _showWatchlistSheet,
          ),
          const SizedBox(height: 12),

          // Error banner
          if (status.lastError != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                status.lastError!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Stale engine warning
          if (isRunning &&
              status.updatedAt != null &&
              DateTime.now().difference(status.updatedAt!).inSeconds > 120) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 14, color: Colors.orange),
                  const SizedBox(width: 8),
                  Text(
                    'Last update ${DateTime.now().difference(status.updatedAt!).inMinutes}m ago — engine may be stale',
                    style:
                        const TextStyle(color: Colors.orange, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Recent activity
          Text('Recent Activity',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          if (logs.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: Text(
                    isRunning
                        ? 'Scanning for opportunities...'
                        : 'Start a session to begin trading',
                    style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.5)),
                  ),
                ),
              ),
            )
          else
            ..._buildRecentTiles(logs),
        ],
      ),
      floatingActionButton: isRunning
          ? FloatingActionButton.extended(
              onPressed: () => controller.stop(),
              backgroundColor: Colors.red.shade700,
              icon: const Icon(Icons.stop),
              label: const Text('Stop Session'),
            )
          : FloatingActionButton.extended(
              onPressed: () => _start(controller),
              icon: const Icon(Icons.flash_on),
              label: const Text('Start Session'),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Market status banner
// ---------------------------------------------------------------------------

class _MarketStatusBanner extends StatelessWidget {
  final MarketClock clock;

  const _MarketStatusBanner({required this.clock});

  @override
  Widget build(BuildContext context) {
    if (clock.isOpen) return const SizedBox.shrink();

    final nextOpen = clock.nextOpen.toLocal();
    final diff = nextOpen.difference(DateTime.now());
    final timeStr = diff.inHours > 0
        ? '${diff.inHours}h ${diff.inMinutes % 60}m'
        : '${diff.inMinutes}m';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blueGrey.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.nights_stay_outlined, size: 14, color: Colors.grey),
          const SizedBox(width: 8),
          Text(
            'Market closed — opens in $timeStr',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hero card — single card with key numbers
// ---------------------------------------------------------------------------

class _HeroCard extends StatelessWidget {
  final QuickTradeStatus status;
  final QuickTradeAnalytics analytics;
  final bool isRunning;

  const _HeroCard({
    required this.status,
    required this.analytics,
    required this.isRunning,
  });

  @override
  Widget build(BuildContext context) {
    final pnl = status.sessionPnL;
    final pnlColor = pnl >= 0 ? Colors.green : Colors.red;
    final hasSession = isRunning || status.totalTrades > 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status line
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isRunning ? Colors.green : Colors.grey,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  isRunning ? 'Live' : 'Idle',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: isRunning ? Colors.green : Colors.grey,
                  ),
                ),
                if (isRunning) ...[
                  const SizedBox(width: 6),
                  Text(
                    '${status.openPositions} open',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),

            if (hasSession) ...[
              const SizedBox(height: 16),
              // Big P&L number
              Text(
                '${pnl >= 0 ? '+' : ''}\$${pnl.toStringAsFixed(2)}',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: pnlColor,
                      fontWeight: FontWeight.bold,
                    ),
              ),
              Text(
                'Session P&L',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              // Row of secondary stats
              Row(
                children: [
                  _MiniStat(
                    label: 'Budget',
                    value:
                        '\$${status.budgetUsed.toStringAsFixed(0)} / \$${status.budgetLimit.toStringAsFixed(0)}',
                  ),
                  const SizedBox(width: 24),
                  _MiniStat(
                    label: 'Trades',
                    value: '${status.totalTrades}',
                  ),
                  if (analytics.hasData) ...[
                    const SizedBox(width: 24),
                    _MiniStat(
                      label: 'Win rate',
                      value:
                          '${(analytics.winRate * 100).toStringAsFixed(0)}%',
                    ),
                  ],
                ],
              ),
              if (status.budgetLimit > 0) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (status.budgetUsed / status.budgetLimit).clamp(0, 1),
                    backgroundColor: Colors.grey.shade800,
                    color: status.budgetUsed / status.budgetLimit > 0.8
                        ? Colors.red
                        : Colors.amber,
                    minHeight: 3,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;

  const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        Text(value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Watchlist row — horizontal scrollable chips
// ---------------------------------------------------------------------------

class _WatchlistRow extends StatelessWidget {
  final List<String> symbols;
  final bool isRunning;
  final VoidCallback onEdit;

  const _WatchlistRow({
    required this.symbols,
    required this.isRunning,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Watchlist',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(width: 6),
            Text('${symbols.length}',
                style: Theme.of(context).textTheme.bodySmall),
            const Spacer(),
            if (!isRunning)
              TextButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit, size: 14),
                label: const Text('Edit', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 30,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: symbols.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, i) {
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  symbols[i],
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Watchlist editor bottom sheet
// ---------------------------------------------------------------------------

class _WatchlistSheet extends StatefulWidget {
  final List<String> symbols;
  final ValueChanged<List<String>> onSave;

  const _WatchlistSheet({required this.symbols, required this.onSave});

  @override
  State<_WatchlistSheet> createState() => _WatchlistSheetState();
}

class _WatchlistSheetState extends State<_WatchlistSheet> {
  late final TextEditingController _controller;
  late List<String> _symbols;

  @override
  void initState() {
    super.initState();
    _symbols = List.of(widget.symbols);
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _addSymbol() {
    final raw = _controller.text.trim().toUpperCase();
    if (raw.isEmpty) return;
    // Support comma/space separated input
    final toAdd = raw
        .split(RegExp(r'[,\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && !_symbols.contains(s))
        .toList();
    if (toAdd.isNotEmpty) {
      setState(() => _symbols.addAll(toAdd));
      _controller.clear();
    }
  }

  void _resetToDefault() {
    setState(() => _symbols = List.of(_defaultWatchlist));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey.withAlpha(80),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Row(
            children: [
              Text('Edit Watchlist',
                  style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              TextButton(
                onPressed: _resetToDefault,
                child: const Text('Reset', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Add field
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    hintText: 'Add symbol (e.g. AAPL)',
                    isDense: true,
                    filled: true,
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 13),
                  onSubmitted: (_) => _addSymbol(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _addSymbol,
                icon: const Icon(Icons.add, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Chip list
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _symbols
                    .map((s) => InputChip(
                          label: Text(s, style: const TextStyle(fontSize: 11)),
                          onDeleted: () =>
                              setState(() => _symbols.remove(s)),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ))
                    .toList(),
              ),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                widget.onSave(_symbols);
                Navigator.pop(context);
              },
              child: Text('Save (${_symbols.length} symbols)'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Budget bottom sheet
// ---------------------------------------------------------------------------

class _BudgetSheet extends StatefulWidget {
  final double initial;

  const _BudgetSheet({required this.initial});

  @override
  State<_BudgetSheet> createState() => _BudgetSheetState();
}

class _BudgetSheetState extends State<_BudgetSheet> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller =
        TextEditingController(text: widget.initial.toStringAsFixed(0));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _controller.text.replaceAll(',', '').trim();
    final amount = double.tryParse(raw);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }
    if (amount < 10) {
      setState(() => _error = 'Minimum \$10');
      return;
    }
    Navigator.pop(context, amount);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 28,
        bottom: MediaQuery.of(context).viewInsets.bottom + 32,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.grey.withAlpha(80),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text('Session Budget',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Maximum amount the bot can use this session.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            children: [100, 500, 1000, 2500].map((amount) {
              return OutlinedButton(
                onPressed: () {
                  _controller
                    ..text = '$amount'
                    ..selection = TextSelection.fromPosition(
                        TextPosition(offset: _controller.text.length));
                  setState(() => _error = null);
                },
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text('\$$amount', style: const TextStyle(fontSize: 13)),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
            ],
            autofocus: true,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              prefixText: '\$ ',
              errorText: _error,
              filled: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.flash_on),
              label: const Text('Go Live'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Recent-activity helpers
// ---------------------------------------------------------------------------

/// Sort newest-first by createdAt; the background service already pushes them
/// reversed, but resorting locally is cheap and keeps the UI deterministic.
List<TradeLog> _sortedRecent(List<TradeLog> logs) {
  final copy = [...logs]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return copy.take(20).toList();
}

// ---------------------------------------------------------------------------
// Trade tile — highlights for ~5s when first mounted, fading back to normal.
// ---------------------------------------------------------------------------

class _TradeTile extends StatelessWidget {
  final TradeLog log;
  final bool isNew;

  const _TradeTile({required this.log, required this.isNew});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (log.action) {
      TradeAction.buy => (Icons.arrow_upward, Colors.green),
      TradeAction.takeProfitSell => (Icons.check_circle_outline, Colors.teal),
      TradeAction.skip => (Icons.block, Colors.grey),
      _ => (Icons.arrow_downward, Colors.red),
    };

    final priceStr =
        log.price != null ? '\$${log.price!.toStringAsFixed(2)}' : '';
    final time =
        '${log.createdAt.hour.toString().padLeft(2, '0')}:'
        '${log.createdAt.minute.toString().padLeft(2, '0')}';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOut,
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: isNew ? color.withValues(alpha: 0.16) : Colors.transparent,
        border: Border(
          left: BorderSide(
            color: isNew ? color : Colors.transparent,
            width: 3,
          ),
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 8),
          Text(
            log.action.name.toUpperCase(),
            style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 11, color: color),
          ),
          const SizedBox(width: 6),
          Text(log.ticker,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          if (priceStr.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(priceStr, style: const TextStyle(fontSize: 11)),
          ],
          if (isNew) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'NEW',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
          ],
          const Spacer(),
          Text(time,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }
}
