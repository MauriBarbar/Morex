import 'package:flutter_dotenv/flutter_dotenv.dart';

class Env {
  static String get alpacaApiKey => dotenv.env['ALPACA_API_KEY'] ?? '';
  static String get alpacaApiSecret => dotenv.env['ALPACA_API_SECRET'] ?? '';

  /// When true, trades hit the real Alpaca API with real money.
  static bool get isLiveTrading =>
      (dotenv.env['ALPACA_LIVE'] ?? 'false').toLowerCase() == 'true';

  static String get alpacaBaseUrl {
    if (isLiveTrading) {
      return dotenv.env['ALPACA_BASE_URL'] ?? 'https://api.alpaca.markets';
    }
    return dotenv.env['ALPACA_BASE_URL'] ?? 'https://paper-api.alpaca.markets';
  }

  static String get alpacaDataBaseUrl =>
      dotenv.env['ALPACA_DATA_BASE_URL'] ?? 'https://data.alpaca.markets';

  static String get alpacaDataStreamUrl =>
      dotenv.env['ALPACA_DATA_STREAM_URL'] ?? 'wss://stream.data.alpaca.markets/v2/iex';

  static String get alpacaTradingStreamUrl {
    if (isLiveTrading) {
      return dotenv.env['ALPACA_TRADING_STREAM_URL'] ?? 'wss://api.alpaca.markets/stream';
    }
    return dotenv.env['ALPACA_TRADING_STREAM_URL'] ?? 'wss://paper-api.alpaca.markets/stream';
  }

  static bool get isConfigured =>
      alpacaApiKey.isNotEmpty && alpacaApiSecret.isNotEmpty;
}
