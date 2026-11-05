import 'package:bitdrop/app.dart';
import 'package:bitdrop/features/home/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('boots to Home with the mock core', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: BitDropApp()));
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('BitDrop'), findsWidgets);
    final navBars = find.byType(NavigationBar);
    expect(navBars, findsOneWidget);
    expect(tester.getSize(navBars.first).width, greaterThan(0.0));
    expect(tester.getSize(navBars.first).height, greaterThan(0.0));

    final home = find.byType(HomeScreen);
    expect(home, findsOneWidget);
    expect(tester.getSize(home.first).width, greaterThan(0.0));
    expect(tester.getSize(home.first).height, greaterThan(0.0));

    // Disposing the scope cancels the mock core's tickers so no timer leaks
    // into the next test.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 60));
  });
}
