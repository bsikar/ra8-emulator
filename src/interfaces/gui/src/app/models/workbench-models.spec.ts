import {
  BoardProfileConfig,
  BOARD_PRESETS,
  parseBoardConfig,
  serializeBoardConfig,
  setTopologyMode,
} from './board-config';
import {
  detectElfDwarfSections,
  decompileThumbRows,
} from './decompiler';
import {
  buildSidewaysRewindLayout,
  RewindTreeBranchInput,
  RewindTreeNodeInput,
} from './rewind-tree';
import {
  parseFoldedStacks,
  FlamegraphNode,
} from './flamegraph';

describe('Obsidian Workbench Pure Models', () => {
  describe('Board Configurator & Adaptable Silicon Topologies', () => {
    it('parses EK-RA8D2 version=1 .board directives and round-trips cleanly', () => {
      const raw = [
        'version=1',
        'ospi=32M',
        'sdram=64M',
        'memory_window_cycles=128',
        'led=red@p000,green@p001,blue@p002',
        'switch=user@p003',
        'panel=ER-TFT070-6',
        'sensor=imx477@cam0',
        'companion=enabled',
      ].join('\n');

      const cfg: BoardProfileConfig = parseBoardConfig('ek_ra8d2.board', raw);
      expect(cfg.fileName).toBe('ek_ra8d2.board');
      expect(cfg.ospiMiB).toBe(32);
      expect(cfg.sdramMiB).toBe(64);
      expect(cfg.memoryWindowCycles).toBe(128);
      expect(cfg.panel).toBe('ER-TFT070-6');
      expect(cfg.topology).toBe('dual');
      expect(cfg.cores.length).toBe(2);
      expect(cfg.cores[0].arch).toBe('Cortex-M85');
      expect(cfg.cores[1].arch).toBe('Cortex-M33');

      const serialized = serializeBoardConfig(cfg);
      expect(serialized).toContain('version=1');
      expect(serialized).toContain('panel=ER-TFT070-6');
      expect(serialized).toContain('companion=enabled');
    });

    it('adapts seamlessly across Single-Core, Dual-Core, and Multi-Core permutations with NPU', () => {
      const base = BOARD_PRESETS[1];
      expect(base.topology).toBe('dual');
      expect(base.npuEnabled).toBeTrue();

      const single = setTopologyMode(base, 'single');
      expect(single.cores.length).toBe(1);
      expect(single.cores[0].arch).toBe('Cortex-M85');
      expect(single.cores[0].clockMhz).toBe(1000);

      const multi = setTopologyMode(single, 'multi');
      expect(multi.cores.length).toBeGreaterThanOrEqual(3);
      expect(multi.cores.some((c) => c.arch === 'Cortex-M85')).toBeTrue();
      expect(multi.cores.some((c) => c.arch === 'Cortex-M33')).toBeTrue();
    });
  });

  describe('Stripped ELF Detection & Deterministic Decompiler (RA8EMU-1247)', () => {
    it('detects stripped vs DWARF ELF buffers from section table headers', () => {
      const elfWithDwarf = new TextEncoder().encode('\x7fELF\x01\x01\x01\x00\0\0\0\0\0\0\0\0.debug_info\0.symtab\0');
      const strippedElf = new TextEncoder().encode('\x7fELF\x01\x01\x01\x00\0\0\0\0\0\0\0\0.text\0.symtab\0');
      expect(detectElfDwarfSections(elfWithDwarf)).toBeTrue();
      expect(detectElfDwarfSections(strippedElf)).toBeFalse();
    });

    it('synthesizes structured C pseudocode and tracks active PC line from Thumb-2 DisasmRow[]', () => {
      const result = decompileThumbRows(
        [
          { address: 0x02004a10, size: 2, decoded: true, raw: new Uint8Array([0x10, 0xb5]), text: 'push {r4, lr}', symbol: 'fn_02004a10' },
          { address: 0x02004a12, size: 4, decoded: true, raw: new Uint8Array(4), text: 'bl riic1_read_reg', symbol: '' },
          { address: 0x02004a16, size: 2, decoded: true, raw: new Uint8Array(2), text: 'cmp r0, #0x6c', symbol: '' },
          { address: 0x02004a18, size: 2, decoded: true, raw: new Uint8Array(2), text: 'bne 0x02004a24', symbol: '' },
          { address: 0x02004a1a, size: 4, decoded: true, raw: new Uint8Array(4), text: 'ldr r3, [r1, #0x2c]', symbol: '' },
          { address: 0x02004a1e, size: 2, decoded: true, raw: new Uint8Array(2), text: 'pop {r4, pc}', symbol: '' },
        ],
        0x02004a16
      );

      expect(result.functionName).toBe('fn_02004a10');
      expect(result.lines.some((l) => l.code.includes('int32_t fn_02004a10'))).toBeTrue();
      expect(result.lines.some((l) => l.code.includes('riic1_read_reg('))).toBeTrue();
      expect(result.lines.some((l) => l.code.includes('if ('))).toBeTrue();
      expect(result.activeLineNumber).not.toBeNull();
      const activeLine = result.lines.find((l) => l.lineNumber === result.activeLineNumber);
      expect(activeLine?.address).toBe(0x02004a16);
    });
  });

  describe('Sideways Left-to-Right Rewind Tree Layout', () => {
    it('lays out t=0 on the left branching rightward across lanes with Bezier SVG curves and zero overlap', () => {
      const branches: RewindTreeBranchInput[] = [
        { branch: 0, parentBranch: 0, forkRound: 0, name: 'Branch 0 · Baseline', actor: 'human', reasonBadge: 'BASE' },
        { branch: 1, parentBranch: 0, forkRound: 904, name: 'Branch 1 · Fault Active', actor: 'agent', reasonBadge: 'FAULT', isActive: true },
        { branch: 2, parentBranch: 1, forkRound: 912, name: 'Branch 2 · Retry Patch', actor: 'human', reasonBadge: 'PATCH' },
      ];
      const nodes: RewindTreeNodeInput[] = [
        { id: 'chk_0', label: 'Chk #0 · Reset', round: 0, timeSec: 0, branch: 0 },
        { id: 'chk_8', label: 'Chk #8 · RIIC1 Init', round: 840, timeSec: 0.84, branch: 0 },
        { id: 'chk_14', label: 'Chk #14 · Poll Start', round: 904, timeSec: 1.80, branch: 1, isJunction: true },
        { id: 'chk_15', label: 'Chk #15 · NACK Fault', round: 912, timeSec: 1.82, branch: 1, isCursor: true, faultBadge: 'NACK' },
        { id: 'chk_22', label: 'Chk #22', round: 1320, timeSec: 2.64, branch: 0 },
        { id: 'chk_19', label: 'Chk #19 · Recovered', round: 1280, timeSec: 2.56, branch: 2 },
      ];

      const layout = buildSidewaysRewindLayout(branches, nodes);
      expect(layout.nodes.length).toBe(6);
      const n0 = layout.nodes.find((n) => n.id === 'chk_0')!;
      const n8 = layout.nodes.find((n) => n.id === 'chk_8')!;
      const n15 = layout.nodes.find((n) => n.id === 'chk_15')!;
      const n22 = layout.nodes.find((n) => n.id === 'chk_22')!;
      expect(n0.x).toBeLessThan(n8.x);
      expect(n8.x).toBeLessThan(n15.x);
      expect(n15.x).toBeLessThan(n22.x);
      expect(layout.edges.length).toBeGreaterThanOrEqual(4);
      expect(layout.edges.every((e) => e.pathD.startsWith('M ') && e.pathD.includes(' C '))).toBeTrue();
    });
  });

  describe('Normalized Bottom-Up Folded Flamegraph Builder', () => {
    it('enforces parentWidth >= sum(childrenWidth) and detects hotspots', () => {
      const folded = [
        'Reset_Handler;main;tx_kernel_enter;vision_infer 390',
        'Reset_Handler;main;tx_kernel_enter;ethos_u55_wait 290',
        'Reset_Handler;main;tx_kernel_enter;imu_mve_norm 170',
        'Reset_Handler;main;tx_kernel_enter;tx_idle 90',
        'Reset_Handler;main;drw_blend 44',
      ].join('\n');

      const graph = parseFoldedStacks(folded);
      expect(graph.totalSamples).toBe(984);
      expect(graph.hotspot?.name).toBe('vision_infer');

      const byParent = new Map<string, FlamegraphNode[]>();
      for (const node of graph.nodes) {
        if (node.parentId) {
          const list = byParent.get(node.parentId) ?? [];
          list.push(node);
          byParent.set(node.parentId, list);
        }
      }
      for (const [parentId, children] of byParent.entries()) {
        const parent = graph.nodes.find((n) => n.id === parentId)!;
        const childSum = children.reduce((acc, c) => acc + c.widthPct, 0);
        expect(parent.widthPct + 0.01).toBeGreaterThanOrEqual(childSum);
      }
    });
  });
});
