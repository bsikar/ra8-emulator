export function createRunner(title) {
  let passed = 0;
  let failed = 0;
  console.log(`=== ${title} ===\n`);

  return {
    section(label) {
      console.log(`--- ${label} ---`);
    },
    test(name, fn) {
      try {
        fn();
        console.log(`  ✓ ${name}`);
        passed++;
      } catch (err) {
        console.error(`  ✗ ${name}`);
        console.error(err);
        failed++;
      }
    },
    async testAsync(name, fn) {
      try {
        await fn();
        console.log(`  ✓ ${name}`);
        passed++;
      } catch (err) {
        console.error(`  ✗ ${name}`);
        console.error(err);
        failed++;
      }
    },
    finish() {
      console.log(`\n=== ${title} Results: ${passed} passed, ${failed} failed ===`);
      if (failed > 0) {
        process.exit(1);
      }
    },
  };
}
