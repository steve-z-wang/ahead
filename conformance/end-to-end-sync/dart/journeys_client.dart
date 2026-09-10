import 'package:local_sync_conformance/src/support/wire_scenario.dart';

import 'scenarios/apply.dart';
import 'scenarios/atomic_local_failure.dart';
import 'scenarios/mixed_act.dart';
import 'scenarios/multipage_apply.dart';
import 'scenarios/multi_scope_settlement.dart';
import 'scenarios/named_mutation.dart';
import 'scenarios/reconnect_catch_up.dart';
import 'scenarios/rejection_rebuild.dart';
import 'scenarios/scoped_streams.dart';
import 'scenarios/slot_binding.dart';
import 'scenarios/support.dart';
import 'scenarios/typed_lifecycle.dart';
import 'scenarios/uplink_scheduling.dart';
import 'scenarios/write_path.dart';

/// The end-to-end contract's half of the cross-language suite: one named
/// journey per run, each ending where the app would look — the client's own
/// local state, after real bytes crossed a real socket.
///
/// Argument dispatch and nothing else. What a journey does belongs to the
/// journey, so this file never grows a branch.

typedef Journey = Future<Map<String, Object?>> Function(WireSession session);

const _journeys = <String, Journey>{
  'apply': runApply,
  'typed-lifecycle': runTypedLifecycle,
  'rejection-rebuild': runRejectionRebuild,
  'scoped-streams': runScopedStreams,
  'scoped-runtime': runScopedRuntime,
  'multipage-apply': runMultipageApply,
  'multi-scope-settlement': runMultiScopeSettlement,
  'reconnect-catch-up': runReconnectCatchUp,
  'atomic-local-failure': runAtomicLocalFailure,
  'named-mutation': runNamedMutation,
  'mutation-version-restart': runMutationVersionRestart,
  'named-mutation-rejection': runNamedMutationRejection,
  'mixed-act': runMixedAct,
  'mixed-act-rejection': runMixedActRejection,
  'mixed-act-direct-lane': runMixedActDirectLane,
  'slot-binding-mismatch': runSlotBindingMismatch,
  'write-path': runWritePath,
  'uplink-scheduling': runUplinkScheduling,
};

Future<void> main(List<String> arguments) =>
    runWireScenario(arguments, _dispatch);

Future<Map<String, Object?>> _dispatch(
  WireSession session,
  String scenario,
) async {
  final journey = _journeys[scenario];
  if (journey == null) throw ArgumentError('unknown scenario "$scenario"');
  await initializeJourneyScopes(session.scope);
  return journey(session);
}
