import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../domain/rain_intensity.dart';

class MapboxMarkerIcons {
  final Map<String, Uint8List> _cache = {};

  Future<Uint8List> getPinIcon(RainIntensity intensity, Color color) async {
    final key = 'pin:${intensity.wireName}:${color.toARGB32()}';
    final cached = _cache[key];
    if (cached != null) return cached;

    const size = 88.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Subtle ground shadow
    canvas.drawOval(
      const Rect.fromLTWH(26, 74, 36, 10),
      Paint()..color = Colors.black26,
    );

    // Teardrop pin path
    final path = Path()
      ..moveTo(size / 2, 78)
      ..quadraticBezierTo(16, 50, 16, 34)
      ..arcToPoint(
        const Offset(72, 34),
        radius: const Radius.circular(28),
        clockwise: true,
      )
      ..quadraticBezierTo(72, 50, size / 2, 78)
      ..close();

    canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5,
    );

    // White inner dot
    canvas.drawCircle(
      const Offset(size / 2, 34),
      10,
      Paint()..color = Colors.white,
    );

    final bytes = await _toPngBytes(recorder, size.toInt(), size.toInt());
    _cache[key] = bytes;
    return bytes;
  }

  Future<Uint8List> getClusterBadgeIcon(
    RainIntensity intensity,
    Color color,
    int count,
  ) async {
    final key = 'cluster:${intensity.wireName}:${color.toARGB32()}:$count';
    final cached = _cache[key];
    if (cached != null) return cached;

    const size = 88.0;
    const center = Offset(size / 2, size / 2);
    const radius = 36.0;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Shadow
    canvas.drawCircle(
      center + const Offset(0, 3),
      radius,
      Paint()..color = Colors.black26,
    );

    // Colored fill
    canvas.drawCircle(center, radius, Paint()..color = color);

    // White border
    canvas.drawCircle(
      center,
      radius - 2,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );

    // Count label
    final label = count > 99 ? '99+' : '$count';
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: label.length > 2 ? 24 : 30,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();

    painter.paint(
      canvas,
      Offset(
        center.dx - painter.width / 2,
        center.dy - painter.height / 2,
      ),
    );

    final bytes = await _toPngBytes(recorder, size.toInt(), size.toInt());
    _cache[key] = bytes;
    return bytes;
  }

  Future<Uint8List> _toPngBytes(
    ui.PictureRecorder recorder,
    int width,
    int height,
  ) async {
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return byteData!.buffer.asUint8List();
  }
}
