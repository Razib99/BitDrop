import 'package:bitdrop/core_api/models.dart';
import 'package:bitdrop/l10n/app_localizations.dart';
import 'package:bitdrop/theme/app_theme.dart';
import 'package:bitdrop/widgets/indicators.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildWrapper(Widget child) {
  return MaterialApp(
    theme: AppTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(child: child),
    ),
  );
}

void main() {
  testWidgets('renders Buffering state with animated waveform', (tester) async {
    const state = BufferingState(
      bufferedMs: 3600,
      targetMs: 10000,
      attempt: 1,
    );

    await tester.pumpWidget(_buildWrapper(const BufferingIndicator(state: state)));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('BUFFERING'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off_rounded), findsNothing);
  });

  testWidgets('renders Slow Connection state on attempt >= 2', (tester) async {
    const state = BufferingState(
      bufferedMs: 1800,
      targetMs: 10000,
      attempt: 2,
    );

    await tester.pumpWidget(_buildWrapper(const BufferingIndicator(state: state)));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('SLOW CONNECTION'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off_rounded), findsNothing);
  });

  testWidgets('renders Loading state', (tester) async {
    await tester.pumpWidget(_buildWrapper(const BufferingIndicator(isLoading: true)));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('LOADING'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off_rounded), findsNothing);
  });

  testWidgets('renders Offline No Connection state with wifi_off icon and coral error styling', (tester) async {
    await tester.pumpWidget(_buildWrapper(const BufferingIndicator(isOffline: true)));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('NO CONNECTION'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);
  });
}
