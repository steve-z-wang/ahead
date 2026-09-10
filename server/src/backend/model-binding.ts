import { BackendReadContext } from './context';

/// A Model's read half, and nothing else: writes are per ACT, resolved through
/// the mutation registry rather than per Model (CAP-439).
export interface BackendModelBinding<TTx, TIdentity, TState> {
  readonly read: {
    /**
     * Optional idempotent preparation for a viewer-relative value. The
     * materializer calls it immediately before [forViewer], with the same
     * transaction and identity order, so a first-write receipt can be read
     * into the page it belongs to.
     */
    prepareForViewer?(
      context: BackendReadContext<TTx>,
      identities: readonly TIdentity[],
    ): Promise<void>;
    forViewer(
      context: BackendReadContext<TTx>,
      identities: readonly TIdentity[],
    ): Promise<readonly (TState | null)[]>;
  };
}

export type AnyBackendModelBinding<TTx> = BackendModelBinding<
  TTx,
  never,
  unknown
>;

export type SyncScalarType =
  | 'string'
  | 'boolean'
  | 'int'
  | 'float'
  | 'dateTime'
  | 'uuid';

export type SyncFieldType =
  | Readonly<{ kind: 'scalar'; name: SyncScalarType }>
  | Readonly<{ kind: 'enum'; name: string }>
  | Readonly<{ kind: 'list'; element: SyncScalarType }>;

export interface SyncFieldDescriptor {
  readonly name: string;
  readonly nullable: boolean;
  readonly identity: boolean;
  readonly type: SyncFieldType;
  readonly prerequisite?: Readonly<{
    name: string;
    arguments: Readonly<Record<string, string>>;
  }>;
}

export interface GeneratedModelForwarders {
  readonly read: (...arguments_: never[]) => Promise<unknown>;
}

export interface SyncModelShape {
  readonly name: string;
  readonly identityFields: readonly string[];
  readonly knownFields?: readonly string[];
  readonly fields: readonly SyncFieldDescriptor[];
}

export interface SyncModelDescriptor<
  TIdentity extends object = object,
> extends SyncModelShape {
  readonly forward: GeneratedModelForwarders;
  readonly identityType?: TIdentity;
}

/// The whole of what generation tells the pipe: which Models exist, what
/// their fields are, and how to reach the product's binding for each. Nothing
/// about the wire — the wire is handwritten and fixed.
export interface GeneratedBackendContract {
  readonly enumValues: Readonly<Record<string, readonly string[]>>;
  readonly models: Readonly<Record<string, SyncModelDescriptor>>;
}

export type MutationOperationKind = 'create' | 'update' | 'delete';

export type MutationSlotCardinality = 'single' | 'optional' | 'list';

/// One `(Model, op)` pair, fixed at declaration. The executor reads the pair
/// off the slot rather than off the wire, so a payload can never claim an
/// operation the schema did not declare.
export interface MutationSlotDescriptor {
  readonly name: string;
  readonly model: string;
  readonly operation: MutationOperationKind;
  readonly cardinality: MutationSlotCardinality;
  /// The complete known-field capability of an update slot. Absent for
  /// create and delete, whose input shapes are already closed.
  readonly allowedPatchFields?: readonly string[];
  /// The act-level wiring the slot declares (spec 2026-08-16-slot-bindings),
  /// absent when it declares none. Names only — the precheck that consumes
  /// them is handwritten (slot-binding-precheck.ts).
  readonly bindings?: readonly SlotBindingDescriptor[];
}

/// One `relation: slot` pair: this slot's rows' [fields] (in the bound
/// Model's identity order) must equal the identity of the row in [slot].
export interface SlotBindingDescriptor {
  readonly relation: string;
  readonly fields: readonly string[];
  readonly slot: string;
}

export interface MutationDescriptor {
  readonly name: string;
  readonly version: number;
  readonly input: MutationInputContract;
  /// Declaration order, which is execution order.
  readonly slots: readonly MutationSlotDescriptor[];
  readonly forward: (...arguments_: never[]) => Promise<unknown>;
}

/// The named write vocabulary, as generation states it (CAP-439). Names only:
/// how a mutation is decoded, dispatched and rolled back is handwritten.
export interface GeneratedMutationContract {
  readonly mutations: Readonly<
    Record<string, Readonly<Record<string, MutationDescriptor>>>
  >;
}

/** Historical inputs describe values, not current storage or Downlink readers. */
export interface MutationInputContract {
  readonly enumValues: Readonly<Record<string, readonly string[]>>;
  readonly models: Readonly<Record<string, SyncModelShape>>;
}
