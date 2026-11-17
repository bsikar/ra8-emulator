import '@angular/compiler';
import '@analogjs/vitest-angular/setup-zone';

import { getTestBed } from '@angular/core/testing';
import {
  BrowserDynamicTestingModule,
  platformBrowserDynamicTesting,
} from '@angular/platform-browser-dynamic/testing';

const TESTBED_KEY = Symbol.for('ra8-testbed-init');
const globalObj = globalThis as Record<symbol, boolean | undefined>;

if (!globalObj[TESTBED_KEY]) {
  globalObj[TESTBED_KEY] = true;
  getTestBed().initTestEnvironment(
    BrowserDynamicTestingModule,
    platformBrowserDynamicTesting(),
    { teardown: { destroyAfterEach: true } }
  );
}
