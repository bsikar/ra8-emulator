import { createRunner } from "./helpers/runner.mjs";
import { run as runTruncation } from "./adversarial/truncation.test.mjs";
import { run as runFraming } from "./adversarial/framing.test.mjs";
import { run as runClientErrors } from "./adversarial/client-errors.test.mjs";

async function main() {
  const suite = createRunner("Adversarial & Stress Tests for ra8-rpc-client");
  runTruncation(suite);
  runFraming(suite);
  await runClientErrors(suite);
  suite.finish();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
