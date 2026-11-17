import {
  STARTER_EXTENSION_MANIFEST,
  parseExtensionManifestJson,
  validateExtensionManifest,
} from '../../../src/app/core/extensions/extension-manifest';

describe('extension-manifest', () => {
  it('validates the starter manifest and structured contributions strictly', () => {
    const res = validateExtensionManifest(STARTER_EXTENSION_MANIFEST);
    expect(res.ok).toBe(true);
    if (res.ok) {
      expect(res.manifest.id).toBe('ra8.target-inspector');
      expect(res.manifest.contributes.commands.length).toBe(1);
    }

    const fromJson = parseExtensionManifestJson(JSON.stringify(STARTER_EXTENSION_MANIFEST));
    expect(fromJson.ok).toBe(true);
  });

  it('rejects malformed JSON, wrong id/publisher pairs, bad semver, and invalid contributions', () => {
    expect(validateExtensionManifest(null).ok).toBe(false);
    expect(validateExtensionManifest([]).ok).toBe(false);
    expect(parseExtensionManifestJson('{bad json').ok).toBe(false);

    const invalid = validateExtensionManifest({
      id: 'other.tool',
      name: 'tool',
      publisher: 'acme',
      displayName: '',
      version: 'not-semver',
      description: 42,
      activationEvents: [''],
      contributes: {
        commands: [{ command: '', title: 'Run' }],
        panels: [{ id: 'p1', title: 'Panel', location: 'invalid-loc' }],
      },
      mainSource: '',
    });
    expect(invalid.ok).toBe(false);
    if (!invalid.ok) {
      expect(invalid.errors.some((e) => e.includes('must equal "acme.tool"'))).toBe(true);
      expect(invalid.errors.some((e) => e.includes('version'))).toBe(true);
      expect(invalid.errors.some((e) => e.includes('invalid-loc') || e.includes('location'))).toBe(true);
    }
  });
});
