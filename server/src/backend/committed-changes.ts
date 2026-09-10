export interface CommittedChanges {
  subscribe(scope: string, wake: () => void, signal: AbortSignal): void;
  close(): Promise<void>;
}
