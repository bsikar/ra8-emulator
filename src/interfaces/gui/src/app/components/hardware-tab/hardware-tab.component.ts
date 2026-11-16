import { CommonModule } from '@angular/common';
import { Component, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { EmulatorService } from '../../services/emulator.service';
import { PeripheralInspectorComponent } from '../peripheral-inspector/peripheral-inspector.component';
import { VirtualBoardComponent } from '../virtual-board/virtual-board.component';

export type HardwareSubView = 'signals' | 'board';

@Component({
  selector: 'app-hardware-tab',
  standalone: true,
  imports: [CommonModule, FormsModule, VirtualBoardComponent, PeripheralInspectorComponent],
  template: `
    <div class="ob-page">
      <div class="ob-card">
        <div class="ob-card-head">
          <div class="ob-row">
            <h2 class="ob-card-title">Hardware-in-the-Loop (HIL) &amp; Bus Matrix</h2>
            <div class="ob-seg" role="group" aria-label="Hardware sub-view">
              <button type="button" class="ob-seg-btn" [class.active]="subView() === 'signals'"
                      (click)="subView.set('signals')">
                Bus Signals
              </button>
              <button type="button" class="ob-seg-btn" [class.active]="subView() === 'board'"
                      (click)="subView.set('board')">
                Board Screen &amp; NPU
              </button>
            </div>
          </div>

          <div class="ob-row">
            <input
              type="text"
              class="ob-input mono ob-spec-input"
              [(ngModel)]="newPartSpec"
              placeholder="sht40@riic1:0x44"
              aria-label="Part specification to attach" />
            <select class="ob-select ob-bus-select" [(ngModel)]="newPartBus" aria-label="Target bus">
              <option value="RIIC1">RIIC1</option>
              <option value="SPI0">SPI0 (CS0)</option>
              <option value="OSPI0">OSPI0</option>
            </select>
            <button type="button" class="ob-btn ob-btn-primary" data-testid="primary-cta" (click)="attachPart()">
              Attach Part
            </button>
          </div>
        </div>

        <div class="ob-card-body">
          <div class="ob-table-wrap">
            <table class="ob-table">
              <thead>
                <tr>
                  <th>Fitted Device</th>
                  <th>Bus</th>
                  <th>Address / Line</th>
                  <th>Status</th>
                  <th>Fault State</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                @for (dev of emu.hardwareDevices(); track dev.id) {
                  <tr>
                    <td class="mono">{{ dev.partSpec }}</td>
                    <td>{{ dev.bus }}</td>
                    <td class="mono">{{ dev.address }}</td>
                    <td>
                      <span class="ob-pill"
                            [class.ob-pill-ok]="dev.status === 'attached'"
                            [class.ob-pill-err]="dev.status === 'fault'">
                        {{ dev.status }}
                      </span>
                    </td>
                    <td class="mono">{{ dev.activeFault ?? 'nominal' }}</td>
                    <td>
                      <div class="ob-row">
                        @if (dev.status === 'unplugged') {
                          <button type="button" class="ob-btn ob-btn-sm" (click)="emu.attachPart(dev.partSpec, dev.bus)">
                            Re-attach
                          </button>
                        } @else {
                          <button type="button" class="ob-btn ob-btn-sm" (click)="emu.detachPart(dev.id)">
                            Unplug
                          </button>
                        }
                        @if (dev.activeFault) {
                          <button type="button" class="ob-btn ob-btn-sm" (click)="emu.clearFaultOnPart(dev.id)">
                            Clear Fault
                          </button>
                        } @else {
                          <button type="button" class="ob-btn ob-btn-sm ob-btn-danger" (click)="emu.injectFaultOnPart(dev.id, 'nack:8')">
                            Inject nack:8
                          </button>
                        }
                      </div>
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          </div>
        </div>
      </div>

      @if (subView() === 'signals') {
        <div class="ob-card">
          <div class="ob-card-head">
            <h2 class="ob-card-title">Controller &amp; Peripheral Bus Timing (SCL / SDA · COPI / CIPO · CS)</h2>
            <span class="ob-pill">Inclusive Bus Decode</span>
          </div>
          <div class="ob-card-body">
            <div class="ob-wave-wrap">
              <svg viewBox="0 0 760 110" width="100%" height="110" role="img" aria-label="2-channel SCL and SDA digital timing waveform">
                <text x="10" y="34" fill="#A1A1AA" font-size="12" font-family="monospace">SCL (Controller)</text>
                <polyline
                  points="160,36 180,36 180,18 205,18 205,36 230,36 230,18 255,18 255,36 280,36 280,18 305,18 305,36 330,36 330,18 355,18 355,36 390,36 390,18 415,18 415,36 440,36 440,18 465,18 465,36 520,36"
                  fill="none"
                  stroke="#0A84FF"
                  stroke-width="2" />
                <text x="10" y="84" fill="#A1A1AA" font-size="12" font-family="monospace">SDA (Peripheral)</text>
                <polyline
                  points="160,68 180,68 180,86 245,86 245,68 310,68 310,86 380,86 380,68 460,68 460,86 520,86"
                  fill="none"
                  stroke="#30D158"
                  stroke-width="2" />
                <rect x="540" y="16" width="206" height="28" rx="4" fill="#1A1A1D" stroke="rgba(255,255,255,0.14)" />
                <text x="552" y="35" fill="#F2F2F7" font-size="12" font-family="monospace">CS0 · COPI / CIPO Ready</text>
              </svg>
            </div>

            <div class="ob-table-wrap">
              <table class="ob-table">
                <thead>
                  <tr>
                    <th>Seq</th>
                    <th>Time (ms)</th>
                    <th>Bus</th>
                    <th>Role</th>
                    <th>Signal / Lines</th>
                    <th>Address</th>
                    <th>Payload</th>
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody>
                  @for (tx of emu.busTransactions(); track tx.seq) {
                    <tr>
                      <td class="mono">#{{ tx.seq }}</td>
                      <td class="mono">{{ tx.timeMs }}</td>
                      <td class="mono">{{ tx.bus }}</td>
                      <td>{{ tx.role }}</td>
                      <td class="mono">{{ tx.signal }}</td>
                      <td class="mono">{{ tx.address }}</td>
                      <td class="mono">{{ tx.payload }}</td>
                      <td>
                        <span class="ob-pill" [class.ob-pill-err]="tx.status === 'NACK'" [class.ob-pill-ok]="tx.status !== 'NACK'">
                          {{ tx.status }}
                        </span>
                      </td>
                    </tr>
                  }
                </tbody>
              </table>
            </div>
          </div>
        </div>
      } @else {
        <div class="ob-grid-2">
          <div class="ob-card">
            <div class="ob-card-head">
              <h2 class="ob-card-title">Virtual Board Screen &amp; Touch</h2>
            </div>
            <div class="ob-card-body">
              <app-virtual-board />
            </div>
          </div>
          <div class="ob-card">
            <div class="ob-card-head">
              <h2 class="ob-card-title">On-Chip Peripherals &amp; Ethos-U55 Inspector</h2>
            </div>
            <div class="ob-card-body">
              <app-peripheral-inspector />
            </div>
          </div>
        </div>
      }
    </div>
  `,
  styles: [
    `:host { display: block; height: 100%; overflow: auto; font-size: 12px; }
     .ob-spec-input { width: 170px; }
     .ob-bus-select { width: 120px; }
     .ob-wave-wrap { background: var(--bg-void); border: 1px solid var(--border-hairline); border-radius: var(--radius-md); padding: 8px; }`,
  ],
})
export class HardwareTabComponent {
  public readonly emu = inject(EmulatorService);
  public readonly subView = signal<HardwareSubView>('signals');
  public newPartSpec = 'sht40@riic1:0x44';
  public newPartBus = 'RIIC1';

  public async attachPart(): Promise<void> {
    await this.emu.attachPart(this.newPartSpec, this.newPartBus);
  }
}
