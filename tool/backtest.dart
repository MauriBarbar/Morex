// CLI backtester — fetches daily bars from Alpaca and runs the
// DipBuyStrategy across a curated liquid universe. Run with:
//
//   dart run tool/backtest.dart [--start YYYY-MM-DD] [--end YYYY-MM-DD]
//                               [--symbols AAPL,NVDA,...]
//                               [--capital 10000] [--per-trade 500]
//
// Reads ALPACA_API_KEY / ALPACA_API_SECRET from .env directly. Pure Dart
// (no Flutter deps), so `dart run` works without a Flutter environment.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:morex/backtest/backtest_simulator.dart';
import 'package:morex/backtest/backtest_strategy.dart';
import 'package:morex/core/models/historical_bar.dart';

const _defaultUniverse = [
  'AAPL', 'MSFT', 'GOOGL', 'META', 'AMZN',
  'NVDA', 'AMD', 'TSM', 'AVGO',
  'TSLA', 'JPM', 'BAC',
  'XOM', 'CVX',
  'JNJ', 'LLY',
  'WMT', 'COST', 'HD',
  'SPY', 'QQQ', 'IWM',
];

Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  final env = _loadEnv();

  final apiKey = env['ALPACA_API_KEY'] ?? '';
  final apiSecret = env['ALPACA_API_SECRET'] ?? '';
  if (apiKey.isEmpty || apiSecret.isEmpty) {
    stderr.writeln('Missing ALPACA_API_KEY / ALPACA_API_SECRET in .env');
    exit(1);
  }

  final dio = Dio(BaseOptions(
    baseUrl: 'https://data.alpaca.markets',
    headers: {
      'APCA-API-KEY-ID': apiKey,
      'APCA-API-SECRET-KEY': apiSecret,
    },
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
  ));

  final BacktestStrategy strategy = switch (opts.strategy) {
    'breakout' => BreakoutStrategy(),
    'dip' => DipBuyStrategy(),
    final s => throw ArgumentError('Unknown strategy: $s (use "dip" or "breakout")'),
  };

  final config = BacktestConfig(
    symbols: opts.symbols,
    start: opts.start,
    end: opts.end,
    initialCapital: opts.capital,
    dollarsPerTrade: opts.dollarsPerTrade,
    strategy: strategy,
  );

  stdout.writeln('Running backtest...');
  stdout.writeln('  strategy:  ${opts.strategy}');
  stdout.writeln('  symbols:   ${opts.symbols.length} '
      '(${opts.symbols.take(5).join(", ")}'
      '${opts.symbols.length > 5 ? "..." : ""})');
  stdout.writeln('  range:     ${_fmt(opts.start)} → ${_fmt(opts.end)}');
  stdout.writeln('  capital:   \$${opts.capital.toStringAsFixed(0)}');
  stdout.writeln('  per-trade: \$${opts.dollarsPerTrade.toStringAsFixed(0)}');
  stdout.writeln('');

  try {
    final sim = BacktestSimulator(barsFetcher: _makeFetcher(dio));
    final report = await sim.run(config);
    stdout.writeln(report.formatHuman());

    if (report.totalTrades == 0) {
      stdout.writeln('NOTE: 0 trades. Check date range, symbols, or strategy '
          'thresholds — universally suggests no setups triggered.');
    } else if (report.expectancy <= 0) {
      stdout.writeln('VERDICT: Negative expectancy. Strategy is unprofitable '
          'on this period and universe. DO NOT GO LIVE without a different edge.');
    } else {
      stdout.writeln('VERDICT: Positive expectancy. Worth investigating '
          'further (5-min bars, longer date range, walk-forward).');
    }
  } catch (e, st) {
    stderr.writeln('Backtest failed: $e');
    stderr.writeln(st);
    exit(2);
  }
}

BarsFetcher _makeFetcher(Dio dio) {
  return (
    List<String> symbols, {
    String timeframe = '1Day',
    int limit = 10000,
    DateTime? start,
    DateTime? end,
  }) async {
    if (symbols.isEmpty) return {};
    final params = <String, dynamic>{
      'symbols': symbols.join(','),
      'timeframe': timeframe,
      'limit': limit,
    };
    // Alpaca accepts either RFC3339 with timezone or date-only YYYY-MM-DD.
    // We use date-only since daily-bar backtests don't need intraday
    // precision — and Dart's toIso8601String() omits the trailing Z which
    // makes Alpaca reject it as malformed.
    if (start != null) params['start'] = _fmtDate(start);
    if (end != null) params['end'] = _fmtDate(end);
    // Free-tier accounts only have access to the IEX feed for historical
    // bars. SIP requires a paid subscription. IEX is fine for liquid
    // mega-caps (which all trade on multiple venues including IEX).
    params['feed'] = 'iex';
    final Response<dynamic> response;
    try {
      response = await dio.get('/v2/stocks/bars', queryParameters: params);
    } on DioException catch (e) {
      // Surface the actual Alpaca error body — much more useful than the
      // generic Dio "bad response" wrapper.
      final body = e.response?.data;
      throw Exception('Alpaca /v2/stocks/bars failed (${e.response?.statusCode}): $body');
    }
    final barsData = response.data['bars'] as Map<String, dynamic>? ?? {};
    return barsData.map((symbol, json) {
      final list = (json as List?)?.cast<Map<String, dynamic>>() ?? [];
      return MapEntry(symbol, list.map(HistoricalBar.fromJson).toList());
    });
  };
}

class _CliOpts {
  final List<String> symbols;
  final DateTime start;
  final DateTime end;
  final double capital;
  final double dollarsPerTrade;
  final String strategy;
  _CliOpts({
    required this.symbols,
    required this.start,
    required this.end,
    required this.capital,
    required this.dollarsPerTrade,
    required this.strategy,
  });
}

_CliOpts _parseArgs(List<String> args) {
  String? sStart;
  String? sEnd;
  String? sSymbols;
  String? sCapital;
  String? sPerTrade;
  String? sStrategy;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--start' && i + 1 < args.length) {
      sStart = args[++i];
    } else if (a == '--end' && i + 1 < args.length) {
      sEnd = args[++i];
    } else if (a == '--symbols' && i + 1 < args.length) {
      sSymbols = args[++i];
    } else if (a == '--capital' && i + 1 < args.length) {
      sCapital = args[++i];
    } else if (a == '--per-trade' && i + 1 < args.length) {
      sPerTrade = args[++i];
    } else if (a == '--strategy' && i + 1 < args.length) {
      sStrategy = args[++i];
    }
  }
  // Default: ~1 year ending yesterday. Daily bars are released after close,
  // so yesterday is safely complete.
  final end = sEnd != null
      ? DateTime.parse(sEnd)
      : DateTime.now().subtract(const Duration(days: 1));
  final start = sStart != null
      ? DateTime.parse(sStart)
      : end.subtract(const Duration(days: 365));
  final symbols = sSymbols != null
      ? sSymbols.split(',').map((s) => s.trim().toUpperCase()).toList()
      : _defaultUniverse;
  return _CliOpts(
    symbols: symbols,
    start: start,
    end: end,
    capital: double.tryParse(sCapital ?? '10000') ?? 10000,
    dollarsPerTrade: double.tryParse(sPerTrade ?? '500') ?? 500,
    strategy: (sStrategy ?? 'dip').toLowerCase(),
  );
}

Map<String, String> _loadEnv() {
  final envFile = File('.env');
  if (!envFile.existsSync()) {
    stderr.writeln('ERROR: .env file not found in working directory');
    exit(1);
  }
  final env = <String, String>{};
  for (final line in envFile.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final idx = trimmed.indexOf('=');
    if (idx > 0) {
      env[trimmed.substring(0, idx).trim()] =
          trimmed.substring(idx + 1).trim();
    }
  }
  return env;
}

String _fmt(DateTime d) => _fmtDate(d);

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
