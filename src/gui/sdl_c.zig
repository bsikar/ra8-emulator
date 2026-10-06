//! The one SDL3 C import of the gui_sdl module, shared by its files so they
//! all see the same SDL types.
pub const c = @cImport(@cInclude("SDL3/SDL.h"));
