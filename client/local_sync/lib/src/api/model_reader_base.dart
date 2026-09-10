import 'dart:async';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../projection/model_record.dart';
import '../projection/query_evaluator.dart';
import '../schema/model_id.dart';
import 'model_query.dart';
import 'model_reader.dart';
import 'transaction_model_reader.dart';

abstract base class ModelReaderBase<I extends ModelId>
    implements TransactionModelReader<I> {
  const ModelReaderBase({
    required this.evaluator,
    required this.readTransaction,
  });

  final QueryEvaluator<I> evaluator;
  final ReadTransaction readTransaction;

  @protected
  Future<ModelRecord<I>?> readIdentityInCurrentTransaction(I id);

  @protected
  Future<List<ModelRecord<I>>> readModelInCurrentTransaction();

  @protected
  Stream<void> invalidations();

  @override
  Future<ModelRecord<I>?> get(I id) =>
      readTransaction(() => getInCurrentTransaction(id));

  @override
  Future<ModelRecord<I>?> getInCurrentTransaction(I id) =>
      readIdentityInCurrentTransaction(id);

  @override
  Future<List<ModelRecord<I>>> query(ProjectionQuery<I> query) =>
      readTransaction(() => queryInCurrentTransaction(query));

  @override
  Future<List<ModelRecord<I>>> queryInCurrentTransaction(
    ProjectionQuery<I> query,
  ) async => evaluator.evaluate(await readModelInCurrentTransaction(), query);

  @override
  Stream<ModelRecord<I>?> watch(I id) =>
      _watch(() => get(id), DefaultEquality<ModelRecord<I>?>());

  @override
  Stream<List<ModelRecord<I>>> watchQuery(ProjectionQuery<I> query) =>
      _watch(() => this.query(query), ListEquality<ModelRecord<I>>());

  Stream<T> _watch<T>(Future<T> Function() read, Equality<T> equality) {
    late final StreamController<T> controller;
    StreamSubscription<void>? invalidationSubscription;
    var pending = Future<void>.value();
    var hasPrevious = false;
    T? previous;
    var cancelled = false;

    void reload() {
      pending = pending.then((_) async {
        if (cancelled) return;
        try {
          final next = await read();
          if (!cancelled &&
              (!hasPrevious || !equality.equals(previous as T, next))) {
            hasPrevious = true;
            previous = next;
            controller.add(next);
          }
        } catch (error, stackTrace) {
          if (!cancelled) controller.addError(error, stackTrace);
        }
      });
    }

    controller = StreamController<T>(
      onListen: () {
        invalidationSubscription = invalidations().listen(
          (_) => reload(),
          onError: controller.addError,
          onDone: () => pending.whenComplete(controller.close),
        );
        reload();
      },
      onPause: () => invalidationSubscription?.pause(),
      onResume: () => invalidationSubscription?.resume(),
      onCancel: () async {
        cancelled = true;
        await invalidationSubscription?.cancel();
      },
    );
    return controller.stream;
  }
}
