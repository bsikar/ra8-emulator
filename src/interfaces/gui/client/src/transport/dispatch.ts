/**
 * Event topic decoder and emitter dispatcher for incoming RPC event frames.
 */

import { decodeBuildEvent, decodeBuildStatus } from "../wire/build.js";
import { decodeTraceEvent } from "../wire/metrics.js";
import {
  decodeDirtyRect,
  decodeSessionEvent,
  decodeStopped,
  decodeTransportEvent,
  decodeUart,
} from "../wire/session.js";
import { Topic } from "../wire/types.js";
import { decodeWorkspaceChange } from "../wire/workspace.js";
import type { TypedEventEmitter } from "./emitter.js";

/** Decode an event frame payload by `topic` and emit it on `emitter`. */
export function dispatchTopicEvent(
  emitter: TypedEventEmitter,
  topic: Topic | number,
  payload: Uint8Array
): void {
  try {
    switch (topic) {
      case Topic.Stop:
        emitter.emit("stop", decodeStopped(payload));
        break;
      case Topic.Uart:
        emitter.emit("uart", decodeUart(payload));
        break;
      case Topic.LcdDirty:
        emitter.emit("lcd_dirty", decodeDirtyRect(payload));
        break;
      case Topic.Trace:
        emitter.emit("trace", decodeTraceEvent(payload));
        break;
      case Topic.Session:
        emitter.emit("session", decodeSessionEvent(payload));
        break;
      case Topic.Transport:
        emitter.emit("transport", decodeTransportEvent(payload));
        break;
      case Topic.WorkspaceChanged:
        emitter.emit("workspace_change", decodeWorkspaceChange(payload));
        break;
      case Topic.BuildEvent:
        emitter.emit("build_event", decodeBuildEvent(payload));
        break;
      case Topic.BuildCompleted:
        emitter.emit("build_completed", decodeBuildStatus(payload));
        break;
      default:
        break;
    }
  } catch (err) {
    console.error(`Error decoding event topic 0x${topic.toString(16)}:`, err);
  }
}
