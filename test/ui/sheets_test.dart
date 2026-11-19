import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rain_reporter/domain/rain_cluster.dart';
import 'package:rain_reporter/domain/rain_intensity.dart';
import 'package:rain_reporter/domain/rain_report.dart';
import 'package:rain_reporter/ui/cluster_detail_bottom_sheet.dart';
import 'package:rain_reporter/ui/pin_detail_bottom_sheet.dart';
import 'package:rain_reporter/ui/report_bottom_sheet.dart';

void main() {
  testWidgets('ReportBottomSheet selects intensity and submits note', (tester) async {
    ReportSubmission? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportBottomSheet(
            onSubmit: (value) => submitted = value,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Heavy'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Visibility low');
    await tester.tap(find.text('Submit Report'));
    await tester.pump();

    expect(submitted, isNotNull);
    expect(submitted!.intensity, RainIntensity.heavy);
    expect(submitted!.note, 'Visibility low');
  });

  testWidgets('PinDetailBottomSheet displays report details and triggers vote callbacks', (tester) async {
    var confirmed = false;
    var stopped = false;
    final t0 = DateTime.utc(2026, 11, 13, 10, 0);
    final report = RainReport.create(
      id: 'r1',
      uid: 'u1',
      intensity: RainIntensity.storm,
      note: 'Thunder and heavy wind',
      lat: -6.2,
      lng: 106.8,
      createdAt: t0,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinDetailBottomSheet(
            report: report,
            now: t0.add(const Duration(minutes: 4)),
            onConfirmStillRaining: () => confirmed = true,
            onMarkStopped: () => stopped = true,
          ),
        ),
      ),
    );

    expect(find.textContaining('Storm'), findsOneWidget);
    expect(find.text('Thunder and heavy wind'), findsOneWidget);
    expect(find.textContaining('4m ago'), findsOneWidget);

    await tester.tap(find.text('Still raining'));
    expect(confirmed, isTrue);

    await tester.tap(find.text('Stopped here'));
    expect(stopped, isTrue);
  });

  testWidgets('ClusterDetailBottomSheet displays strongest intensity, report count, zone radius, notes, and fires vote callbacks for specific report', (tester) async {
    RainReport? confirmedReport;
    RainReport? stoppedReport;
    final t0 = DateTime.utc(2026, 11, 19, 10, 0);
    final newer = RainReport.create(
      id: 'r2',
      uid: 'u2',
      intensity: RainIntensity.storm,
      note: 'Heavy wind by station',
      lat: -6.2,
      lng: 106.8,
      createdAt: t0.add(const Duration(minutes: 3)),
    );
    final older = RainReport.create(
      id: 'r1',
      uid: 'u1',
      intensity: RainIntensity.heavy,
      note: 'Roads flooding',
      lat: -6.2,
      lng: 106.8,
      createdAt: t0,
    );
    final cluster = RainClusterer.cluster([older, newer]).single;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClusterDetailBottomSheet(
            cluster: cluster,
            now: t0.add(const Duration(minutes: 5)),
            onConfirmStillRaining: (r) => confirmedReport = r,
            onMarkStopped: (r) => stoppedReport = r,
          ),
        ),
      ),
    );

    expect(find.text('Storm Rain'), findsOneWidget);
    expect(find.text('2 reports'), findsOneWidget);
    expect(find.text('~424m zone'), findsOneWidget);
    expect(find.text('Heavy wind by station'), findsOneWidget);
    expect(find.text('Roads flooding'), findsOneWidget);

    await tester.tap(find.text('Still raining').first);
    expect(confirmedReport?.id, equals('r2'));

    await tester.tap(find.text('Stopped here').last);
    expect(stoppedReport?.id, equals('r1'));
  });

  testWidgets('ClusterDetailBottomSheet scrolls cleanly with 12 reports without overflow', (tester) async {
    final t0 = DateTime.utc(2026, 11, 19, 10, 0);
    final reports = List.generate(
      12,
      (i) => RainReport.create(
        id: 'r$i',
        uid: 'u$i',
        intensity: RainIntensity.moderate,
        note: 'Report note #$i',
        lat: -6.2,
        lng: 106.8,
        createdAt: t0.add(Duration(minutes: i)),
      ),
    );
    final cluster = RainClusterer.cluster(reports).single;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 500,
            child: ClusterDetailBottomSheet(
              cluster: cluster,
              now: t0.add(const Duration(minutes: 15)),
              onConfirmStillRaining: (_) {},
              onMarkStopped: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('12 reports'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
