import 'dart:async';

Future<T> hedged<T>(
  Future<T> Function() attempt, {
  Duration after = const Duration(seconds: 2),
  int tries = 3,
  Duration limit = const Duration(seconds: 12),
  Duration retryDelay = const Duration(milliseconds: 300),
  bool Function(Object error)? fatal,
  void Function(T value)? discard,
  void Function(int number)? onExtra,
}) {
  final result = Completer<T>();
  Object? lastError;
  StackTrace? lastStack;
  var started = 0;
  var running = 0;
  Timer? next;
  Timer? deadline;

  void stop() {
    next?.cancel();
    deadline?.cancel();
  }

  void launch() {
    if (result.isCompleted || started >= tries) return;
    started++;
    running++;
    if (started > 1) onExtra?.call(started);
    next?.cancel();
    if (started < tries) next = Timer(after, launch);
    final Future<T> run = Future<T>.sync(attempt);
    unawaited(run.then<void>((T value) {
      running--;
      if (result.isCompleted) {
        if (discard != null) {
          try {
            discard(value);
          } catch (_) {}
        }
        return;
      }
      stop();
      result.complete(value);
    }, onError: (Object error, StackTrace stack) {
      running--;
      lastError = error;
      lastStack = stack;
      if (result.isCompleted) return;
      if (fatal != null && fatal(error)) {
        stop();
        result.completeError(error, stack);
        return;
      }
      if (started < tries) {
        next?.cancel();
        next = Timer(retryDelay, launch);
      } else if (running == 0) {
        stop();
        result.completeError(error, stack);
      }
    }));
  }

  deadline = Timer(limit, () {
    if (result.isCompleted) return;
    stop();
    result.completeError(
        lastError ?? TimeoutException('no answer in ${limit.inSeconds}s', limit), lastStack);
  });
  launch();
  return result.future;
}
