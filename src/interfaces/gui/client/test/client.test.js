import { createRunner } from "./helpers/runner.mjs";
import { run as runEnumsEnvelope } from "./unit/enums-envelope.test.mjs";
import { run as runSessionDebug } from "./unit/session-debug.test.mjs";
import { run as runHistoryDiff } from "./unit/history-diff.test.mjs";
import { run as runBackendCodecs } from "./unit/backend-codecs.test.mjs";
import { run as runBinaryFormats } from "./unit/binary-formats.test.mjs";
import { run as runClientSession } from "./unit/client-session.test.mjs";
import { run as runClientBackend } from "./unit/client-backend.test.mjs";
import { run as runEmulatorBin } from "./unit/emulator-bin.test.mjs";

async function main() {
  const suite = createRunner("RA8 Emulator RPC Client Tests");
  runEnumsEnvelope(suite);
  runSessionDebug(suite);
  runHistoryDiff(suite);
  runBackendCodecs(suite);
  await runBinaryFormats(suite);
  await runClientSession(suite);
  await runClientBackend(suite);
  runEmulatorBin(suite);
  suite.finish();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
