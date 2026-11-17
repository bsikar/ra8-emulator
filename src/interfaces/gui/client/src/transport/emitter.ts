/**
 * Lightweight, zero-dependency typed event emitter for RPC client events.
 */

import type { BuildEvent, BuildStatus } from "../wire/build.js";
import type {
  DirtyRect,
  SessionEvent,
  Stopped,
  TransportEvent,
  UartEvent,
} from "../wire/session.js";
import type { TraceEvent } from "../wire/metrics.js";
import type { Hello, RpcEventEnvelope } from "../wire/types.js";
import type { WorkspaceChange } from "../wire/workspace.js";

export type EventListener<T> = (data: T) => void;

/** Typed event payloads emitted by `RA8RpcClient`. */
export interface ClientEventMap {
  open: void;
  close: { code: number; reason: string };
  error: Error;
  hello: Hello;
  event: RpcEventEnvelope;
  stop: Stopped;
  uart: UartEvent;
  lcd_dirty: DirtyRect;
  trace: TraceEvent;
  session: SessionEvent;
  transport: TransportEvent;
  workspace_change: WorkspaceChange;
  build_event: BuildEvent;
  build_completed: BuildStatus;
}

type ListenerSetMap = {
  [K in keyof ClientEventMap]?: Set<EventListener<ClientEventMap[K]>>;
};

/** Typed pub/sub emitter isolating listener failures from sibling subscribers. */
export class TypedEventEmitter {
  private readonly listeners: ListenerSetMap = {};

  public on<K extends keyof ClientEventMap>(
    event: K,
    listener: EventListener<ClientEventMap[K]>
  ): this {
    let set = this.listeners[event] as Set<EventListener<ClientEventMap[K]>> | undefined;
    if (!set) {
      set = new Set<EventListener<ClientEventMap[K]>>();
      (this.listeners as Record<keyof ClientEventMap, unknown>)[event] = set;
    }
    set.add(listener);
    return this;
  }

  public once<K extends keyof ClientEventMap>(
    event: K,
    listener: EventListener<ClientEventMap[K]>
  ): this {
    const wrapper: EventListener<ClientEventMap[K]> = (data) => {
      this.off(event, wrapper);
      listener(data);
    };
    return this.on(event, wrapper);
  }

  public off<K extends keyof ClientEventMap>(
    event: K,
    listener: EventListener<ClientEventMap[K]>
  ): this {
    const set = this.listeners[event] as Set<EventListener<ClientEventMap[K]>> | undefined;
    if (set) {
      set.delete(listener);
      if (set.size === 0) {
        delete this.listeners[event];
      }
    }
    return this;
  }

  public emit<K extends keyof ClientEventMap>(event: K, data: ClientEventMap[K]): boolean {
    const set = this.listeners[event] as Set<EventListener<ClientEventMap[K]>> | undefined;
    if (!set || set.size === 0) return false;
    for (const listener of Array.from(set)) {
      try {
        listener(data);
      } catch (err) {
        console.error(`Error in event listener for ${String(event)}:`, err);
      }
    }
    return true;
  }

  public removeAllListeners(event?: keyof ClientEventMap): this {
    if (event) {
      delete this.listeners[event];
      return this;
    }
    for (const key of Object.keys(this.listeners) as Array<keyof ClientEventMap>) {
      delete this.listeners[key];
    }
    return this;
  }
}
