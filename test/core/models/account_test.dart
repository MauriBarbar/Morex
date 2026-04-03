import 'package:flutter_test/flutter_test.dart';
import 'package:morex/core/models/account.dart';

void main() {
  group('Account', () {
    late Account account;

    setUp(() {
      account = const Account(
        id: 'acc123',
        accountNumber: 'PA123456789',
        status: 'active',
        currency: 'USD',
        equity: 100000,
        cash: 30000,
        buyingPower: 90000,
        portfolioValue: 130000,
        lastEquity: 95000,
      );
    });

    test('dailyPnL calculates equity change', () {
      expect(account.dailyPnL, 5000); // 100000 - 95000
    });

    test('dailyPnLPercent calculates profit percentage', () {
      final dailyPnLPercent = 5000 / 95000 * 100;
      expect(
        account.dailyPnLPercent,
        closeTo(dailyPnLPercent, 0.01),
      );
    });

    test('dailyPnLPercent returns 0 when lastEquity is 0', () {
      final zeroEquityAccount = const Account(
        id: 'acc456',
        accountNumber: 'PA987654321',
        status: 'active',
        currency: 'USD',
        equity: 100000,
        cash: 50000,
        buyingPower: 100000,
        portfolioValue: 150000,
        lastEquity: 0,
      );
      expect(zeroEquityAccount.dailyPnLPercent, 0);
    });

    test('fromJson creates Account from JSON', () {
      final json = {
        'id': 'acc789',
        'account_number': 'PA111222333',
        'status': 'active',
        'currency': 'USD',
        'equity': '75000',
        'cash': '25000',
        'buying_power': '75000',
        'portfolio_value': '100000',
        'last_equity': '70000',
      };

      final accountFromJson = Account.fromJson(json);

      expect(accountFromJson.id, 'acc789');
      expect(accountFromJson.accountNumber, 'PA111222333');
      expect(accountFromJson.status, 'active');
      expect(accountFromJson.currency, 'USD');
      expect(accountFromJson.equity, 75000);
      expect(accountFromJson.cash, 25000);
      expect(accountFromJson.buyingPower, 75000);
      expect(accountFromJson.portfolioValue, 100000);
      expect(accountFromJson.lastEquity, 70000);
    });

    test('fromJson uses defaults for missing fields', () {
      final minimalJson = {'id': 'acc999'};
      final accountFromJson = Account.fromJson(minimalJson);

      expect(accountFromJson.id, 'acc999');
      expect(accountFromJson.accountNumber, '');
      expect(accountFromJson.status, '');
      expect(accountFromJson.currency, 'USD');
      expect(accountFromJson.equity, 0);
    });

    test('Account with positive P&L', () {
      final profitAccount = const Account(
        id: 'profit',
        accountNumber: 'PA111',
        status: 'active',
        currency: 'USD',
        equity: 110000,
        cash: 30000,
        buyingPower: 100000,
        portfolioValue: 140000,
        lastEquity: 100000,
      );

      expect(profitAccount.dailyPnL, 10000);
      expect(profitAccount.dailyPnLPercent, closeTo(10.0, 0.01));
    });

    test('Account with negative P&L', () {
      final lossAccount = const Account(
        id: 'loss',
        accountNumber: 'PA222',
        status: 'active',
        currency: 'USD',
        equity: 80000,
        cash: 30000,
        buyingPower: 70000,
        portfolioValue: 110000,
        lastEquity: 100000,
      );

      expect(lossAccount.dailyPnL, -20000);
      expect(lossAccount.dailyPnLPercent, closeTo(-20.0, 0.01));
    });
  });
}

