import { ChangeDetectionStrategy, Component, input } from '@angular/core';
import type { LaunchIconName } from './launch-commands';

@Component({
  selector: 'app-launch-icon',
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <svg
      [attr.width]="size()"
      [attr.height]="size()"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.65"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      @switch (name()) {
        @case ('search') {
          <circle cx="11" cy="11" r="7" />
          <path d="m20 20-3.5-3.5" />
        }
        @case ('open-folder') {
          <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" />
        }
        @case ('connect-remote') {
          <rect x="4" y="4" width="16" height="6" rx="1.5" />
          <rect x="4" y="14" width="16" height="6" rx="1.5" />
          <circle cx="8" cy="7" r="0.8" fill="currentColor" />
          <circle cx="8" cy="17" r="0.8" fill="currentColor" />
        }
        @case ('import-archive') {
          <rect x="3" y="4" width="18" height="4" rx="1" />
          <path d="M5 8v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8" />
          <path d="M10 12h4" />
        }
        @case ('new-workspace') {
          <rect x="4" y="4" width="16" height="16" rx="2" />
          <path d="M12 8v8M8 12h8" />
        }
        @case ('device-monitor') {
          <rect x="3" y="4" width="18" height="12" rx="1.5" />
          <path d="M8 20h8M12 16v4" />
        }
        @case ('board-composer') {
          <rect x="7" y="7" width="10" height="10" rx="1" />
          <path d="M9 4v3M15 4v3M9 17v3M15 17v3M4 9h3M4 15h3M17 9h3M17 15h3" />
        }
        @case ('settings') {
          <path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6" />
        }
        @case ('pin') {
          <path d="M12 17v5M9 4h6l-1 5 3 3v1H7v-1l3-3Z" [attr.fill]="filled() ? 'currentColor' : 'none'" />
        }
        @case ('kebab') {
          <circle cx="12" cy="5.5" r="1.2" fill="currentColor" stroke="none" />
          <circle cx="12" cy="12" r="1.2" fill="currentColor" stroke="none" />
          <circle cx="12" cy="18.5" r="1.2" fill="currentColor" stroke="none" />
        }
        @case ('search-everywhere') {
          <circle cx="10.5" cy="10.5" r="6" />
          <path d="m19.5 19.5-4-4M10.5 7.5v6M7.5 10.5h6" />
        }
        @case ('extensions') {
          <rect x="3" y="13" width="8" height="8" rx="1" />
          <rect x="3" y="3" width="8" height="8" rx="1" />
          <rect x="13" y="13" width="8" height="8" rx="1" />
          <path d="M13 7h8M17 3v8" />
        }
        @case ('vim') {
          <path d="M4 6h5l3 10L17 6h3L13.5 19h-3Z" />
        }
        @case ('palette') {
          <path d="m7 8 4 4-4 4M13 16h5" />
        }
        @case ('arrow-left') {
          <path d="M19 12H5M11 6l-6 6 6 6" />
        }
        @case ('arrow-right') {
          <path d="M5 12h14M13 6l6 6-6 6" />
        }
        @case ('network') {
          <circle cx="12" cy="12" r="9" />
          <path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18" />
        }
        @case ('key') {
          <circle cx="8" cy="14" r="3.5" />
          <path d="M10.8 11.5 20 3M17 6l2.5 2.5M14.5 8.5l2 2" />
        }
        @case ('terminal') {
          <path d="m4 7 5 5-5 5M11 17h9" />
        }
        @case ('eye') {
          <path d="M2 12s3.8-6 10-6 10 6 10 6-3.8 6-10 6-10-6-10-6Z" />
          <circle cx="12" cy="12" r="2.5" />
        }
        @case ('copy') {
          <rect x="9" y="9" width="11" height="11" rx="1.5" />
          <path d="M5 15H4a1.5 1.5 0 0 1-1.5-1.5v-9A1.5 1.5 0 0 1 4 3h9a1.5 1.5 0 0 1 1.5 1.5V6" />
        }
        @case ('refresh') {
          <path d="M20 6v5h-5M4 18v-5h5" />
          <path d="M19.2 11a7.5 7.5 0 0 0-12.7-4L4 9.5M4.8 13a7.5 7.5 0 0 0 12.7 4L20 14.5" />
        }
      }
    </svg>
  `,
  styles: [
    `
      :host {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        flex-shrink: 0;
      }
    `,
  ],
})
export class LaunchIconComponent {
  public readonly name = input.required<LaunchIconName>();
  public readonly size = input<number>(15);
  public readonly filled = input<boolean>(false);
}
