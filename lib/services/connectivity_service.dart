import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Whether the phone has a network connection. Offline, the app only plays downloads.
class ConnectivityService {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  final ValueNotifier<bool> online = ValueNotifier<bool>(true);
  StreamSubscription<List<ConnectivityResult>>? _sub;

  Future<void> init() async {
    try {
      online.value = _isOnline(await Connectivity().checkConnectivity());
    } catch (e) {
      debugPrint('connectivity check failed: $e');
    }
    _sub ??= Connectivity().onConnectivityChanged.listen(
      (r) => online.value = _isOnline(r),
      onError: (Object e) => debugPrint('connectivity stream error: $e'),
    );
  }

  static bool _isOnline(List<ConnectivityResult> r) =>
      r.any((e) => e != ConnectivityResult.none);
}
