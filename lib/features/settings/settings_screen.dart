import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:morex/config/env.dart';
import 'package:morex/providers/storage_providers.dart';

// Setting keys — match the defaults in RiskConfig / QuickTradeConfig
const _kStopLossPercent = 'risk_stop_loss_pct';
const _kTakeProfitPercent = 'risk_take_profit_pct';
const _kMaxExposurePercent = 'risk_max_exposure_pct';
const _kMaxPositionPercent = 'risk_max_position_pct';
const _kMaxOrderDollars = 'risk_max_order_dollars';
const _kTrailingStopEnabled = 'risk_trailing_stop_enabled';
const _kTrailingStopPercent = 'risk_trailing_stop_pct';
const _kMaxHoldDays = 'risk_max_hold_days';
const _kScanIntervalMin = 'engine_scan_interval_min';
const _kMinConfidence = 'risk_min_confidence';
const _kDailyLossLimit = 'risk_daily_loss_limit_pct';
const _kTakeProfitSellFraction = 'risk_take_profit_sell_fraction';
const _kReEvalSellConfidence = 'risk_re_eval_sell_confidence';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _loaded = false;

  // Risk
  double _stopLoss = 8.0;
  double _takeProfit = 15.0;
  double _maxExposure = 80.0;
  double _maxPosition = 10.0;
  double _maxOrder = 1000;
  bool _trailingStop = true;
  double _trailingStopPct = 5.0;
  int _maxHoldDays = 14;
  double _minConfidence = 60.0;
  double _dailyLossLimit = 3.0;
  double _takeProfitSellFraction = 50.0;
  double _reEvalSellConfidence = 65.0;

  // Engine
  int _scanInterval = 20;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final store = await ref.read(hiveStoreProvider.future);
    setState(() {
      _stopLoss = store.getSetting<double>(_kStopLossPercent, defaultValue: 8.0)!;
      _takeProfit = store.getSetting<double>(_kTakeProfitPercent, defaultValue: 15.0)!;
      _maxExposure = store.getSetting<double>(_kMaxExposurePercent, defaultValue: 80.0)!;
      _maxPosition = store.getSetting<double>(_kMaxPositionPercent, defaultValue: 10.0)!;
      _maxOrder = store.getSetting<double>(_kMaxOrderDollars, defaultValue: 1000)!;
      _trailingStop = store.getSetting<bool>(_kTrailingStopEnabled, defaultValue: true)!;
      _trailingStopPct = store.getSetting<double>(_kTrailingStopPercent, defaultValue: 5.0)!;
      _maxHoldDays = store.getSetting<int>(_kMaxHoldDays, defaultValue: 14)!;
      _minConfidence = store.getSetting<double>(_kMinConfidence, defaultValue: 60.0)!;
      _dailyLossLimit = store.getSetting<double>(_kDailyLossLimit, defaultValue: 3.0)!;
      _takeProfitSellFraction = store.getSetting<double>(_kTakeProfitSellFraction, defaultValue: 50.0)!;
      _reEvalSellConfidence = store.getSetting<double>(_kReEvalSellConfidence, defaultValue: 65.0)!;
      _scanInterval = store.getSetting<int>(_kScanIntervalMin, defaultValue: 20)!;
      _loaded = true;
    });
  }

  Future<void> _save(String key, dynamic value) async {
    final store = await ref.read(hiveStoreProvider.future);
    await store.setSetting(key, value);
  }

  void _applyLowRiskPreset() {
    setState(() {
      _stopLoss = 5.0;
      _takeProfit = 8.0;
      _maxExposure = 60.0;
      _maxPosition = 15.0;
      _maxOrder = 10;
      _trailingStop = true;
      _trailingStopPct = 3.0;
      _maxHoldDays = 7;
      _minConfidence = 75.0;
      _dailyLossLimit = 2.0;
      _takeProfitSellFraction = 75.0;
      _reEvalSellConfidence = 70.0;
      _scanInterval = 20;
    });
    _save(_kStopLossPercent, _stopLoss);
    _save(_kTakeProfitPercent, _takeProfit);
    _save(_kMaxExposurePercent, _maxExposure);
    _save(_kMaxPositionPercent, _maxPosition);
    _save(_kMaxOrderDollars, _maxOrder);
    _save(_kTrailingStopEnabled, _trailingStop);
    _save(_kTrailingStopPercent, _trailingStopPct);
    _save(_kMaxHoldDays, _maxHoldDays);
    _save(_kMinConfidence, _minConfidence);
    _save(_kDailyLossLimit, _dailyLossLimit);
    _save(_kTakeProfitSellFraction, _takeProfitSellFraction);
    _save(_kReEvalSellConfidence, _reEvalSellConfidence);
    _save(_kScanIntervalMin, _scanInterval);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final isLive = Env.isLiveTrading;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          // Trading mode
          _SectionHeader(title: 'Trading Mode'),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isLive ? Colors.red.shade900.withAlpha(50) : Colors.green.shade900.withAlpha(50),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isLive ? Colors.red.shade700 : Colors.green.shade700,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isLive ? Icons.warning_amber_rounded : Icons.science_outlined,
                  color: isLive ? Colors.red.shade300 : Colors.green.shade300,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isLive ? 'LIVE TRADING' : 'PAPER TRADING',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: isLive ? Colors.red.shade300 : Colors.green.shade300,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isLive
                            ? 'Real money. Orders hit the live Alpaca API.'
                            : 'Simulated trades. No real money at risk.',
                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Set ALPACA_LIVE=true in .env to switch to live trading. '
            'Restart the app after changing.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey, fontSize: 10),
          ),
          const Divider(height: 24),

          // Presets
          _SectionHeader(title: 'Quick Presets'),
          Wrap(
            spacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.shield_outlined, size: 16),
                label: const Text('Low Risk (\$50)', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  _applyLowRiskPreset();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Low-risk preset applied — restart engines to apply'),
                      duration: Duration(seconds: 3),
                    ),
                  );
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.restart_alt, size: 16),
                label: const Text('Reset Defaults', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  setState(() {
                    _stopLoss = 8.0;
                    _takeProfit = 15.0;
                    _maxExposure = 80.0;
                    _maxPosition = 10.0;
                    _maxOrder = 1000;
                    _trailingStop = true;
                    _trailingStopPct = 5.0;
                    _maxHoldDays = 14;
                    _minConfidence = 60.0;
                    _dailyLossLimit = 3.0;
                    _takeProfitSellFraction = 50.0;
                    _reEvalSellConfidence = 65.0;
                    _scanInterval = 20;
                  });
                  _save(_kStopLossPercent, _stopLoss);
                  _save(_kTakeProfitPercent, _takeProfit);
                  _save(_kMaxExposurePercent, _maxExposure);
                  _save(_kMaxPositionPercent, _maxPosition);
                  _save(_kMaxOrderDollars, _maxOrder);
                  _save(_kTrailingStopEnabled, _trailingStop);
                  _save(_kTrailingStopPercent, _trailingStopPct);
                  _save(_kMaxHoldDays, _maxHoldDays);
                  _save(_kMinConfidence, _minConfidence);
                  _save(_kDailyLossLimit, _dailyLossLimit);
                  _save(_kTakeProfitSellFraction, _takeProfitSellFraction);
                  _save(_kReEvalSellConfidence, _reEvalSellConfidence);
                  _save(_kScanIntervalMin, _scanInterval);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Defaults restored — restart engines to apply'),
                      duration: Duration(seconds: 3),
                    ),
                  );
                },
              ),
            ],
          ),
          const Divider(height: 24),

          // Risk management
          _SectionHeader(title: 'Risk Management'),
          _SliderTile(
            label: 'Stop Loss',
            value: _stopLoss,
            suffix: '%',
            min: 1,
            max: 20,
            divisions: 38,
            onChanged: (v) {
              setState(() => _stopLoss = v);
              _save(_kStopLossPercent, v);
            },
          ),
          _SliderTile(
            label: 'Take Profit',
            value: _takeProfit,
            suffix: '%',
            min: 2,
            max: 50,
            divisions: 48,
            onChanged: (v) {
              setState(() => _takeProfit = v);
              _save(_kTakeProfitPercent, v);
            },
          ),
          _SliderTile(
            label: 'Max Total Exposure',
            value: _maxExposure,
            suffix: '%',
            min: 10,
            max: 100,
            divisions: 18,
            onChanged: (v) {
              setState(() => _maxExposure = v);
              _save(_kMaxExposurePercent, v);
            },
          ),
          _SliderTile(
            label: 'Max Per Position',
            value: _maxPosition,
            suffix: '%',
            min: 2,
            max: 25,
            divisions: 23,
            onChanged: (v) {
              setState(() => _maxPosition = v);
              _save(_kMaxPositionPercent, v);
            },
          ),
          _NumberTile(
            label: 'Max Order Size',
            value: _maxOrder,
            prefix: '\$',
            onChanged: (v) {
              setState(() => _maxOrder = v);
              _save(_kMaxOrderDollars, v);
            },
          ),
          _SliderTile(
            label: 'Daily Loss Limit',
            value: _dailyLossLimit,
            suffix: '%',
            min: 1,
            max: 10,
            divisions: 18,
            onChanged: (v) {
              setState(() => _dailyLossLimit = v);
              _save(_kDailyLossLimit, v);
            },
          ),
          const Divider(height: 24),

          // Trailing stop
          SwitchListTile(
            title: const Text('Trailing Stop Loss', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              _trailingStop
                  ? 'Moves stop up as price rises'
                  : 'Fixed stop loss only',
              style: const TextStyle(fontSize: 11),
            ),
            value: _trailingStop,
            onChanged: (v) {
              setState(() => _trailingStop = v);
              _save(_kTrailingStopEnabled, v);
            },
          ),
          if (_trailingStop)
            _SliderTile(
              label: 'Trailing Stop Distance',
              value: _trailingStopPct,
              suffix: '%',
              min: 1,
              max: 15,
              divisions: 28,
              onChanged: (v) {
                setState(() => _trailingStopPct = v);
                _save(_kTrailingStopPercent, v);
              },
            ),
          const Divider(height: 24),

          // Position management
          _SectionHeader(title: 'Position Management'),
          _SliderTile(
            label: 'Max Hold Period',
            value: _maxHoldDays.toDouble(),
            suffix: ' days',
            min: 1,
            max: 60,
            divisions: 59,
            decimals: 0,
            onChanged: (v) {
              setState(() => _maxHoldDays = v.round());
              _save(_kMaxHoldDays, v.round());
            },
          ),
          _SliderTile(
            label: 'Min Signal Confidence',
            value: _minConfidence,
            suffix: '%',
            min: 40,
            max: 90,
            divisions: 50,
            onChanged: (v) {
              setState(() => _minConfidence = v);
              _save(_kMinConfidence, v);
            },
          ),
          _SliderTile(
            label: 'Take-Profit Sell %',
            value: _takeProfitSellFraction,
            suffix: '%',
            min: 10,
            max: 100,
            divisions: 18,
            onChanged: (v) {
              setState(() => _takeProfitSellFraction = v);
              _save(_kTakeProfitSellFraction, v);
            },
          ),
          _SliderTile(
            label: 'Re-Eval Sell Confidence',
            value: _reEvalSellConfidence,
            suffix: '%',
            min: 40,
            max: 90,
            divisions: 50,
            onChanged: (v) {
              setState(() => _reEvalSellConfidence = v);
              _save(_kReEvalSellConfidence, v);
            },
          ),
          const Divider(height: 24),

          // Engine
          _SectionHeader(title: 'Engine'),
          _SliderTile(
            label: 'Scan Interval',
            value: _scanInterval.toDouble(),
            suffix: ' min',
            min: 5,
            max: 60,
            divisions: 11,
            decimals: 0,
            onChanged: (v) {
              setState(() => _scanInterval = v.round());
              _save(_kScanIntervalMin, v.round());
            },
          ),
          const SizedBox(height: 8),
          Text(
            'Changes apply next time the engine starts. '
            'Running engines use the config from when they were started.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared widgets
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Text(title,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: Theme.of(context).colorScheme.primary)),
    );
  }
}

class _SliderTile extends StatelessWidget {
  final String label;
  final double value;
  final String suffix;
  final double min;
  final double max;
  final int divisions;
  final int decimals;
  final ValueChanged<double> onChanged;

  const _SliderTile({
    required this.label,
    required this.value,
    required this.suffix,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.decimals = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              '${value.toStringAsFixed(decimals)}$suffix',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _NumberTile extends StatelessWidget {
  final String label;
  final double value;
  final String prefix;
  final ValueChanged<double> onChanged;

  const _NumberTile({
    required this.label,
    required this.value,
    required this.prefix,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          const Spacer(),
          SizedBox(
            width: 120,
            child: TextField(
              controller:
                  TextEditingController(text: value.toStringAsFixed(0)),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                prefixText: prefix,
                isDense: true,
                filled: true,
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              style: const TextStyle(fontSize: 13),
              onSubmitted: (v) {
                final parsed = double.tryParse(v);
                if (parsed != null && parsed > 0) onChanged(parsed);
              },
            ),
          ),
        ],
      ),
    );
  }
}
