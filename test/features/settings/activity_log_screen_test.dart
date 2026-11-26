// Settings → Help → Activity log on phones and computers (the TV has its
// own, test/tv/tv_activity_log_test.dart).
import 'package:cinemakom/app/app.dart';
import 'package:cinemakom/app/router.dart';
import 'package:cinemakom/core/diagnostics/event_log.dart';
import 'package:cinemakom/core/storage/preferences.dart';
import 'package:cinemakom/features/settings/activity_log_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/app_harness.dart';
import '../../helpers/fake_log_actions.dart';

Future<FakeLogActions> openLog(
  WidgetTester tester, {
  bool arabic = false,
  double width = 390,
}) async {
  final actions = FakeLogActions();
  await pumpApp(
    tester,
    logActions: actions,
    width: width,
    height: 900,
    store: MemoryPreferenceStore({
      PreferenceKeys.language: arabic ? 'ar' : 'en',
    }),
  );
  ProviderScope.containerOf(tester.element(find.byType(CinemakomApp)))
      .read(routerProvider)
      .go(AppRoutes.activityLog);
  await tester.pumpAndSettle();
  return actions;
}

void main() {
  testWidgets('Settings → Help has it', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Activity log'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activity log'));
    await tester.pumpAndSettle();
    expect(find.byType(ActivityLogScreen), findsOneWidget);
  });

  testWidgets('what it is, the newest entries first, problems marked', (
    tester,
  ) async {
    EventLog.instance
      ..record('player', 'phase loading → ready')
      ..record('error', 'Bad state: no frame\n#0 build');
    final actions = await openLog(tester);
    expect(find.textContaining('kept on this device'), findsOneWidget);
    final lines = tester
        .widgetList<LogEntryLine>(find.byType(LogEntryLine))
        .map((l) => l.entry.message)
        .toList();
    expect(
      lines.indexOf('Bad state: no frame\n#0 build'),
      lessThan(lines.indexOf('phase loading → ready')),
    );
    // Android: where the files are, for adb.
    expect(find.textContaining('adb pull ${actions.folder}'), findsOneWidget);
  });

  testWidgets('new entries show as they come', (tester) async {
    await openLog(tester);
    EventLog.instance.record('net', 'GET banner/level/0 failed');
    await tester.pumpAndSettle();
    expect(find.textContaining('GET banner/level/0 failed'), findsOneWidget);
  });

  testWidgets('Share hands both sessions to the share sheet', (tester) async {
    final actions = await openLog(tester);
    await tester.tap(find.text('Share the log'));
    await tester.pumpAndSettle();
    expect(actions.shared.single.$2, 'Activity log');
    expect(find.text('Save a copy'), findsNothing);
  });

  testWidgets('a log that can\'t be made ready says so', (tester) async {
    final actions = await openLog(tester);
    actions.failExport = true;
    await tester.tap(find.text('Share the log'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn\'t get the log ready'), findsOneWidget);
    expect(actions.shared, isEmpty);
  });

  testWidgets('Clear empties it', (tester) async {
    EventLog.instance.record('player', 'old');
    final actions = await openLog(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(actions.clears, 1);
    expect(find.text('The log is empty now'), findsOneWidget);
    expect(find.text('Nothing recorded yet'), findsOneWidget);
  });

  testWidgets('on a computer: Save a copy, then where it went', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final actions = await openLog(tester, width: 1000);
      expect(find.text('Share the log'), findsNothing);
      expect(find.textContaining('adb pull'), findsNothing);
      await tester.tap(find.text('Save a copy'));
      await tester.pumpAndSettle();
      expect(actions.saved, hasLength(1));
      expect(find.text('Saved: /home/me/cinemakom-log.txt'), findsOneWidget);

      // Cancelled: nothing said (once the first message has gone).
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved:'), findsNothing);
      actions.saveTo = null;
      await tester.tap(find.text('Save a copy'));
      await tester.pump();
      expect(find.textContaining('Saved:'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('in Arabic the page is right to left, the entries left to '
      'right', (tester) async {
    EventLog.instance.record('player', 'phase loading → ready');
    await openLog(tester, arabic: true);
    expect(find.text('سجل النشاط'), findsOneWidget);
    expect(find.text('مشاركة السجل'), findsOneWidget);
    final line = find.byType(LogEntryLine).first;
    final direction = tester.widget<Directionality>(
      find.descendant(of: line, matching: find.byType(Directionality)).first,
    );
    expect(direction.textDirection, TextDirection.ltr);
    expect(
      Directionality.of(tester.element(find.text('مشاركة السجل'))),
      TextDirection.rtl,
    );
  });
}
