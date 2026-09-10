import 'downlink_protocol.dart';

final class DownlinkPageQueue {
  DownlinkPageQueue({this.capacity = 64}) {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be positive');
    }
  }

  final int capacity;
  final List<DownlinkPage> _pages = [];

  int get length => _pages.length;
  bool get isEmpty => _pages.isEmpty;
  DownlinkPage? get first => _pages.firstOrNull;

  bool add(DownlinkPage page) {
    final matching = _pages.indexWhere(
      (candidate) =>
          candidate.fromSyncId == page.fromSyncId &&
          candidate.throughSyncId == page.throughSyncId,
    );
    if (matching >= 0) {
      _pages[matching] = page;
      return true;
    }
    if (_pages.length == capacity) {
      _pages.clear();
      return false;
    }
    _pages.add(page);
    _pages.sort(_compare);
    return true;
  }

  DownlinkPage removeFirst() => _pages.removeAt(0);

  void clear() => _pages.clear();
}

int _compare(DownlinkPage left, DownlinkPage right) {
  final from = left.fromSyncId.compareTo(right.fromSyncId);
  return from != 0 ? from : left.throughSyncId.compareTo(right.throughSyncId);
}
