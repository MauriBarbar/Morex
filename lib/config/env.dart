import 'package:flutter_dotenv/flutter_dotenv.dart';

class Env {
  static String get alpacaApiKey => dotenv.env['ALPACA_API_KEY'] ?? '';
  static String get alpacaApiSecret => dotenv.env['ALPACA_API_SECRET'] ?? '';
  static String get alpacaBaseUrl =>
      dotenv.env['ALPACA_BASE_URL'] ?? 'https://paper-api.alpaca.markets';
  static String get claudeApiKey => dotenv.env['CLAUDE_API_KEY'] ?? '';
}
