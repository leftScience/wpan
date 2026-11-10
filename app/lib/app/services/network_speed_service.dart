import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

/// Samples the device's cumulative network byte counters once per second and
/// exposes the current download rate for the player overlay.
class NetworkSpeedService extends GetxService {
  static const MethodChannel _channel = MethodChannel('ohome/network_info');

  final RxDouble downloadBytesPerSecond = 0.0.obs;
  final RxDouble uploadBytesPerSecond = 0.0.obs;

  Timer? _timer;
  int _lastRx = 0;
  int _lastTx = 0;
  bool _sampled = false;

  NetworkSpeedService init() {
    return this;
  }

  void start() {
    if (_timer != null) return;
    _sampled = false;
    unawaited(_sample());
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_sample()),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _sampled = false;
    downloadBytesPerSecond.value = 0;
    uploadBytesPerSecond.value = 0;
  }

  Future<void> _sample() async {
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>(
        'getNetworkBytes',
      );
      if (data == null) return;
      final rx = _toInt(data['rx']);
      final tx = _toInt(data['tx']);
      if (rx == null || tx == null) return;

      if (_sampled) {
        downloadBytesPerSecond.value = _delta(_lastRx, rx).toDouble();
        uploadBytesPerSecond.value = _delta(_lastTx, tx).toDouble();
      }
      _lastRx = rx;
      _lastTx = tx;
      _sampled = true;
    } catch (_) {}
  }

  int _delta(int previous, int current) {
    if (current >= previous) return current - previous;
    // 32-bit interface counters wrap around.
    return current + (0x100000000 - previous);
  }

  int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static String formatRate(double bytesPerSecond) {
    if (bytesPerSecond <= 0) return '0 KB/s';
    const units = <String>['B/s', 'KB/s', 'MB/s', 'GB/s'];
    var value = bytesPerSecond;
    var index = 0;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index++;
    }
    final digits = value >= 100 || index == 0 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[index]}';
  }
}
