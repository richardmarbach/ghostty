//! Surface represents a single terminal "surface". A terminal surface is
//! a minimal "widget" where the terminal is drawn and responds to events
//! such as keyboard and mouse. Each surface also creates and owns its pty
//! session.
//!
//! The word "surface" is used because it is left to the higher level
//! application runtime to determine if the surface is a window, a tab,
//! a split, a preview pane in a larger window, etc. This struct doesn't care:
//! it just draws and responds to events. The events come from the application
//! runtime so the runtime can determine when and how those are delivered
//! (i.e. with focus, without focus, and so on).
const Surface = @This();

const apprt = @import("apprt.zig");
pub const Mailbox = apprt.surface.Mailbox;
pub const Message = apprt.surface.Message;

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const renderer = @import("renderer.zig");
const termio = @import("termio.zig");
const objc = @import("objc");
const imgui = @import("imgui");
const Pty = @import("Pty.zig");
const font = @import("font/main.zig");
const Command = @import("Command.zig");
const trace = @import("tracy").trace;
const terminal = @import("terminal/main.zig");
const Config = @import("config.zig").Config;
const input = @import("input.zig");
const DevMode = @import("DevMode.zig");
const App = @import("App.zig");
const internal_os = @import("os/main.zig");

const log = std.log.scoped(.surface);

// The renderer implementation to use.
const Renderer = renderer.Renderer;

/// Allocator
alloc: Allocator,

/// The mailbox for sending messages to the main app thread.
app_mailbox: App.Mailbox,

/// The windowing system surface
rt_surface: *apprt.runtime.Surface,

/// The font structures
font_lib: font.Library,
font_group: *font.GroupCache,
font_size: font.face.DesiredSize,

/// Imgui context
imgui_ctx: if (DevMode.enabled) *imgui.Context else void,

/// The renderer for this surface.
renderer: Renderer,

/// The render state
renderer_state: renderer.State,

/// The renderer thread manager
renderer_thread: renderer.Thread,

/// The actual thread
renderer_thr: std.Thread,

/// Mouse state.
mouse: Mouse,
mouse_interval: u64,

/// The terminal IO handler.
io: termio.Impl,
io_thread: termio.Thread,
io_thr: std.Thread,

/// All the cached sizes since we need them at various times.
screen_size: renderer.ScreenSize,
grid_size: renderer.GridSize,
cell_size: renderer.CellSize,

/// Explicit padding due to configuration
padding: renderer.Padding,

/// The app configuration
config: *const Config,

/// Set to true for a single GLFW key/char callback cycle to cause the
/// char callback to ignore. GLFW seems to always do key followed by char
/// callbacks so we abuse that here. This is to solve an issue where commands
/// like such as "control-v" will write a "v" even if they're intercepted.
ignore_char: bool = false,

/// Mouse state for the surface.
const Mouse = struct {
    /// The last tracked mouse button state by button.
    click_state: [input.MouseButton.max]input.MouseButtonState = .{.release} ** input.MouseButton.max,

    /// The last mods state when the last mouse button (whatever it was) was
    /// pressed or release.
    mods: input.Mods = .{},

    /// The point at which the left mouse click happened. This is in screen
    /// coordinates so that scrolling preserves the location.
    left_click_point: terminal.point.ScreenPoint = .{},

    /// The starting xpos/ypos of the left click. Note that if scrolling occurs,
    /// these will point to different "cells", but the xpos/ypos will stay
    /// stable during scrolling relative to the surface.
    left_click_xpos: f64 = 0,
    left_click_ypos: f64 = 0,

    /// The count of clicks to count double and triple clicks and so on.
    /// The left click time was the last time the left click was done. This
    /// is always set on the first left click.
    left_click_count: u8 = 0,
    left_click_time: std.time.Instant = undefined,

    /// The last x/y sent for mouse reports.
    event_point: terminal.point.Viewport = .{},
};

/// Create a new surface. This must be called from the main thread. The
/// pointer to the memory for the surface must be provided and must be
/// stable due to interfacing with various callbacks.
pub fn init(
    self: *Surface,
    alloc: Allocator,
    config: *const Config,
    app_mailbox: App.Mailbox,
    rt_surface: *apprt.runtime.Surface,
) !void {
    // Initialize our renderer with our initialized surface.
    try Renderer.surfaceInit(rt_surface);

    // Determine our DPI configurations so we can properly configure
    // font points to pixels and handle other high-DPI scaling factors.
    const content_scale = try rt_surface.getContentScale();
    const x_dpi = content_scale.x * font.face.default_dpi;
    const y_dpi = content_scale.y * font.face.default_dpi;
    log.debug("xscale={} yscale={} xdpi={} ydpi={}", .{
        content_scale.x,
        content_scale.y,
        x_dpi,
        y_dpi,
    });

    // The font size we desire along with the DPI determined for the surface
    const font_size: font.face.DesiredSize = .{
        .points = config.@"font-size",
        .xdpi = @floatToInt(u16, x_dpi),
        .ydpi = @floatToInt(u16, y_dpi),
    };

    // Find all the fonts for this surface
    //
    // Future: we can share the font group amongst all surfaces to save
    // some new surface init time and some memory. This will require making
    // thread-safe changes to font structs.
    var font_lib = try font.Library.init();
    errdefer font_lib.deinit();
    var font_group = try alloc.create(font.GroupCache);
    errdefer alloc.destroy(font_group);
    font_group.* = try font.GroupCache.init(alloc, group: {
        var group = try font.Group.init(alloc, font_lib, font_size);
        errdefer group.deinit();

        // Search for fonts
        if (font.Discover != void) {
            var disco = font.Discover.init();
            group.discover = disco;

            if (config.@"font-family") |family| {
                var disco_it = try disco.discover(.{
                    .family = family,
                    .size = font_size.points,
                });
                defer disco_it.deinit();
                if (try disco_it.next()) |face| {
                    log.info("font regular: {s}", .{try face.name()});
                    try group.addFace(alloc, .regular, face);
                }
            }
            if (config.@"font-family-bold") |family| {
                var disco_it = try disco.discover(.{
                    .family = family,
                    .size = font_size.points,
                    .bold = true,
                });
                defer disco_it.deinit();
                if (try disco_it.next()) |face| {
                    log.info("font bold: {s}", .{try face.name()});
                    try group.addFace(alloc, .bold, face);
                }
            }
            if (config.@"font-family-italic") |family| {
                var disco_it = try disco.discover(.{
                    .family = family,
                    .size = font_size.points,
                    .italic = true,
                });
                defer disco_it.deinit();
                if (try disco_it.next()) |face| {
                    log.info("font italic: {s}", .{try face.name()});
                    try group.addFace(alloc, .italic, face);
                }
            }
            if (config.@"font-family-bold-italic") |family| {
                var disco_it = try disco.discover(.{
                    .family = family,
                    .size = font_size.points,
                    .bold = true,
                    .italic = true,
                });
                defer disco_it.deinit();
                if (try disco_it.next()) |face| {
                    log.info("font bold+italic: {s}", .{try face.name()});
                    try group.addFace(alloc, .bold_italic, face);
                }
            }
        }

        // Our built-in font will be used as a backup
        try group.addFace(
            alloc,
            .regular,
            font.DeferredFace.initLoaded(try font.Face.init(font_lib, face_ttf, font_size)),
        );
        try group.addFace(
            alloc,
            .bold,
            font.DeferredFace.initLoaded(try font.Face.init(font_lib, face_bold_ttf, font_size)),
        );

        // Emoji fallback. We don't include this on Mac since Mac is expected
        // to always have the Apple Emoji available.
        if (builtin.os.tag != .macos or font.Discover == void) {
            try group.addFace(
                alloc,
                .regular,
                font.DeferredFace.initLoaded(try font.Face.init(font_lib, face_emoji_ttf, font_size)),
            );
            try group.addFace(
                alloc,
                .regular,
                font.DeferredFace.initLoaded(try font.Face.init(font_lib, face_emoji_text_ttf, font_size)),
            );
        }

        // If we're on Mac, then we try to use the Apple Emoji font for Emoji.
        if (builtin.os.tag == .macos and font.Discover != void) {
            var disco = font.Discover.init();
            defer disco.deinit();
            var disco_it = try disco.discover(.{
                .family = "Apple Color Emoji",
                .size = font_size.points,
            });
            defer disco_it.deinit();
            if (try disco_it.next()) |face| {
                log.debug("font emoji: {s}", .{try face.name()});
                try group.addFace(alloc, .regular, face);
            }
        }

        break :group group;
    });
    errdefer font_group.deinit(alloc);

    // Pre-calculate our initial cell size ourselves.
    const cell_size = try renderer.CellSize.init(alloc, font_group);

    // Convert our padding from points to pixels
    const padding_x = (@intToFloat(f32, config.@"window-padding-x") * x_dpi) / 72;
    const padding_y = (@intToFloat(f32, config.@"window-padding-y") * y_dpi) / 72;
    const padding: renderer.Padding = .{
        .top = padding_y,
        .bottom = padding_y,
        .right = padding_x,
        .left = padding_x,
    };

    // Create our terminal grid with the initial size
    var renderer_impl = try Renderer.init(alloc, .{
        .config = config,
        .font_group = font_group,
        .padding = .{
            .explicit = padding,
            .balance = config.@"window-padding-balance",
        },
        .surface_mailbox = .{ .surface = self, .app = app_mailbox },
    });
    errdefer renderer_impl.deinit();

    // Calculate our grid size based on known dimensions.
    const surface_size = try rt_surface.getSize();
    const screen_size: renderer.ScreenSize = .{
        .width = surface_size.width,
        .height = surface_size.height,
    };
    const grid_size = renderer.GridSize.init(
        screen_size.subPadding(padding),
        cell_size,
    );

    // The mutex used to protect our renderer state.
    var mutex = try alloc.create(std.Thread.Mutex);
    mutex.* = .{};
    errdefer alloc.destroy(mutex);

    // Create the renderer thread
    var render_thread = try renderer.Thread.init(
        alloc,
        rt_surface,
        &self.renderer,
        &self.renderer_state,
        app_mailbox,
    );
    errdefer render_thread.deinit();

    // Start our IO implementation
    var io = try termio.Impl.init(alloc, .{
        .grid_size = grid_size,
        .screen_size = screen_size,
        .config = config,
        .renderer_state = &self.renderer_state,
        .renderer_wakeup = render_thread.wakeup,
        .renderer_mailbox = render_thread.mailbox,
        .surface_mailbox = .{ .surface = self, .app = app_mailbox },
    });
    errdefer io.deinit();

    // Create the IO thread
    var io_thread = try termio.Thread.init(alloc, &self.io);
    errdefer io_thread.deinit();

    // True if this surface is hosting devmode. We only host devmode on
    // the first surface since imgui is not threadsafe. We need to do some
    // work to make DevMode work with multiple threads.
    const host_devmode = DevMode.enabled and DevMode.instance.surface == null;

    self.* = .{
        .alloc = alloc,
        .app_mailbox = app_mailbox,
        .rt_surface = rt_surface,
        .font_lib = font_lib,
        .font_group = font_group,
        .font_size = font_size,
        .renderer = renderer_impl,
        .renderer_thread = render_thread,
        .renderer_state = .{
            .mutex = mutex,
            .cursor = .{
                .style = .blinking_block,
                .visible = true,
            },
            .terminal = &self.io.terminal,
            .devmode = if (!host_devmode) null else &DevMode.instance,
        },
        .renderer_thr = undefined,
        .mouse = .{},
        .mouse_interval = config.@"click-repeat-interval" * 1_000_000, // 500ms
        .io = io,
        .io_thread = io_thread,
        .io_thr = undefined,
        .screen_size = screen_size,
        .grid_size = grid_size,
        .cell_size = cell_size,
        .padding = padding,
        .config = config,

        .imgui_ctx = if (!DevMode.enabled) {} else try imgui.Context.create(),
    };
    errdefer if (DevMode.enabled) self.imgui_ctx.destroy();

    // Set a minimum size that is cols=10 h=4. This matches Mac's Terminal.app
    // but is otherwise somewhat arbitrary.
    try rt_surface.setSizeLimits(.{
        .width = @floatToInt(u32, cell_size.width * 10),
        .height = @floatToInt(u32, cell_size.height * 4),
    }, null);

    // Call our size callback which handles all our retina setup
    // Note: this shouldn't be necessary and when we clean up the surface
    // init stuff we should get rid of this. But this is required because
    // sizeCallback does retina-aware stuff we don't do here and don't want
    // to duplicate.
    try self.sizeCallback(surface_size);

    // Load imgui. This must be done LAST because it has to be done after
    // all our GLFW setup is complete.
    if (DevMode.enabled and DevMode.instance.surface == null) {
        const dev_io = try imgui.IO.get();
        dev_io.cval().IniFilename = "ghostty_dev_mode.ini";

        // Add our built-in fonts so it looks slightly better
        const dev_atlas = @ptrCast(*imgui.FontAtlas, dev_io.cval().Fonts);
        dev_atlas.addFontFromMemoryTTF(
            face_ttf,
            @intToFloat(f32, font_size.pixels()),
        );

        // Default dark style
        const style = try imgui.Style.get();
        style.colorsDark();

        // Add our surface to the instance if it isn't set.
        DevMode.instance.surface = self;

        // Let our renderer setup
        try renderer_impl.initDevMode(rt_surface);
    }

    // Give the renderer one more opportunity to finalize any surface
    // setup on the main thread prior to spinning up the rendering thread.
    try renderer_impl.finalizeSurfaceInit(rt_surface);

    // Start our renderer thread
    self.renderer_thr = try std.Thread.spawn(
        .{},
        renderer.Thread.threadMain,
        .{&self.renderer_thread},
    );
    self.renderer_thr.setName("renderer") catch {};

    // Start our IO thread
    self.io_thr = try std.Thread.spawn(
        .{},
        termio.Thread.threadMain,
        .{&self.io_thread},
    );
    self.io_thr.setName("io") catch {};
}

pub fn deinit(self: *Surface) void {
    // Stop rendering thread
    {
        self.renderer_thread.stop.notify() catch |err|
            log.err("error notifying renderer thread to stop, may stall err={}", .{err});
        self.renderer_thr.join();

        // We need to become the active rendering thread again
        self.renderer.threadEnter(self.rt_surface) catch unreachable;

        // If we are devmode-owning, clean that up.
        if (DevMode.enabled and DevMode.instance.surface == self) {
            // Let our renderer clean up
            self.renderer.deinitDevMode();

            // Clear the surface
            DevMode.instance.surface = null;

            // Uninitialize imgui
            self.imgui_ctx.destroy();
        }
    }

    // Stop our IO thread
    {
        self.io_thread.stop.notify() catch |err|
            log.err("error notifying io thread to stop, may stall err={}", .{err});
        self.io_thr.join();
    }

    // We need to deinit AFTER everything is stopped, since there are
    // shared values between the two threads.
    self.renderer_thread.deinit();
    self.renderer.deinit();
    self.io_thread.deinit();
    self.io.deinit();

    self.font_group.deinit(self.alloc);
    self.font_lib.deinit();
    self.alloc.destroy(self.font_group);

    self.alloc.destroy(self.renderer_state.mutex);
    log.info("surface closed addr={x}", .{@ptrToInt(self)});
}

/// Called from the app thread to handle mailbox messages to our specific
/// surface.
pub fn handleMessage(self: *Surface, msg: Message) !void {
    switch (msg) {
        .set_title => |*v| {
            // The ptrCast just gets sliceTo to return the proper type.
            // We know that our title should end in 0.
            const slice = std.mem.sliceTo(@ptrCast([*:0]const u8, v), 0);
            log.debug("changing title \"{s}\"", .{slice});
            try self.rt_surface.setTitle(slice);
        },

        .cell_size => |size| try self.setCellSize(size),

        .clipboard_read => |kind| try self.clipboardRead(kind),

        .clipboard_write => |req| switch (req) {
            .small => |v| try self.clipboardWrite(v.data[0..v.len]),
            .stable => |v| try self.clipboardWrite(v),
            .alloc => |v| {
                defer v.alloc.free(v.data);
                try self.clipboardWrite(v.data);
            },
        },
    }
}

/// Returns the x/y coordinate of where the IME (Input Method Editor)
/// keyboard should be rendered.
pub fn imePoint(self: *const Surface) apprt.IMEPos {
    self.renderer_state.mutex.lock();
    const cursor = self.renderer_state.terminal.screen.cursor;
    self.renderer_state.mutex.unlock();

    // TODO: need to handle when scrolling and the cursor is not
    // in the visible portion of the screen.

    // Our sizes are all scaled so we need to send the unscaled values back.
    const content_scale = self.rt_surface.getContentScale() catch .{ .x = 1, .y = 1 };

    const x: f64 = x: {
        // Simple x * cell width gives the top-left corner
        var x: f64 = @floatCast(f64, @intToFloat(f32, cursor.x) * self.cell_size.width);

        // We want the midpoint
        x += self.cell_size.width / 2;

        // And scale it
        x /= content_scale.x;

        break :x x;
    };

    const y: f64 = y: {
        // Simple x * cell width gives the top-left corner
        var y: f64 = @floatCast(f64, @intToFloat(f32, cursor.y) * self.cell_size.height);

        // We want the bottom
        y += self.cell_size.height;

        // And scale it
        y /= content_scale.y;

        break :y y;
    };

    return .{ .x = x, .y = y };
}

fn clipboardRead(self: *const Surface, kind: u8) !void {
    if (!self.config.@"clipboard-read") {
        log.info("application attempted to read clipboard, but 'clipboard-read' setting is off", .{});
        return;
    }

    const data = self.rt_surface.getClipboardString() catch |err| {
        log.warn("error reading clipboard: {}", .{err});
        return;
    };

    // Even if the clipboard data is empty we reply, since presumably
    // the client app is expecting a reply. We first allocate our buffer.
    // This must hold the base64 encoded data PLUS the OSC code surrounding it.
    const enc = std.base64.standard.Encoder;
    const size = enc.calcSize(data.len);
    var buf = try self.alloc.alloc(u8, size + 9); // const for OSC
    defer self.alloc.free(buf);

    // Wrap our data with the OSC code
    const prefix = try std.fmt.bufPrint(buf, "\x1b]52;{c};", .{kind});
    assert(prefix.len == 7);
    buf[buf.len - 2] = '\x1b';
    buf[buf.len - 1] = '\\';

    // Do the base64 encoding
    const encoded = enc.encode(buf[prefix.len..], data);
    assert(encoded.len == size);

    _ = self.io_thread.mailbox.push(try termio.Message.writeReq(
        self.alloc,
        buf,
    ), .{ .forever = {} });
    self.io_thread.wakeup.notify() catch {};
}

fn clipboardWrite(self: *const Surface, data: []const u8) !void {
    if (!self.config.@"clipboard-write") {
        log.info("application attempted to write clipboard, but 'clipboard-write' setting is off", .{});
        return;
    }

    const dec = std.base64.standard.Decoder;

    // Build buffer
    const size = try dec.calcSizeForSlice(data);
    var buf = try self.alloc.allocSentinel(u8, size, 0);
    defer self.alloc.free(buf);
    buf[buf.len] = 0;

    // Decode
    try dec.decode(buf, data);
    assert(buf[buf.len] == 0);

    self.rt_surface.setClipboardString(buf) catch |err| {
        log.err("error setting clipboard string err={}", .{err});
        return;
    };
}

/// Change the cell size for the terminal grid. This can happen as
/// a result of changing the font size at runtime.
fn setCellSize(self: *Surface, size: renderer.CellSize) !void {
    // Update our new cell size for future calcs
    self.cell_size = size;

    // Update our grid_size
    self.grid_size = renderer.GridSize.init(
        self.screen_size.subPadding(self.padding),
        self.cell_size,
    );

    // Notify the terminal
    _ = self.io_thread.mailbox.push(.{
        .resize = .{
            .grid_size = self.grid_size,
            .screen_size = self.screen_size,
            .padding = self.padding,
        },
    }, .{ .forever = {} });
    self.io_thread.wakeup.notify() catch {};
}

/// Change the font size.
///
/// This can only be called from the main thread.
pub fn setFontSize(self: *Surface, size: font.face.DesiredSize) void {
    // Update our font size so future changes work
    self.font_size = size;

    // Notify our render thread of the font size. This triggers everything else.
    _ = self.renderer_thread.mailbox.push(.{
        .font_size = size,
    }, .{ .forever = {} });

    // Schedule render which also drains our mailbox
    self.queueRender() catch unreachable;
}

/// This queues a render operation with the renderer thread. The render
/// isn't guaranteed to happen immediately but it will happen as soon as
/// practical.
fn queueRender(self: *const Surface) !void {
    try self.renderer_thread.wakeup.notify();
}

pub fn sizeCallback(self: *Surface, size: apprt.SurfaceSize) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // TODO: if our screen size didn't change, then we should avoid the
    // overhead of inter-thread communication

    // Save our screen size
    self.screen_size = .{
        .width = size.width,
        .height = size.height,
    };

    // Recalculate our grid size
    self.grid_size = renderer.GridSize.init(
        self.screen_size.subPadding(self.padding),
        self.cell_size,
    );
    if (self.grid_size.columns < 5 and (self.padding.left > 0 or self.padding.right > 0)) {
        log.warn("WARNING: very small terminal grid detected with padding " ++
            "set. Is your padding reasonable?", .{});
    }
    if (self.grid_size.rows < 2 and (self.padding.top > 0 or self.padding.bottom > 0)) {
        log.warn("WARNING: very small terminal grid detected with padding " ++
            "set. Is your padding reasonable?", .{});
    }

    // Mail the renderer
    _ = self.renderer_thread.mailbox.push(.{
        .screen_size = self.screen_size,
    }, .{ .forever = {} });
    try self.queueRender();

    // Mail the IO thread
    _ = self.io_thread.mailbox.push(.{
        .resize = .{
            .grid_size = self.grid_size,
            .screen_size = self.screen_size,
            .padding = self.padding,
        },
    }, .{ .forever = {} });
    try self.io_thread.wakeup.notify();
}

pub fn charCallback(self: *Surface, codepoint: u21) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // Dev Mode
    if (DevMode.enabled and DevMode.instance.visible) {
        // If the event was handled by imgui, ignore it.
        if (imgui.IO.get()) |io| {
            if (io.cval().WantCaptureKeyboard) {
                try self.queueRender();
            }
        } else |_| {}
    }

    // Ignore if requested. See field docs for more information.
    if (self.ignore_char) {
        self.ignore_char = false;
        return;
    }

    // Critical area
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // Clear the selction if we have one.
        if (self.io.terminal.selection != null) {
            self.io.terminal.selection = null;
            try self.queueRender();
        }

        // We want to scroll to the bottom
        // TODO: detect if we're at the bottom to avoid the render call here.
        try self.io.terminal.scrollViewport(.{ .bottom = {} });
    }

    // Ask our IO thread to write the data
    var data: termio.Message.WriteReq.Small.Array = undefined;
    const len = try std.unicode.utf8Encode(codepoint, &data);
    _ = self.io_thread.mailbox.push(.{
        .write_small = .{
            .data = data,
            .len = len,
        },
    }, .{ .forever = {} });

    // After sending all our messages we have to notify our IO thread
    try self.io_thread.wakeup.notify();
}

pub fn keyCallback(
    self: *Surface,
    action: input.Action,
    key: input.Key,
    mods: input.Mods,
) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // Dev Mode
    if (DevMode.enabled and DevMode.instance.visible) {
        // If the event was handled by imgui, ignore it.
        if (imgui.IO.get()) |io| {
            if (io.cval().WantCaptureKeyboard) {
                try self.queueRender();
            }
        } else |_| {}
    }

    // Reset the ignore char setting. If we didn't handle the char
    // by here, we aren't going to get it so we just reset this.
    self.ignore_char = false;

    if (action == .press or action == .repeat) {
        const trigger: input.Binding.Trigger = .{
            .mods = mods,
            .key = key,
        };

        //log.warn("BINDING TRIGGER={}", .{trigger});
        if (self.config.keybind.set.get(trigger)) |binding_action| {
            //log.warn("BINDING ACTION={}", .{binding_action});

            switch (binding_action) {
                .unbind => unreachable,
                .ignore => {},

                .csi => |data| {
                    _ = self.io_thread.mailbox.push(.{
                        .write_stable = "\x1B[",
                    }, .{ .forever = {} });
                    _ = self.io_thread.mailbox.push(.{
                        .write_stable = data,
                    }, .{ .forever = {} });
                    try self.io_thread.wakeup.notify();
                },

                .cursor_key => |ck| {
                    // We send a different sequence depending on if we're
                    // in cursor keys mode. We're in "normal" mode if cursor
                    // keys mdoe is NOT set.
                    const normal = normal: {
                        self.renderer_state.mutex.lock();
                        defer self.renderer_state.mutex.unlock();
                        break :normal !self.io.terminal.modes.cursor_keys;
                    };

                    if (normal) {
                        _ = self.io_thread.mailbox.push(.{
                            .write_stable = ck.normal,
                        }, .{ .forever = {} });
                    } else {
                        _ = self.io_thread.mailbox.push(.{
                            .write_stable = ck.application,
                        }, .{ .forever = {} });
                    }

                    try self.io_thread.wakeup.notify();
                },

                .copy_to_clipboard => {
                    // We can read from the renderer state without holding
                    // the lock because only we will write to this field.
                    if (self.io.terminal.selection) |sel| {
                        var buf = self.io.terminal.screen.selectionString(
                            self.alloc,
                            sel,
                            self.config.@"clipboard-trim-trailing-spaces",
                        ) catch |err| {
                            log.err("error reading selection string err={}", .{err});
                            return;
                        };
                        defer self.alloc.free(buf);

                        self.rt_surface.setClipboardString(buf) catch |err| {
                            log.err("error setting clipboard string err={}", .{err});
                            return;
                        };
                    }
                },

                .paste_from_clipboard => {
                    const data = self.rt_surface.getClipboardString() catch |err| {
                        log.warn("error reading clipboard: {}", .{err});
                        return;
                    };

                    if (data.len > 0) {
                        const bracketed = bracketed: {
                            self.renderer_state.mutex.lock();
                            defer self.renderer_state.mutex.unlock();
                            break :bracketed self.io.terminal.modes.bracketed_paste;
                        };

                        if (bracketed) {
                            _ = self.io_thread.mailbox.push(.{
                                .write_stable = "\x1B[200~",
                            }, .{ .forever = {} });
                        }

                        _ = self.io_thread.mailbox.push(try termio.Message.writeReq(
                            self.alloc,
                            data,
                        ), .{ .forever = {} });

                        if (bracketed) {
                            _ = self.io_thread.mailbox.push(.{
                                .write_stable = "\x1B[201~",
                            }, .{ .forever = {} });
                        }

                        try self.io_thread.wakeup.notify();
                    }
                },

                .increase_font_size => |delta| {
                    log.debug("increase font size={}", .{delta});

                    var size = self.font_size;
                    size.points +|= delta;
                    self.setFontSize(size);
                },

                .decrease_font_size => |delta| {
                    log.debug("decrease font size={}", .{delta});

                    var size = self.font_size;
                    size.points = @max(1, size.points -| delta);
                    self.setFontSize(size);
                },

                .reset_font_size => {
                    log.debug("reset font size", .{});

                    var size = self.font_size;
                    size.points = self.config.@"font-size";
                    self.setFontSize(size);
                },

                .clear_screen => {
                    _ = self.io_thread.mailbox.push(.{
                        .clear_screen = .{ .history = true },
                    }, .{ .forever = {} });
                    try self.io_thread.wakeup.notify();
                },

                .toggle_dev_mode => if (DevMode.enabled) {
                    DevMode.instance.visible = !DevMode.instance.visible;
                    try self.queueRender();
                } else log.warn("dev mode was not compiled into this binary", .{}),

                .new_window => {
                    _ = self.app_mailbox.push(.{
                        .new_window = .{
                            .parent = self,
                        },
                    }, .{ .instant = {} });
                },

                .new_tab => {
                    if (@hasDecl(apprt.Surface, "newTab")) {
                        try self.rt_surface.newTab();
                    } else log.warn("runtime doesn't implement newTab", .{});
                },

                .previous_tab => {
                    if (@hasDecl(apprt.Surface, "gotoPreviousTab")) {
                        self.rt_surface.gotoPreviousTab();
                    } else log.warn("runtime doesn't implement gotoPreviousTab", .{});
                },

                .next_tab => {
                    if (@hasDecl(apprt.Surface, "gotoNextTab")) {
                        self.rt_surface.gotoNextTab();
                    } else log.warn("runtime doesn't implement gotoNextTab", .{});
                },

                .goto_tab => |n| {
                    if (@hasDecl(apprt.Surface, "gotoTab")) {
                        self.rt_surface.gotoTab(n);
                    } else log.warn("runtime doesn't implement gotoTab", .{});
                },

                .new_split => |direction| {
                    if (@hasDecl(apprt.Surface, "newSplit")) {
                        try self.rt_surface.newSplit(direction);
                    } else log.warn("runtime doesn't implement newSplit", .{});
                },

                .close_surface => {
                    if (@hasDecl(apprt.Surface, "closeSurface")) {
                        try self.rt_surface.closeSurface();
                    } else log.warn("runtime doesn't implement closeSurface", .{});
                },

                .close_window => {
                    _ = self.app_mailbox.push(.{ .close = self }, .{ .instant = {} });
                },

                .quit => {
                    _ = self.app_mailbox.push(.{
                        .quit = {},
                    }, .{ .instant = {} });
                },
            }

            // Bindings always result in us ignoring the char if printable
            self.ignore_char = true;

            // No matter what, if there is a binding then we are done.
            return;
        }

        // Handle non-printables
        const char: u8 = char: {
            const mods_int = @bitCast(u8, mods);
            const ctrl_only = @bitCast(u8, input.Mods{ .ctrl = true });

            // If we're only pressing control, check if this is a character
            // we convert to a non-printable.
            if (mods_int == ctrl_only) {
                const val: u8 = switch (key) {
                    .a => 0x01,
                    .b => 0x02,
                    .c => 0x03,
                    .d => 0x04,
                    .e => 0x05,
                    .f => 0x06,
                    .g => 0x07,
                    .h => 0x08,
                    .i => 0x09,
                    .j => 0x0A,
                    .k => 0x0B,
                    .l => 0x0C,
                    .m => 0x0D,
                    .n => 0x0E,
                    .o => 0x0F,
                    .p => 0x10,
                    .q => 0x11,
                    .r => 0x12,
                    .s => 0x13,
                    .t => 0x14,
                    .u => 0x15,
                    .v => 0x16,
                    .w => 0x17,
                    .x => 0x18,
                    .y => 0x19,
                    .z => 0x1A,
                    else => 0,
                };

                if (val > 0) break :char val;
            }

            // Otherwise, we don't care what modifiers we press we do this.
            break :char @as(u8, switch (key) {
                .backspace => 0x7F,
                .enter => '\r',
                .tab => '\t',
                .escape => 0x1B,
                else => 0,
            });
        };
        if (char > 0) {
            // Ask our IO thread to write the data
            var data: termio.Message.WriteReq.Small.Array = undefined;
            data[0] = @intCast(u8, char);
            _ = self.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = 1,
                },
            }, .{ .forever = {} });

            // After sending all our messages we have to notify our IO thread
            try self.io_thread.wakeup.notify();
        }
    }
}

pub fn focusCallback(self: *Surface, focused: bool) !void {
    // Notify our render thread of the new state
    _ = self.renderer_thread.mailbox.push(.{
        .focus = focused,
    }, .{ .forever = {} });

    // Schedule render which also drains our mailbox
    try self.queueRender();
}

pub fn refreshCallback(self: *Surface) !void {
    // The point of this callback is to schedule a render, so do that.
    try self.queueRender();
}

pub fn scrollCallback(self: *Surface, xoff: f64, yoff: f64) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // If our dev mode surface is visible then we always schedule a render on
    // cursor move because the cursor might touch our surfaces.
    if (DevMode.enabled and DevMode.instance.visible) {
        try self.queueRender();

        // If the mouse event was handled by imgui, ignore it.
        if (imgui.IO.get()) |io| {
            if (io.cval().WantCaptureMouse) return;
        } else |_| {}
    }

    //log.info("SCROLL: {} {}", .{ xoff, yoff });
    _ = xoff;

    // Positive is up
    const sign: isize = if (yoff > 0) -1 else 1;
    const delta: isize = sign * @max(@divFloor(self.grid_size.rows, 15), 1);
    log.info("scroll: delta={}", .{delta});

    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // Modify our viewport, this requires a lock since it affects rendering
        try self.io.terminal.scrollViewport(.{ .delta = delta });

        // If we're scrolling up or down, then send a mouse event. This requires
        // a lock since we read terminal state.
        if (yoff != 0) {
            const pos = try self.rt_surface.getCursorPos();
            try self.mouseReport(if (yoff < 0) .five else .four, .press, self.mouse.mods, pos);
        }
    }

    try self.queueRender();
}

/// The type of action to report for a mouse event.
const MouseReportAction = enum { press, release, motion };

fn mouseReport(
    self: *Surface,
    button: ?input.MouseButton,
    action: MouseReportAction,
    mods: input.Mods,
    pos: apprt.CursorPos,
) !void {
    // TODO: posToViewport currently clamps to the surface boundary,
    // do we want to not report mouse events at all outside the surface?

    // Depending on the event, we may do nothing at all.
    switch (self.io.terminal.modes.mouse_event) {
        .none => return,

        // X10 only reports clicks with mouse button 1, 2, 3. We verify
        // the button later.
        .x10 => if (action != .press or
            button == null or
            !(button.? == .left or
            button.? == .right or
            button.? == .middle)) return,

        // Doesn't report motion
        .normal => if (action == .motion) return,

        // Button must be pressed
        .button => if (button == null) return,

        // Everything
        .any => {},
    }

    // This format reports X/Y
    const viewport_point = self.posToViewport(pos.x, pos.y);

    // Record our new point
    self.mouse.event_point = viewport_point;

    // Get the code we'll actually write
    const button_code: u8 = code: {
        var acc: u8 = 0;

        // Determine our initial button value
        if (button == null) {
            // Null button means motion without a button pressed
            acc = 3;
        } else if (action == .release and self.io.terminal.modes.mouse_format != .sgr) {
            // Release is 3. It is NOT 3 in SGR mode because SGR can tell
            // the application what button was released.
            acc = 3;
        } else {
            acc = switch (button.?) {
                .left => 0,
                .right => 1,
                .middle => 2,
                .four => 64,
                .five => 65,
                else => return, // unsupported
            };
        }

        // X10 doesn't have modifiers
        if (self.io.terminal.modes.mouse_event != .x10) {
            if (mods.shift) acc += 4;
            if (mods.super) acc += 8;
            if (mods.ctrl) acc += 16;
        }

        // Motion adds another bit
        if (action == .motion) acc += 32;

        break :code acc;
    };

    switch (self.io.terminal.modes.mouse_format) {
        .x10 => {
            if (viewport_point.x > 222 or viewport_point.y > 222) {
                log.info("X10 mouse format can only encode X/Y up to 223", .{});
                return;
            }

            // + 1 below is because our x/y is 0-indexed and the protocol wants 1
            var data: termio.Message.WriteReq.Small.Array = undefined;
            assert(data.len >= 6);
            data[0] = '\x1b';
            data[1] = '[';
            data[2] = 'M';
            data[3] = 32 + button_code;
            data[4] = 32 + @intCast(u8, viewport_point.x) + 1;
            data[5] = 32 + @intCast(u8, viewport_point.y) + 1;

            // Ask our IO thread to write the data
            _ = self.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = 6,
                },
            }, .{ .forever = {} });
        },

        .utf8 => {
            // Maximum of 12 because at most we have 2 fully UTF-8 encoded chars
            var data: termio.Message.WriteReq.Small.Array = undefined;
            assert(data.len >= 12);
            data[0] = '\x1b';
            data[1] = '[';
            data[2] = 'M';

            // The button code will always fit in a single u8
            data[3] = 32 + button_code;

            // UTF-8 encode the x/y
            var i: usize = 4;
            i += try std.unicode.utf8Encode(@intCast(u21, 32 + viewport_point.x + 1), data[i..]);
            i += try std.unicode.utf8Encode(@intCast(u21, 32 + viewport_point.y + 1), data[i..]);

            // Ask our IO thread to write the data
            _ = self.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = @intCast(u8, i),
                },
            }, .{ .forever = {} });
        },

        .sgr => {
            // Final character to send in the CSI
            const final: u8 = if (action == .release) 'm' else 'M';

            // Response always is at least 4 chars, so this leaves the
            // remainder for numbers which are very large...
            var data: termio.Message.WriteReq.Small.Array = undefined;
            const resp = try std.fmt.bufPrint(&data, "\x1B[<{d};{d};{d}{c}", .{
                button_code,
                viewport_point.x + 1,
                viewport_point.y + 1,
                final,
            });

            // Ask our IO thread to write the data
            _ = self.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = @intCast(u8, resp.len),
                },
            }, .{ .forever = {} });
        },

        .urxvt => {
            // Response always is at least 4 chars, so this leaves the
            // remainder for numbers which are very large...
            var data: termio.Message.WriteReq.Small.Array = undefined;
            const resp = try std.fmt.bufPrint(&data, "\x1B[{d};{d};{d}M", .{
                32 + button_code,
                viewport_point.x + 1,
                viewport_point.y + 1,
            });

            // Ask our IO thread to write the data
            _ = self.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = @intCast(u8, resp.len),
                },
            }, .{ .forever = {} });
        },

        .sgr_pixels => {
            // Final character to send in the CSI
            const final: u8 = if (action == .release) 'm' else 'M';

            // Response always is at least 4 chars, so this leaves the
            // remainder for numbers which are very large...
            var data: termio.Message.WriteReq.Small.Array = undefined;
            const resp = try std.fmt.bufPrint(&data, "\x1B[<{d};{d};{d}{c}", .{
                button_code,
                pos.x,
                pos.y,
                final,
            });

            // Ask our IO thread to write the data
            _ = self.io_thread.mailbox.push(.{
                .write_small = .{
                    .data = data,
                    .len = @intCast(u8, resp.len),
                },
            }, .{ .forever = {} });
        },
    }

    // After sending all our messages we have to notify our IO thread
    try self.io_thread.wakeup.notify();
}

pub fn mouseButtonCallback(
    self: *Surface,
    action: input.MouseButtonState,
    button: input.MouseButton,
    mods: input.Mods,
) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // If our dev mode surface is visible then we always schedule a render on
    // cursor move because the cursor might touch our surfaces.
    if (DevMode.enabled and DevMode.instance.visible) {
        try self.queueRender();

        // If the mouse event was handled by imgui, ignore it.
        if (imgui.IO.get()) |io| {
            if (io.cval().WantCaptureMouse) return;
        } else |_| {}
    }

    // Always record our latest mouse state
    self.mouse.click_state[@intCast(usize, @enumToInt(button))] = action;
    self.mouse.mods = @bitCast(input.Mods, mods);

    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    // Report mouse events if enabled
    if (self.io.terminal.modes.mouse_event != .none) {
        const pos = try self.rt_surface.getCursorPos();

        const report_action: MouseReportAction = switch (action) {
            .press => .press,
            .release => .release,
        };

        try self.mouseReport(
            button,
            report_action,
            self.mouse.mods,
            pos,
        );

        // If we're doing mouse reporting, we do not support any other
        // selection or highlighting.
        return;
    }

    // For left button clicks we always record some information for
    // selection/highlighting purposes.
    if (button == .left and action == .press) {
        const pos = try self.rt_surface.getCursorPos();

        // If we move our cursor too much between clicks then we reset
        // the multi-click state.
        if (self.mouse.left_click_count > 0) {
            const max_distance = self.cell_size.width;
            const distance = @sqrt(
                std.math.pow(f64, pos.x - self.mouse.left_click_xpos, 2) +
                    std.math.pow(f64, pos.y - self.mouse.left_click_ypos, 2),
            );

            if (distance > max_distance) self.mouse.left_click_count = 0;
        }

        // Store it
        const point = self.posToViewport(pos.x, pos.y);
        self.mouse.left_click_point = point.toScreen(&self.io.terminal.screen);
        self.mouse.left_click_xpos = pos.x;
        self.mouse.left_click_ypos = pos.y;

        // Setup our click counter and timer
        if (std.time.Instant.now()) |now| {
            // If we have mouse clicks, then we check if the time elapsed
            // is less than and our interval and if so, increase the count.
            if (self.mouse.left_click_count > 0) {
                const since = now.since(self.mouse.left_click_time);
                if (since > self.mouse_interval) {
                    self.mouse.left_click_count = 0;
                }
            }

            self.mouse.left_click_time = now;
            self.mouse.left_click_count += 1;

            // We only support up to triple-clicks.
            if (self.mouse.left_click_count > 3) self.mouse.left_click_count = 1;
        } else |err| {
            self.mouse.left_click_count = 1;
            log.err("error reading time, mouse multi-click won't work err={}", .{err});
        }

        switch (self.mouse.left_click_count) {
            // First mouse click, clear selection
            1 => if (self.io.terminal.selection != null) {
                self.io.terminal.selection = null;
                try self.queueRender();
            },

            // Double click, select the word under our mouse
            2 => {
                const sel_ = self.io.terminal.screen.selectWord(self.mouse.left_click_point);
                if (sel_) |sel| {
                    self.io.terminal.selection = sel;
                    try self.queueRender();
                }
            },

            // Triple click, select the line under our mouse
            3 => {
                const sel_ = self.io.terminal.screen.selectLine(self.mouse.left_click_point);
                if (sel_) |sel| {
                    self.io.terminal.selection = sel;
                    try self.queueRender();
                }
            },

            // We should be bounded by 1 to 3
            else => unreachable,
        }
    }
}

pub fn cursorPosCallback(
    self: *Surface,
    pos: apprt.CursorPos,
) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // If our dev mode surface is visible then we always schedule a render on
    // cursor move because the cursor might touch our surfaces.
    if (DevMode.enabled and DevMode.instance.visible) {
        try self.queueRender();

        // If the mouse event was handled by imgui, ignore it.
        if (imgui.IO.get()) |io| {
            if (io.cval().WantCaptureMouse) return;
        } else |_| {}
    }

    // We are reading/writing state for the remainder
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    // Do a mouse report
    if (self.io.terminal.modes.mouse_event != .none) {
        // We use the first mouse button we find pressed in order to report
        // since the spec (afaict) does not say...
        const button: ?input.MouseButton = button: for (self.mouse.click_state, 0..) |state, i| {
            if (state == .press)
                break :button @intToEnum(input.MouseButton, i);
        } else null;

        try self.mouseReport(button, .motion, self.mouse.mods, pos);

        // If we're doing mouse motion tracking, we do not support text
        // selection.
        return;
    }

    // If the cursor isn't clicked currently, it doesn't matter
    if (self.mouse.click_state[@enumToInt(input.MouseButton.left)] != .press) return;

    // All roads lead to requiring a re-render at this pont.
    try self.queueRender();

    // Convert to pixels from screen coords
    const xpos = pos.x;
    const ypos = pos.y;

    // Convert to points
    const viewport_point = self.posToViewport(xpos, ypos);
    const screen_point = viewport_point.toScreen(&self.io.terminal.screen);

    // Handle dragging depending on click count
    switch (self.mouse.left_click_count) {
        1 => self.dragLeftClickSingle(screen_point, xpos),
        2 => self.dragLeftClickDouble(screen_point),
        3 => self.dragLeftClickTriple(screen_point),
        else => unreachable,
    }
}

/// Double-click dragging moves the selection one "word" at a time.
fn dragLeftClickDouble(
    self: *Surface,
    screen_point: terminal.point.ScreenPoint,
) void {
    // Get the word under our current point. If there isn't a word, do nothing.
    const word = self.io.terminal.screen.selectWord(screen_point) orelse return;

    // Get our selection to grow it. If we don't have a selection, start it now.
    // We may not have a selection if we started our dbl-click in an area
    // that had no data, then we dragged our mouse into an area with data.
    var sel = self.io.terminal.screen.selectWord(self.mouse.left_click_point) orelse {
        self.io.terminal.selection = word;
        return;
    };

    // Grow our selection
    if (screen_point.before(self.mouse.left_click_point)) {
        sel.start = word.start;
    } else {
        sel.end = word.end;
    }
    self.io.terminal.selection = sel;
}

/// Triple-click dragging moves the selection one "line" at a time.
fn dragLeftClickTriple(
    self: *Surface,
    screen_point: terminal.point.ScreenPoint,
) void {
    // Get the word under our current point. If there isn't a word, do nothing.
    const word = self.io.terminal.screen.selectLine(screen_point) orelse return;

    // Get our selection to grow it. If we don't have a selection, start it now.
    // We may not have a selection if we started our dbl-click in an area
    // that had no data, then we dragged our mouse into an area with data.
    var sel = self.io.terminal.screen.selectLine(self.mouse.left_click_point) orelse {
        self.io.terminal.selection = word;
        return;
    };

    // Grow our selection
    if (screen_point.before(self.mouse.left_click_point)) {
        sel.start = word.start;
    } else {
        sel.end = word.end;
    }
    self.io.terminal.selection = sel;
}

fn dragLeftClickSingle(
    self: *Surface,
    screen_point: terminal.point.ScreenPoint,
    xpos: f64,
) void {
    // NOTE(mitchellh): This logic super sucks. There has to be an easier way
    // to calculate this, but this is good for a v1. Selection isn't THAT
    // common so its not like this performance heavy code is running that
    // often.
    // TODO: unit test this, this logic sucks

    // If we were selecting, and we switched directions, then we restart
    // calculations because it forces us to reconsider if the first cell is
    // selected.
    if (self.io.terminal.selection) |sel| {
        const reset: bool = if (sel.end.before(sel.start))
            sel.start.before(screen_point)
        else
            screen_point.before(sel.start);

        if (reset) self.io.terminal.selection = null;
    }

    // Our logic for determing if the starting cell is selected:
    //
    //   - The "xboundary" is 60% the width of a cell from the left. We choose
    //     60% somewhat arbitrarily based on feeling.
    //   - If we started our click left of xboundary, backwards selections
    //     can NEVER select the current char.
    //   - If we started our click right of xboundary, backwards selections
    //     ALWAYS selected the current char, but we must move the cursor
    //     left of the xboundary.
    //   - Inverted logic for forwards selections.
    //

    // the boundary point at which we consider selection or non-selection
    const cell_xboundary = self.cell_size.width * 0.6;

    // first xpos of the clicked cell
    const cell_xstart = @intToFloat(f32, self.mouse.left_click_point.x) * self.cell_size.width;
    const cell_start_xpos = self.mouse.left_click_xpos - cell_xstart;

    // If this is the same cell, then we only start the selection if weve
    // moved past the boundary point the opposite direction from where we
    // started.
    if (std.meta.eql(screen_point, self.mouse.left_click_point)) {
        const cell_xpos = xpos - cell_xstart;
        const selected: bool = if (cell_start_xpos < cell_xboundary)
            cell_xpos >= cell_xboundary
        else
            cell_xpos < cell_xboundary;

        self.io.terminal.selection = if (selected) .{
            .start = screen_point,
            .end = screen_point,
        } else null;

        return;
    }

    // If this is a different cell and we haven't started selection,
    // we determine the starting cell first.
    if (self.io.terminal.selection == null) {
        //   - If we're moving to a point before the start, then we select
        //     the starting cell if we started after the boundary, else
        //     we start selection of the prior cell.
        //   - Inverse logic for a point after the start.
        const click_point = self.mouse.left_click_point;
        const start: terminal.point.ScreenPoint = if (screen_point.before(click_point)) start: {
            if (self.mouse.left_click_xpos > cell_xboundary) {
                break :start click_point;
            } else {
                break :start if (click_point.x > 0) terminal.point.ScreenPoint{
                    .y = click_point.y,
                    .x = click_point.x - 1,
                } else terminal.point.ScreenPoint{
                    .x = self.io.terminal.screen.cols - 1,
                    .y = click_point.y -| 1,
                };
            }
        } else start: {
            if (self.mouse.left_click_xpos < cell_xboundary) {
                break :start click_point;
            } else {
                break :start if (click_point.x < self.io.terminal.screen.cols - 1) terminal.point.ScreenPoint{
                    .y = click_point.y,
                    .x = click_point.x + 1,
                } else terminal.point.ScreenPoint{
                    .y = click_point.y + 1,
                    .x = 0,
                };
            }
        };

        self.io.terminal.selection = .{ .start = start, .end = screen_point };
        return;
    }

    // TODO: detect if selection point is passed the point where we've
    // actually written data before and disallow it.

    // We moved! Set the selection end point. The start point should be
    // set earlier.
    assert(self.io.terminal.selection != null);
    self.io.terminal.selection.?.end = screen_point;
}

fn posToViewport(self: Surface, xpos: f64, ypos: f64) terminal.point.Viewport {
    // xpos and ypos can be negative if while dragging, the user moves the
    // mouse off the surface. Likewise, they can be larger than our surface
    // width if the user drags out of the surface positively.
    return .{
        .x = if (xpos < 0) 0 else x: {
            // Our cell is the mouse divided by cell width
            const cell_width = @floatCast(f64, self.cell_size.width);
            const x = @floatToInt(usize, xpos / cell_width);

            // Can be off the screen if the user drags it out, so max
            // it out on our available columns
            break :x @min(x, self.grid_size.columns - 1);
        },

        .y = if (ypos < 0) 0 else y: {
            const cell_height = @floatCast(f64, self.cell_size.height);
            const y = @floatToInt(usize, ypos / cell_height);
            break :y @min(y, self.grid_size.rows - 1);
        },
    };
}

const face_ttf = @embedFile("font/res/FiraCode-Regular.ttf");
const face_bold_ttf = @embedFile("font/res/FiraCode-Bold.ttf");
const face_emoji_ttf = @embedFile("font/res/NotoColorEmoji.ttf");
const face_emoji_text_ttf = @embedFile("font/res/NotoEmoji-Regular.ttf");