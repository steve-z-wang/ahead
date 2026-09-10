import 'dart:convert';
import 'dart:io';

import 'package:local_sync/local_sync.dart';
import 'package:local_sync_conformance/local_sync_conformance.dart';

/// The generated Dart mutation surface's own account of every synced act,
/// printed as JSON so the shared matrix can compare it with the generated
/// Backend descriptors
/// (`model-generation/typescript/shared-mutation-contract.spec.ts`).
///
/// It is read by building each act's exact returned record and asking the
/// generated `MutationRecords` what that spells — the same fact `mutate` sends
/// — rather than from a parallel manifest. A slot the compiler declared but
/// spelled differently on one side would not survive that: the record would
/// not compile with these field names, and the flattened order would not
/// match.
///
///     dart run model-generation/dart/mutation_manifest.dart
void main() {
  final moment = Moment(
    id: MomentId(_momentId),
    spaceId: _spaceId,
    capturedAt: DateTime.utc(2026, 8, 12),
    caption: null,
  );
  final star = Star(
    id: StarId(userId: _userId, momentId: _momentId),
    userId: _userId,
    momentId: _momentId,
  );
  final tag = StarTag(
    id: StarTagId(_tagId),
    userId: _userId,
    momentId: _momentId,
    label: 'ready-key',
  );
  final space = Space(
    id: SpaceId(_spaceId),
    ownerId: _userId,
    name: 'Everyday',
    kind: SpaceKind.personal,
    avatarKey: null,
  );
  final sample = ScalarSample(
    id: ScalarSampleId(_sampleId),
    enabled: true,
    rank: 7,
    score: 1.5,
    optionalAt: null,
    optionalUuid: null,
  );

  // One operation per declared slot: a list slot carries exactly one element
  // and an optional slot is present, so the flattened order is the slot order
  // and the two sides are comparable slot for slot.
  final mutations = <MutationRecord>[
    mutationRecords.captureMoment((
      moment: Moment.create(
        id: _momentId,
        spaceId: _spaceId,
        capturedAt: DateTime.utc(2026, 8, 12),
        caption: null,
      ),
      tags: [
        StarTag.create(
          id: _tagId,
          userId: _userId,
          momentId: _momentId,
          label: 'ready-key',
        ),
      ],
      star: Star.create(userId: _userId, momentId: _momentId),
    )),
    mutationRecords.reviseMoment((
      moment: const ReviseMomentMomentSlot().update(
        moment,
        caption: const FieldUpdate.set('revised'),
      ),
      removedTags: [tag.delete()],
      addedTags: [
        StarTag.create(
          id: _tagId,
          userId: _userId,
          momentId: _momentId,
          label: 'ready-key',
        ),
      ],
      star: star.delete(),
    )),
    mutationRecords.renameSpace((
      space: const RenameSpaceSpaceSlot().update(space, name: 'Renamed'),
    )),
    mutationRecords.deleteSpace((space: space.delete())),
    mutationRecords.registerUser((
      user: User.create(id: _userId, handle: 'steve'),
    )),
    mutationRecords.createSpace((
      space: Space.create(
        id: _spaceId,
        ownerId: _userId,
        name: 'Everyday',
        kind: SpaceKind.personal,
        avatarKey: null,
      ),
    )),
    mutationRecords.saveAccountState((
      accountState: AccountState.create(
        userId: _userId,
        spaceOrder: [_spaceId],
        inboxSeenAt: null,
      ),
    )),
    mutationRecords.writeMoment((
      moment: Moment.create(
        id: _momentId,
        spaceId: _spaceId,
        capturedAt: DateTime.utc(2026, 8, 12),
        caption: null,
      ),
    )),
    mutationRecords.discardMoment((moment: moment.delete())),
    mutationRecords.recordSample((
      sample: ScalarSample.create(
        id: _sampleId,
        enabled: true,
        rank: 7,
        score: 1.5,
        optionalAt: null,
        optionalUuid: null,
      ),
    )),
    mutationRecords.reviseSample((
      sample: const ReviseSampleSampleSlot().update(sample, rank: 8),
    )),
    mutationRecords.keepMoment((
      star: Star.create(userId: _userId, momentId: _momentId),
    )),
    mutationRecords.unstar((star: star.delete())),
    mutationRecords.publishNote((
      note: LocalNote.create(
        id: _noteId,
        text: 'shared',
        status: LocalNoteStatus.active,
      ),
    )),
    // The companion acts: what the act SENDS is its declared slot alone, and
    // the device-only note it writes inside its callback appears nowhere here
    // — which is exactly the point (CAP-488).
    mutationRecords.captionWithNote((
      moment: const CaptionWithNoteMomentSlot().update(
        moment,
        caption: FieldUpdate.set('captioned'),
      ),
    )),
    mutationRecords.recaptionWithNote((
      moment: const RecaptionWithNoteMomentSlot().update(
        moment,
        caption: FieldUpdate.set('recaptioned'),
      ),
    )),
  ];

  stdout.writeln(
    jsonEncode({
      'mutations': [for (final mutation in mutations) _record(mutation)]
        ..sort(
          (left, right) =>
              (left['name']! as String).compareTo(right['name']! as String),
        ),
    }),
  );
}

Map<String, Object?> _record(MutationRecord record) => {
  'name': record.name,
  'version': record.version,
  'operations': [
    for (final operation in record.operations)
      {'model': operation.model, 'operation': _operation(operation)},
  ],
  // The act's declared wiring, by operation index (spec
  // 2026-08-16-slot-bindings). Each act above carries one row per slot, so
  // operation index N IS slot index N and the shared spec can hold this half
  // against the Backend descriptors' per-slot bindings.
  'bindings': [
    for (final binding in record.bindings)
      {
        'operation': record.operations.indexOf(binding.operation),
        'fields': binding.fields,
        'parent': record.operations.indexOf(binding.parent),
      },
  ],
  // The update capability is generated onto each returned slot operation,
  // so this is the exact projection the client runtime enforces.
  'updateProjections': [
    for (final slot in record.slotOperations)
      if (slot.allowedPatchFields != null)
        {
          'operation': record.slotOperations.indexOf(slot),
          'fields': slot.allowedPatchFields!.toList(),
        },
  ],
};

String _operation(ModelOperation operation) => switch (operation) {
  ModelCreateOperation() => 'create',
  ModelUpdateOperation() => 'update',
  ModelDeleteOperation() => 'delete',
};

final _momentId = _uuid(1);
final _spaceId = _uuid(2);
final _userId = _uuid(3);
final _tagId = _uuid(4);
final _sampleId = _uuid(5);
final _noteId = _uuid(6);

UUID _uuid(int value) => UUID.withValidation(
  '550e8400-e29b-41d4-a716-${value.toString().padLeft(12, '0')}',
);
