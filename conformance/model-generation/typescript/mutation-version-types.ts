import type {
  LocalSyncMutations,
  RenameSpaceV1Arguments,
  RenameSpaceV2Arguments,
} from '../../generated/backend/backend_contract';

// Compiled with conformance: an unused @ts-expect-error fails the build.
type RenameHandlers = LocalSyncMutations<object, 'renameSpace'>;
const resolve = async () => undefined;
const complete: RenameHandlers = { renameSpace: { v1: resolve, v2: resolve } };
// @ts-expect-error v1 remains mandatory after introducing v2.
const missing: RenameHandlers = { renameSpace: { v2: resolve } };
const extra: RenameHandlers = {
  // @ts-expect-error undeclared versions cannot be registered.
  renameSpace: { v1: resolve, v2: resolve, v3: resolve },
};
function oldInput(input: RenameSpaceV1Arguments): void {
  void input.space.patch.avatarKey;
  // @ts-expect-error the current Model's kind field is outside retained v1.
  void input.space.patch.kind;
}
function newInput(input: RenameSpaceV2Arguments): void {
  const kind: 'personal' | 'group' | undefined = input.space.patch.kind;
  void kind;
}
void [complete, missing, extra, oldInput, newInput];
