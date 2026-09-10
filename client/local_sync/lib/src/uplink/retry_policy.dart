import 'dart:math';

final class RetryPolicy {
  RetryPolicy({required double Function() randomDouble})
    : _randomDouble = randomDouble;

  final double Function() _randomDouble;
  int _attempt = 0;

  /// Full-jitter exponential backoff, the one pacing there is: the wire
  /// carries no server-suggested delay to defer to.
  Duration nextDelay() {
    final random = _randomDouble();
    final attempt = _attempt + 1;
    _attempt = attempt;
    return delayForAttempt(attempt: attempt, random: random);
  }

  static Duration delayForAttempt({
    required int attempt,
    required double random,
  }) {
    if (attempt < 1) {
      throw ArgumentError.value(attempt, 'attempt');
    }
    if (!random.isFinite || random < 0 || random >= 1) {
      throw StateError('random must be in [0, 1)');
    }
    final capSeconds = min(pow(2, attempt - 1).toInt(), 60);
    final jitter = Duration(
      microseconds: (capSeconds * Duration.microsecondsPerSecond * random)
          .floor(),
    );
    return jitter;
  }

  void reset() => _attempt = 0;
}
