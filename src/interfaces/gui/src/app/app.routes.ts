import { type Routes } from '@angular/router';

export const appRoutes: Routes = [
  { path: '', pathMatch: 'full', redirectTo: 'launch' },
  {
    path: 'launch',
    loadComponent: () => import('./routes/launch.route').then((m) => m.LaunchRouteComponent),
  },
  {
    path: 'connect',
    loadComponent: () => import('./routes/connect.route').then((m) => m.ConnectRouteComponent),
  },
  {
    path: 'debug',
    loadComponent: () => import('./routes/debug.route').then((m) => m.DebugRouteComponent),
  },
  {
    path: 'hardware',
    loadComponent: () => import('./routes/hardware.route').then((m) => m.HardwareRouteComponent),
  },
  {
    path: 'rewind',
    loadComponent: () => import('./routes/rewind.route').then((m) => m.RewindRouteComponent),
  },
  {
    path: 'profile',
    loadComponent: () => import('./routes/profile.route').then((m) => m.ProfileRouteComponent),
  },
  {
    path: 'console',
    loadComponent: () => import('./routes/console.route').then((m) => m.ConsoleRouteComponent),
  },
  { path: '**', redirectTo: 'launch' },
];
