import type { CommittedChanges } from 'local-sync-backend';

interface Listener {
  readonly scope: string;
  readonly wake: () => void;
}

/**
 * A wake-up hint, never a payload. It fires only after a write commits, so a
 * subscriber that rereads durable state can never read uncommitted rows.
 */
export class InMemoryCommittedChanges implements CommittedChanges {
  private readonly listeners = new Set<Listener>();
  private closed = false;

  subscribe(scope: string, wake: () => void, signal: AbortSignal): void {
    if (this.closed) return;
    const listener: Listener = { scope, wake };
    this.listeners.add(listener);
    signal.addEventListener('abort', () => this.listeners.delete(listener), {
      once: true,
    });
  }

  /** Called by the transaction layer once a write has committed. */
  notify(scopes: Iterable<string>): void {
    if (this.closed) return;
    const touched = [...scopes];
    for (const listener of [...this.listeners]) {
      if (touched.includes(listener.scope)) {
        listener.wake();
      }
    }
  }

  /** A reconnected source wakes every live viewer exactly once. */
  reconnect(): void {
    for (const listener of [...this.listeners]) listener.wake();
  }

  get listenerCount(): number {
    return this.listeners.size;
  }

  async close(): Promise<void> {
    this.closed = true;
    this.listeners.clear();
  }
}
