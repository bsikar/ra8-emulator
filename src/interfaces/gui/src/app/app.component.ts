import { ChangeDetectionStrategy, Component } from '@angular/core';
import { AppShellComponent } from './shell/app-shell.component';

@Component({
  selector: 'app-root',
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [AppShellComponent],
  template: `<app-shell />`,
})
export class AppComponent {}
