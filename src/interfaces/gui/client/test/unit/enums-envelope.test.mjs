import assert from "node:assert/strict";
import {
  CAP_ARTIFACTS,
  CAP_BUILD,
  CAP_PROJECT,
  CAP_RECOVERY,
  CAP_TARGETS,
  CAP_TRANSPORT,
  CAP_WORKSPACE,
  DEFAULT_CLIENT_CAPS,
  ErrorCode,
  HEADER_BYTES,
  Kind,
  Method,
  PROTOCOL_MAGIC,
  PROTOCOL_VERSION,
  Topic,
  decodeEvent,
  decodeFault,
  decodeHeader,
  decodeHello,
  decodeRequest,
  decodeResponse,
  encodeEvent,
  encodeFault,
  encodeFrame,
  encodeHeader,
  encodeHello,
  encodeRequest,
  encodeResponse,
  splitFrames,
} from "../../dist/index.js";

function registerEnumTests(suite) {
  suite.section("Enums, Capabilities, Error Codes & Envelopes");

  suite.test("Method defines all 64 session opcodes (0x0100..0x013F) plus 23 backend opcodes", () => {
    const numeric = Object.values(Method).filter((v) => typeof v === "number");
    assert.equal(numeric.length, 87);
    assert.equal(Method.Load, 0x0100);
    assert.equal(Method.Interrupt, 0x0110);
    assert.equal(Method.SetRunBudget, 0x0111);
    assert.equal(Method.SetCameraSource, 0x011b);
    assert.equal(Method.Rtc, 0x011e);
    assert.equal(Method.AdvanceAsync, 0x012b);
    assert.equal(Method.SetVar, 0x013d);
    assert.equal(Method.UndoWrite, 0x013e);
    assert.equal(Method.ResetImage, 0x013f);
    assert.equal(Method.WorkspaceList, 0x0140);
    assert.equal(Method.WorkspaceUnwatch, 0x0145);
    assert.equal(Method.BuildStart, 0x0160);
    assert.equal(Method.BuildCancel, 0x0162);
    assert.equal(Method.ProjectOpen, 0x0170);
    assert.equal(Method.ProjectPrepare, 0x0173);
    assert.equal(Method.ArtifactsExportBegin, 0x0180);
    assert.equal(Method.ArtifactsAbort, 0x0185);
    assert.equal(Method.TargetsList, 0x0190);
    assert.equal(Method.TargetsPerform, 0x0193);
  });

  suite.test("Capabilities and ErrorCode cover 0x0150..0x0197 and CAP_TRANSPORT..CAP_TARGETS", () => {
    assert.equal(CAP_TRANSPORT, 1 << 15);
    assert.equal(CAP_WORKSPACE, 1 << 16);
    assert.equal(CAP_BUILD, 1 << 17);
    assert.equal(CAP_PROJECT, 1 << 18);
    assert.equal(CAP_RECOVERY, 1 << 19);
    assert.equal(CAP_ARTIFACTS, 1 << 20);
    assert.equal(CAP_TARGETS, 1 << 21);
    assert.equal(DEFAULT_CLIENT_CAPS, 0x003f_ffff);

    assert.equal(ErrorCode.WorkspaceUnavailable, 0x0150);
    assert.equal(ErrorCode.WorkspaceNotFile, 0x0157);
    assert.equal(ErrorCode.BuildUnavailable, 0x0160);
    assert.equal(ErrorCode.BuildIo, 0x0163);
    assert.equal(ErrorCode.ProjectUnavailable, 0x0170);
    assert.equal(ErrorCode.ProjectChanged, 0x0174);
    assert.equal(ErrorCode.ArtifactsUnavailable, 0x0180);
    assert.equal(ErrorCode.ArtifactsIo, 0x0184);
    assert.equal(ErrorCode.TargetsUnavailable, 0x0190);
    assert.equal(ErrorCode.TargetsFailed, 0x0197);
  });

  suite.test("all 10 Topic codes (0x0100..0x0106, 0x0180..0x0182) are defined", () => {
    const topics = Object.values(Topic).filter((v) => typeof v === "number");
    assert.equal(topics.length, 10);
    assert.equal(Topic.Stop, 0x0100);
    assert.equal(Topic.Transport, 0x0106);
    assert.equal(Topic.WorkspaceChanged, 0x0180);
    assert.equal(Topic.BuildEvent, 0x0181);
    assert.equal(Topic.BuildCompleted, 0x0182);
  });
}

function registerEnvelopeTests(suite) {
  suite.test("Header, Hello, Fault, Request, Response, Event, and splitFrames roundtrip", () => {
    const hdr = decodeHeader(encodeHeader(1024, Kind.Request));
    assert.equal(hdr.length, 1024);
    assert.equal(hdr.kind, Kind.Request);

    const hello = decodeHello(encodeHello(DEFAULT_CLIENT_CAPS));
    assert.equal(hello.magic, PROTOCOL_MAGIC);
    assert.equal(hello.version, PROTOCOL_VERSION);
    assert.equal(hello.caps, DEFAULT_CLIENT_CAPS);

    const fault = decodeFault(encodeFault(ErrorCode.BadArgs));
    assert.equal(fault.code, ErrorCode.BadArgs);

    const req = decodeRequest(encodeRequest(42, Method.Step, new Uint8Array([1, 2, 3])));
    assert.equal(req.id, 42);
    assert.equal(req.method, Method.Step);
    assert.deepEqual(Array.from(req.args), [1, 2, 3]);

    const okResp = decodeResponse(encodeResponse(77, true, new Uint8Array([0xaa, 0xbb])));
    assert.equal(okResp.ok, true);
    assert.deepEqual(Array.from(okResp.payload), [0xaa, 0xbb]);

    const errResp = decodeResponse(encodeResponse(88, false, ErrorCode.TargetsCustodian));
    assert.equal(errResp.ok, false);
    assert.equal(errResp.code, ErrorCode.TargetsCustodian);

    const ev = decodeEvent(encodeEvent(Topic.BuildEvent, new Uint8Array([0x10, 0x20])));
    assert.equal(ev.topic, Topic.BuildEvent);
    assert.deepEqual(Array.from(ev.payload), [0x10, 0x20]);

    const f1 = encodeFrame(Kind.Hello, encodeHello(0x1234));
    const f2 = encodeFrame(Kind.Event, encodeEvent(Topic.Speed, new Uint8Array([1])));
    const combined = new Uint8Array(f1.length + f2.length + 2);
    combined.set(f1, 0);
    combined.set(f2, f1.length);
    combined.set([0x99, 0x88], f1.length + f2.length);
    const split = splitFrames(combined);
    assert.equal(HEADER_BYTES, 6);
    assert.equal(split.frames.length, 2);
    assert.deepEqual(Array.from(split.remainder), [0x99, 0x88]);
  });
}

export function run(suite) {
  registerEnumTests(suite);
  registerEnvelopeTests(suite);
}
