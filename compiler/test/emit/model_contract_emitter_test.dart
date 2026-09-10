import 'dart:convert';

import 'package:local_sync_compiler/local_sync_compiler.dart';
import 'package:test/test.dart';

void main() {
  final graph = compileModelSources({
    'account.model': '''enum SpaceKind {
  personal
  group
}

model AccountState {
  userId UUID
  spaceOrder UUID[]
  kind SpaceKind
  @@id(userId)
}''',
    'user.model': '''model User {
  id UUID
  handle String
  nickname String?
  @@id(id)
  @@unique(handle)
}''',
    'star.model': '''model Star {
  userId UUID
  momentId UUID
  createdAt DateTime
  user User @reference(via: [userId], onTargetDelete: delete)
  @@id(userId, momentId)
}''',
    'scalar_sample.model': '''model ScalarSample {
  id UUID
  text String
  enabled Boolean
  count Int
  ratio Float
  occurredAt DateTime
  @@id(id)
}''',
    'draft.model': '''enum DraftState {
  editing
  saved
}

model Draft {
  id UUID
  state DraftState
  @@id(id)
}''',
  });

  test('emits the deterministic Backend Model contract projection', () {
    final output = emitModelContract(graph);

    expect(output, endsWith('\n'));
    expect(output, contains('\n  "enums": [\n'));
    expect(emitModelContract(graph), output);
    expect(jsonDecode(output), {
      // Every Model and every enum reachable from one: the compiler no
      // longer owns replication policy, so nothing is filtered here
      // (CAP-488).
      'enums': [
        {
          'name': 'DraftState',
          'values': ['editing', 'saved'],
        },
        {
          'name': 'SpaceKind',
          'values': ['personal', 'group'],
        },
      ],
      'models': [
        {
          'name': 'AccountState',
          'identity': ['userId'],
          'fields': [
            {
              'name': 'userId',
              'type': {'kind': 'scalar', 'name': 'uuid'},
              'nullable': false,
            },
            {
              'name': 'spaceOrder',
              'type': {
                'kind': 'list',
                'element': {'kind': 'scalar', 'name': 'uuid'},
              },
              'nullable': false,
            },
            {
              'name': 'kind',
              'type': {'kind': 'enum', 'name': 'SpaceKind'},
              'nullable': false,
            },
          ],
        },
        {
          'name': 'Draft',
          'identity': ['id'],
          'fields': [
            {
              'name': 'id',
              'type': {'kind': 'scalar', 'name': 'uuid'},
              'nullable': false,
            },
            {
              'name': 'state',
              'type': {'kind': 'enum', 'name': 'DraftState'},
              'nullable': false,
            },
          ],
        },
        {
          'name': 'ScalarSample',
          'identity': ['id'],
          'fields': [
            {
              'name': 'id',
              'type': {'kind': 'scalar', 'name': 'uuid'},
              'nullable': false,
            },
            {
              'name': 'text',
              'type': {'kind': 'scalar', 'name': 'string'},
              'nullable': false,
            },
            {
              'name': 'enabled',
              'type': {'kind': 'scalar', 'name': 'boolean'},
              'nullable': false,
            },
            {
              'name': 'count',
              'type': {'kind': 'scalar', 'name': 'int'},
              'nullable': false,
            },
            {
              'name': 'ratio',
              'type': {'kind': 'scalar', 'name': 'float'},
              'nullable': false,
            },
            {
              'name': 'occurredAt',
              'type': {'kind': 'scalar', 'name': 'dateTime'},
              'nullable': false,
            },
          ],
        },
        {
          'name': 'Star',
          'identity': ['userId', 'momentId'],
          'fields': [
            {
              'name': 'userId',
              'type': {'kind': 'scalar', 'name': 'uuid'},
              'nullable': false,
            },
            {
              'name': 'momentId',
              'type': {'kind': 'scalar', 'name': 'uuid'},
              'nullable': false,
            },
            {
              'name': 'createdAt',
              'type': {'kind': 'scalar', 'name': 'dateTime'},
              'nullable': false,
            },
          ],
        },
        {
          'name': 'User',
          'identity': ['id'],
          'fields': [
            {
              'name': 'id',
              'type': {'kind': 'scalar', 'name': 'uuid'},
              'nullable': false,
            },
            {
              'name': 'handle',
              'type': {'kind': 'scalar', 'name': 'string'},
              'nullable': false,
            },
            {
              'name': 'nickname',
              'type': {'kind': 'scalar', 'name': 'string'},
              'nullable': true,
            },
          ],
        },
      ],
    });
  });
}
