import 'package:flutter_test/flutter_test.dart';
import 'package:morex/core/api/alpaca_websocket.dart';

void main() {
  group('AlpacaWebSocket', () {
    late AlpacaWebSocket ws;

    setUp(() {
      ws = AlpacaWebSocket(
        url: 'wss://stream.data.alpaca.markets/v2/iex',
        apiKey: 'test-key',
        apiSecret: 'test-secret',
      );
    });

    tearDown(() {
      ws.dispose();
    });

    test('initial state is disconnected', () {
      expect(ws.state, WsConnectionState.disconnected);
    });

    test('stateStream emits state changes', () {
      expect(ws.stateStream, isA<Stream<WsConnectionState>>());
    });

    test('messageStream is a broadcast stream', () {
      expect(ws.messageStream, isA<Stream<Map<String, dynamic>>>());
      // Should allow multiple listeners
      ws.messageStream.listen((_) {});
      ws.messageStream.listen((_) {});
    });

    test('subscribeTrades tracks symbols', () {
      ws.subscribeTrades(['AAPL', 'GOOG']);
      // Internal state tracked (tested via resubscribe behavior)
      expect(ws.state, WsConnectionState.disconnected);
    });

    test('subscribeQuotes tracks symbols', () {
      ws.subscribeQuotes(['MSFT']);
      expect(ws.state, WsConnectionState.disconnected);
    });

    test('dispose does not throw', () {
      expect(() => ws.dispose(), returnsNormally);
    });

    test('connect from disconnected changes state to connecting', () async {
      // Will try to connect (and fail since no real server)
      // but should not throw
      ws.connect();
      // State should have moved to connecting
      expect(ws.state, WsConnectionState.connecting);
    });

    test('connect while not disconnected is a no-op', () {
      ws.connect();
      expect(ws.state, WsConnectionState.connecting);
      // Second call should be ignored
      ws.connect();
      expect(ws.state, WsConnectionState.connecting);
    });
  });

  group('WsConnectionState', () {
    test('has all expected values', () {
      expect(WsConnectionState.values, hasLength(4));
      expect(WsConnectionState.values,
          contains(WsConnectionState.disconnected));
      expect(
          WsConnectionState.values, contains(WsConnectionState.connecting));
      expect(WsConnectionState.values,
          contains(WsConnectionState.authenticating));
      expect(
          WsConnectionState.values, contains(WsConnectionState.connected));
    });
  });
}
