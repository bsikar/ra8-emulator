import {
  type FullscreenCapableDocument,
  isFullscreenActive,
  toggleDocumentFullscreen,
} from '../../../src/app/shared/utils/fullscreen';

describe('fullscreen utility', () => {
  it('enters and exits fullscreen cleanly via mock document', async () => {
    let activeEl: Element | null = null;
    const mockDoc: FullscreenCapableDocument = {
      get fullscreenElement() {
        return activeEl;
      },
      documentElement: {
        requestFullscreen: async () => {
          activeEl = document.createElement('div');
        },
      },
      exitFullscreen: async () => {
        activeEl = null;
      },
    };

    expect(isFullscreenActive(mockDoc)).toBe(false);
    const entered = await toggleDocumentFullscreen(mockDoc);
    expect(entered.active).toBe(true);
    expect(entered.error).toBeNull();
    expect(isFullscreenActive(mockDoc)).toBe(true);

    const exited = await toggleDocumentFullscreen(mockDoc);
    expect(exited.active).toBe(false);
    expect(exited.error).toBeNull();
  });

  it('surfaces browser refusal errors without throwing', async () => {
    const mockDoc: FullscreenCapableDocument = {
      fullscreenElement: null,
      documentElement: {
        requestFullscreen: async () => {
          throw new Error('Permissions check failed');
        },
      },
    };
    const res = await toggleDocumentFullscreen(mockDoc);
    expect(res.active).toBe(false);
    expect(res.error).toContain('Permissions check failed');
  });
});
