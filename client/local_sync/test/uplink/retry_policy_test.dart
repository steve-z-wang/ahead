import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

void main() {
  test('uses full-jitter exponential caps from one through sixty seconds', () {
    final policy = RetryPolicy(randomDouble: () => 0.5);

    expect(policy.nextDelay(), const Duration(milliseconds: 500));
    expect(policy.nextDelay(), const Duration(seconds: 1));
    expect(policy.nextDelay(), const Duration(seconds: 2));
    for (var index = 0; index < 10; index += 1) {
      policy.nextDelay();
    }
    expect(policy.nextDelay(), const Duration(seconds: 30));
  });

  test('reset forgets attempts', () {
    final policy = RetryPolicy(randomDouble: () => 0.25);

    expect(policy.nextDelay(), const Duration(milliseconds: 250));
    expect(policy.nextDelay(), const Duration(milliseconds: 500));
    policy.reset();
    expect(policy.nextDelay(), const Duration(milliseconds: 250));
  });

  test('computes a delay for an invocation-owned attempt number', () {
    expect(
      RetryPolicy.delayForAttempt(attempt: 3, random: 0.5),
      const Duration(seconds: 2),
    );
  });
}
