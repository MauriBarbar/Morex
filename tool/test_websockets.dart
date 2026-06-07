import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> main() async {
  // Load .env manually (no Flutter needed)
  final envFile = File('.env');
  if (!envFile.existsSync()) {
    print('ERROR: .env file not found');
    exit(1);
  }

  final env = <String, String>{};
  for (final line in envFile.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final idx = trimmed.indexOf('=');
    if (idx > 0) {
      env[trimmed.substring(0, idx).trim()] = trimmed.substring(idx + 1).trim();
    }
  }

  final apiKey = env['ALPACA_API_KEY'] ?? '';
  final apiSecret = env['ALPACA_API_SECRET'] ?? '';

  if (apiKey.isEmpty || apiSecret.isEmpty) {
    print('ERROR: ALPACA_API_KEY or ALPACA_API_SECRET not set in .env');
    exit(1);
  }

  print('API Key: ${apiKey.substring(0, 4)}...${apiKey.substring(apiKey.length - 4)}');
  print('');

  // Test data stream with multiple URL candidates
  for (final dataUrl in [
    'wss://stream.data.alpaca.markets/v2/iex',
    'wss://stream.data.sandbox.alpaca.markets/v2/iex',
  ]) {
    await testConnection(
      name: 'Data Stream ($dataUrl)',
      url: dataUrl,
      apiKey: apiKey,
      apiSecret: apiSecret,
      sendAuthOnConnect: false, // Wait for server hello
      onConnected: (sink) {
        sink.add(jsonEncode({
          'action': 'subscribe',
          'trades': ['AAPL'],
          'quotes': ['AAPL'],
        }));
      },
    );
    print('');
  }

  // Test trading stream — send auth immediately (no server hello)
  await testConnection(
    name: 'Trading Stream (paper)',
    url: env['ALPACA_TRADING_STREAM_URL'] ?? 'wss://paper-api.alpaca.markets/stream',
    apiKey: apiKey,
    apiSecret: apiSecret,
    sendAuthOnConnect: true,
    onConnected: (sink) {
      sink.add(jsonEncode({
        'action': 'listen',
        'data': {'streams': ['trade_updates']},
      }));
    },
  );
}

Future<void> testConnection({
  required String name,
  required String url,
  required String apiKey,
  required String apiSecret,
  required bool sendAuthOnConnect,
  required void Function(WebSocketSink sink) onConnected,
}) async {
  print('--- $name ---');

  final completer = Completer<void>();
  bool authenticated = false;

  try {
    final channel = WebSocketChannel.connect(Uri.parse(url));
    print('  [+] Connected');

    if (sendAuthOnConnect) {
      print('  >>> Sending auth immediately...');
      channel.sink.add(jsonEncode({
        'action': 'auth',
        'key': apiKey,
        'secret': apiSecret,
      }));
    }

    final sub = channel.stream.listen(
      (raw) {
        String rawStr;
        if (raw is List<int>) {
          rawStr = utf8.decode(raw);
        } else {
          rawStr = raw as String;
        }
        final data = jsonDecode(rawStr);
        print('  <<< $data');

        if (data is List) {
          for (final msg in data) {
            if (msg['T'] == 'success' && msg['msg'] == 'connected') {
              if (!sendAuthOnConnect) {
                print('  >>> Sending auth...');
                channel.sink.add(jsonEncode({
                  'action': 'auth',
                  'key': apiKey,
                  'secret': apiSecret,
                }));
              }
            } else if (msg['T'] == 'success' && msg['msg'] == 'authenticated') {
              print('  [+] AUTHENTICATED');
              authenticated = true;
              onConnected(channel.sink);
            } else if (msg['T'] == 'error') {
              print('  [!] ERROR: ${msg['msg']} (code: ${msg['code']})');
            }
          }
        } else if (data is Map) {
          final status = data['data']?['status'] ?? data['status'];
          if (status == 'authorized') {
            print('  [+] AUTHENTICATED');
            authenticated = true;
            onConnected(channel.sink);
          } else if (status == 'unauthorized') {
            print('  [!] AUTH FAILED');
          }
        }
      },
      onError: (e) {
        print('  [!] Error: $e');
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        print('  [x] Connection closed');
        if (!completer.isCompleted) completer.complete();
      },
    );

    await Future.delayed(const Duration(seconds: 8));
    await sub.cancel();
    await channel.sink.close();

    print('  RESULT: ${authenticated ? "OK" : "FAILED"}');
  } catch (e) {
    print('  [!] Connection failed: $e');
    print('  RESULT: FAILED');
  }

  if (!completer.isCompleted) completer.complete();
}
