/** Internal zero-argument change notifications, shared by Node and mobile. */
export class Events {
  #listeners = new Map<string, Set<() => void>>();
  on(name: string, listener: () => void): void {
    let listeners = this.#listeners.get(name);
    if (!listeners) this.#listeners.set(name, (listeners = new Set()));
    listeners.add(listener);
  }
  off(name: string, listener: () => void): void {
    this.#listeners.get(name)?.delete(listener);
  }
  emit(name: string): void {
    for (const listener of [...(this.#listeners.get(name) ?? [])]) listener();
  }
  removeAllListeners(): void {
    this.#listeners.clear();
  }
}
