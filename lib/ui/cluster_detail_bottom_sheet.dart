import 'package:flutter/material.dart';

import '../domain/rain_cluster.dart';
import '../domain/rain_report.dart';

class ClusterDetailBottomSheet extends StatelessWidget {
  const ClusterDetailBottomSheet({
    super.key,
    required this.cluster,
    required this.now,
    required this.onConfirmStillRaining,
    required this.onMarkStopped,
  });

  final RainCluster cluster;
  final DateTime now;
  final ValueChanged<RainReport> onConfirmStillRaining;
  final ValueChanged<RainReport> onMarkStopped;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.65;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${cluster.strongestIntensity.label} Rain',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '~${cluster.radiusMeters.round()}m zone',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  Chip(
                    label: Text('${cluster.reports.length} reports'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: cluster.reports.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final report = cluster.reports[index];
                    final minutesAgo =
                        now.difference(report.createdAt).inMinutes.clamp(0, 999);
                    return Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  report.intensity.label,
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                Text(
                                  '${minutesAgo}m ago',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                            if (report.note != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                report.note!,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                            const SizedBox(height: 6),
                            Text(
                              'Confirmed by ${report.confirmCount} user(s)',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.tonalIcon(
                                    onPressed: () =>
                                        onConfirmStillRaining(report),
                                    icon: const Icon(Icons.water_drop, size: 18),
                                    label: const Text('Still raining'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () => onMarkStopped(report),
                                    icon: const Icon(
                                      Icons.wb_sunny_outlined,
                                      size: 18,
                                    ),
                                    label: const Text('Stopped here'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
