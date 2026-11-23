import { Injectable, inject } from '@angular/core';
import { Core, type RA8RpcClient } from 'ra8-rpc-client';
import { RpcConnectionStore } from '../rpc/rpc-connection.store';
import { DebugStore } from './debug.store';
import { ExecutionStore } from './execution.store';

@Injectable({ providedIn: 'root' })
export class DebugLabelsStore {
  private readonly debug = inject(DebugStore);
  private readonly execution = inject(ExecutionStore);
  private readonly rpc = inject(RpcConnectionStore);

  public setAddressLabel(core: Core, address: number, name: string): Promise<boolean> {
    if (this.rpc.observeOnly()) return Promise.resolve(false);
    const rows = core === Core.Cpu0 ? this.debug.cpu0Disasm() : this.debug.cpu1Disasm();
    return this.runRpc('Address label update failed', false, async (client) => {
      const accepted = await client.setLabel({ core, address, name });
      if (accepted) await this.debug.refreshDisassembly(core, rows[0]?.address);
      return accepted;
    });
  }

  public setLocalLabel(core: Core, frame: number, local: string, name: string): Promise<boolean> {
    if (this.rpc.observeOnly()) return Promise.resolve(false);
    return this.runRpc('Local label update failed', false, async (client) => {
      const accepted = await client.setLocalLabel({ core, frame, local, name });
      if (accepted) this.execution.inspectionEpoch.update((n) => n + 1);
      return accepted;
    });
  }

  private async runRpc<T>(label: string, fallback: T, fn: (client: RA8RpcClient) => Promise<T>): Promise<T> {
    const client = this.rpc.activeClient;
    if (!client) return fallback;
    try {
      return await fn(client);
    } catch (err) {
      this.rpc.reportError(label, err);
      return fallback;
    }
  }

}
