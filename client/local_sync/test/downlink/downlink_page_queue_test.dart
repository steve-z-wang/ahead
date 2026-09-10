import 'package:local_sync/local_sync.dart';
import 'package:test/test.dart';

const _scope = 'User:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

void main() {
  test('retains a multi-change page as one queue entry', () {
    final queue = DownlinkPageQueue();
    final value = page(100, 120, changeCount: 20);

    expect(queue.add(value), isTrue);

    expect(queue.length, 1);
    expect(queue.first, same(value));
  });

  test('orders complete pages by their cursor boundaries', () {
    final queue = DownlinkPageQueue();
    final later = page(120, 130);
    final earlier = page(100, 110);

    queue
      ..add(later)
      ..add(earlier);

    expect(queue.removeFirst(), same(earlier));
    expect(queue.removeFirst(), same(later));
    expect(queue.isEmpty, isTrue);
  });

  test('replaces a page with the same boundaries', () {
    final queue = DownlinkPageQueue();
    final first = page(100, 120);
    final replacement = page(100, 120, changeCount: 1);

    expect(queue.add(first), isTrue);
    expect(queue.add(replacement), isTrue);

    expect(queue.length, 1);
    expect(queue.first, same(replacement));
  });

  test('the 65th retained page reports overflow and clears the queue', () {
    final queue = DownlinkPageQueue();
    for (var index = 0; index < 64; index += 1) {
      expect(queue.add(page(index, index + 1)), isTrue);
    }

    expect(queue.add(page(64, 65)), isFalse);

    expect(queue.isEmpty, isTrue);
  });
}

DownlinkPage page(int fromSyncId, int throughSyncId, {int changeCount = 0}) {
  return DownlinkPage(
    scope: _scope,
    fromSyncId: fromSyncId,
    throughSyncId: throughSyncId,
    changes: [
      for (var index = 1; index <= changeCount; index += 1)
        AddressedModelChange(
          syncId: fromSyncId + index,
          raw: {'syncId': fromSyncId + index},
        ),
    ],
  );
}
