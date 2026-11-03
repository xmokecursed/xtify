import 'dart:async';

/// Runs [attempt] and, while it has not answered after [after], runs it once more alongside
/// it (up to [tries] runs in all). The first answer wins.
///
/// For a request that can be repeated without harm and whose connection may simply go nowhere:
/// a lost packet, or a connection the phone's network dropped without telling anybody. Asking
/// again on a new connection after two seconds is much quicker than waiting ten for the first
/// one to give up (which is what a stuck link check and a stuck first piece of a song did).
///
/// An attempt that fails does not wait for the timer either: the next one starts after
/// [retryDelay], unless [fatal] says that error is the final answer (an answer from the server
/// is not made better by asking again). The result is the last error once every attempt has
/// failed, or a [TimeoutException] when [limit] passes first.
///
/// An answer that arrives after another one has won goes to [discard], so that what it holds
/// (a connection, say) can be let go. [onExtra] is told when an extra attempt starts (2, 3, ...).
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
    // if this one is slow, the following one starts after [after]
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
        // this one failed: the next one need not wait for the timer
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
