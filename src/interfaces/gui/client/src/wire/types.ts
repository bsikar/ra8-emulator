/**
 * Core RA8 WebSocket RPC wire protocol constants, enums, and envelope types
 * matching `src/interfaces/rpc/session/rpc.zig`, `method.zig`, and backend wire files.
 */

export const PROTOCOL_MAGIC = 0x52384152; // 'RA8R' little-endian
export const PROTOCOL_VERSION = 1;
export const MAX_PAYLOAD = 1_048_576; // 1 MiB
export const HEADER_BYTES = 6;
export const METRICS_REPORT_BYTES = 32;

export const CAP_TRANSPORT = 1 << 15;
export const CAP_WORKSPACE = 1 << 16;
export const CAP_BUILD = 1 << 17;
export const CAP_PROJECT = 1 << 18;
export const CAP_RECOVERY = 1 << 19;
export const CAP_ARTIFACTS = 1 << 20;
export const CAP_TARGETS = 1 << 21;

export const DEFAULT_CLIENT_CAPS =
  0x0000_7fff |
  CAP_TRANSPORT |
  CAP_WORKSPACE |
  CAP_BUILD |
  CAP_PROJECT |
  CAP_RECOVERY |
  CAP_ARTIFACTS |
  CAP_TARGETS;

/** Wire message kinds (`Kind` in `ra8_rpc/envelope.zig`). */
export enum Kind {
  Hello = 1,
  Request = 2,
  Response = 3,
  Event = 4,
  Fault = 5,
}

/** Result tag in response envelope. */
export enum ResultTag {
  Ok = 0,
  Err = 1,
}

/** Error codes across envelope, session, workspace, build, project, artifacts, targets. */
export enum ErrorCode {
  UnknownMethod = 1,
  BadArgs = 2,
  Failed = 3,
  VersionMismatch = 4,
  BadMagic = 5,
  NotReady = 6,
  FirstApp = 0x0100,
  AppRefused = 0x0100,
  AppNoCore = 0x0101,
  AppTooLong = 0x0102,
  AppHistory = 0x0103,
  WorkspaceUnavailable = 0x0150,
  WorkspaceInvalidPath = 0x0151,
  WorkspaceConflict = 0x0152,
  WorkspaceTooLarge = 0x0153,
  WorkspaceNotFound = 0x0154,
  WorkspaceInvalidWatch = 0x0155,
  WorkspaceIo = 0x0156,
  WorkspaceNotFile = 0x0157,
  BuildUnavailable = 0x0160,
  BuildBusy = 0x0161,
  BuildUnknownJob = 0x0162,
  BuildIo = 0x0163,
  ProjectUnavailable = 0x0170,
  ProjectState = 0x0171,
  ProjectInvalid = 0x0172,
  ProjectFailed = 0x0173,
  ProjectChanged = 0x0174,
  ArtifactsUnavailable = 0x0180,
  ArtifactsState = 0x0181,
  ArtifactsInvalid = 0x0182,
  ArtifactsTooLarge = 0x0183,
  ArtifactsIo = 0x0184,
  TargetsUnavailable = 0x0190,
  TargetsStale = 0x0191,
  TargetsAmbiguous = 0x0192,
  TargetsBusy = 0x0193,
  TargetsOwnership = 0x0194,
  TargetsUnsupported = 0x0195,
  TargetsCustodian = 0x0196,
  TargetsFailed = 0x0197,
}

/** Session (`0x0100..0x013F`) and backend (`0x0140..0x0193`) RPC opcodes. */
export enum Method {
  Load = 0x0100,
  Run = 0x0101,
  Pause = 0x0102,
  Step = 0x0103,
  SetSpeed = 0x0104,
  ReadRegister = 0x0105,
  WriteRegister = 0x0106,
  ReadMemory = 0x0107,
  WriteMemory = 0x0108,
  SetBreakpoint = 0x0109,
  ClearBreakpoint = 0x010a,
  SetWatchpoint = 0x010b,
  ClearWatchpoint = 0x010c,
  Subscribe = 0x010d,
  Unsubscribe = 0x010e,
  Now = 0x010f,
  Interrupt = 0x0110,
  SetRunBudget = 0x0111,
  RemovePoint = 0x0112,
  Plug = 0x0113,
  Unplug = 0x0114,
  SetFault = 0x0115,
  ClearFault = 0x0116,
  Advance = 0x0117,
  Snapshot = 0x0118,
  Restore = 0x0119,
  ListParts = 0x011a,
  SetCameraSource = 0x011b,
  Map = 0x011c,
  Stack = 0x011d,
  Rtc = 0x011e,
  Input = 0x011f,
  Backtrace = 0x0120,
  Periph = 0x0121,
  Folded = 0x0122,
  SetBreakpointName = 0x0123,
  LoadBegin = 0x0124,
  LoadChunk = 0x0125,
  LoadEnd = 0x0126,
  BoardParts = 0x0127,
  SourceLine = 0x0128,
  Locals = 0x0129,
  LocalsAt = 0x012a,
  AdvanceAsync = 0x012b,
  Seek = 0x012c,
  Rcont = 0x012d,
  Metrics = 0x012e,
  Disasm = 0x012f,
  BranchList = 0x0130,
  BranchSwitch = 0x0131,
  BranchDelete = 0x0132,
  BranchConfirmFork = 0x0133,
  BranchCancelFork = 0x0134,
  BranchStatus = 0x0135,
  ConsoleInput = 0x0136,
  SkipBkpt = 0x0137,
  Play = 0x0138,
  NavQuery = 0x0139,
  MarkerSet = 0x013a,
  FrameStatus = 0x013b,
  Diff = 0x013c,
  SetVar = 0x013d,
  UndoWrite = 0x013e,
  ResetImage = 0x013f,
  WorkspaceList = 0x0140,
  WorkspaceStat = 0x0141,
  WorkspaceRead = 0x0142,
  WorkspaceWrite = 0x0143,
  WorkspaceWatch = 0x0144,
  WorkspaceUnwatch = 0x0145,
  BuildStart = 0x0160,
  BuildStatus = 0x0161,
  BuildCancel = 0x0162,
  ProjectOpen = 0x0170,
  ProjectClose = 0x0171,
  ProjectBuild = 0x0172,
  ProjectPrepare = 0x0173,
  ArtifactsExportBegin = 0x0180,
  ArtifactsExportRead = 0x0181,
  ArtifactsImportBegin = 0x0182,
  ArtifactsImportWrite = 0x0183,
  ArtifactsImportEnd = 0x0184,
  ArtifactsAbort = 0x0185,
  TargetsList = 0x0190,
  TargetsReserve = 0x0191,
  TargetsRelease = 0x0192,
  TargetsPerform = 0x0193,
}

export { Method as Opcode };

/** Session and backend event topic IDs. */
export enum Topic {
  Stop = 0x0100,
  Uart = 0x0101,
  Speed = 0x0102,
  LcdDirty = 0x0103,
  Trace = 0x0104,
  Session = 0x0105,
  Transport = 0x0106,
  WorkspaceChanged = 0x0180,
  BuildEvent = 0x0181,
  BuildCompleted = 0x0182,
}

/** Target CPU core (`Core` in `rpc.zig`). */
export enum Core {
  Cpu0 = 0,
  Cpu1 = 1,
}

/** Run mode (`RunMode` in `rpc.zig`). */
export enum RunMode {
  Run = 0,
  Cont = 1,
  Step = 2,
  Next = 3,
  Finish = 4,
}

/** Stop reason (`StopReason` in `rpc.zig`). */
export enum StopReason {
  Stepped = 0,
  Breakpoint = 1,
  Watchpoint = 2,
  HaltRequested = 3,
  UnitBreak = 4,
  UnitWatch = 5,
  Count = 6,
  CoreFault = 7,
  ReplayFailed = 8,
}

/** Memory watchpoint access type (`Access` in `rpc.zig`). */
export enum Access {
  Read = 0,
  Write = 1,
  Access = 2,
}

/** Session event kind (`EventKind` in `rpc.zig`). */
export enum EventKind {
  Loaded = 0,
  Paused = 1,
  Stopped = 2,
  RegisterWritten = 3,
  MemoryWritten = 4,
  BreakpointSet = 5,
  BreakpointCleared = 6,
  WatchpointSet = 7,
  WatchpointCleared = 8,
  SpeedChanged = 9,
  InputScheduled = 10,
  FaultSet = 11,
  FaultCleared = 12,
  Plugged = 13,
  Unplugged = 14,
  LedChanged = 15,
  ModuleLoaded = 16,
  ModuleUnloaded = 17,
  ModuleFaulted = 18,
  RtosSwitch = 19,
  RtosIdle = 20,
  IsrEnter = 21,
  IsrLeave = 22,
  Rewound = 23,
}

/** Host input kind (`InputKind` in `rpc.zig`). */
export enum InputKind {
  Tap = 0,
  Swipe = 1,
  LongPress = 2,
  Button = 3,
}

export interface RpcHeader {
  length: number;
  kind: Kind;
}

export interface Hello {
  magic: number;
  version: number;
  caps: number;
}

export interface Fault {
  code: ErrorCode | number;
  version: number;
}

export interface RpcRequestEnvelope {
  id: number;
  method: Method | number;
  args: Uint8Array;
}

export interface RpcResponseEnvelope {
  id: number;
  ok: boolean;
  code?: ErrorCode | number;
  payload: Uint8Array;
}

export interface RpcEventEnvelope {
  topic: Topic | number;
  payload: Uint8Array;
}

export interface Ack {
  accepted: number;
}
