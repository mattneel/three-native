//! Event system types and key code mapping
//!
//! Provides event types and key code mapping for DOM event handling.
//! Event listener registration is handled in js.zig.

const std = @import("std");

// =============================================================================
// Event Types
// =============================================================================

pub const EventType = enum {
    // Mouse events
    mousedown,
    mouseup,
    mousemove,
    wheel,
    click,
    contextmenu,

    // Keyboard events
    keydown,
    keyup,

    // Window events
    resize,

    pub fn toString(self: EventType) [:0]const u8 {
        return switch (self) {
            .mousedown => "mousedown",
            .mouseup => "mouseup",
            .mousemove => "mousemove",
            .wheel => "wheel",
            .click => "click",
            .contextmenu => "contextmenu",
            .keydown => "keydown",
            .keyup => "keyup",
            .resize => "resize",
        };
    }

    pub fn fromString(s: []const u8) ?EventType {
        const map = std.StaticStringMap(EventType).initComptime(.{
            .{ "mousedown", .mousedown },
            .{ "mouseup", .mouseup },
            .{ "mousemove", .mousemove },
            .{ "wheel", .wheel },
            .{ "click", .click },
            .{ "contextmenu", .contextmenu },
            .{ "keydown", .keydown },
            .{ "keyup", .keyup },
            .{ "resize", .resize },
        });
        return map.get(s);
    }
};

// =============================================================================
// Mouse Event Data
// =============================================================================

pub const MouseEventData = struct {
    clientX: i32 = 0,
    clientY: i32 = 0,
    button: u8 = 0, // 0=left, 1=middle, 2=right
    buttons: u8 = 0, // Bitmask of pressed buttons
    shiftKey: bool = false,
    ctrlKey: bool = false,
    altKey: bool = false,
    metaKey: bool = false,
    deltaX: f32 = 0, // For wheel events
    deltaY: f32 = 0,
    deltaMode: u8 = 0, // 0=pixels, 1=lines, 2=pages
};

// =============================================================================
// Keyboard Event Data
// =============================================================================

pub const KeyboardEventData = struct {
    key: []const u8 = "",
    code: []const u8 = "",
    keyCode: u32 = 0,
    shiftKey: bool = false,
    ctrlKey: bool = false,
    altKey: bool = false,
    metaKey: bool = false,
    repeat: bool = false,
};

// =============================================================================
// Resize Event Data
// =============================================================================

pub const ResizeEventData = struct {
    width: u32 = 0,
    height: u32 = 0,
};

// =============================================================================
// Key Code Mapping (Sokol Keycode -> DOM keyCode)
// =============================================================================

pub fn sokolKeyCodeToDom(sokol_code: u32) u32 {
    // Map Sokol key codes to DOM key codes
    // Reference: https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/keyCode
    return switch (sokol_code) {
        // Letters A-Z (Sokol: 65-90, DOM: 65-90)
        65...90 => sokol_code,

        // Numbers 0-9 (Sokol: 48-57, DOM: 48-57)
        48...57 => sokol_code,

        // Function keys F1-F12 (Sokol: 290-301, DOM: 112-123)
        290...301 => sokol_code - 290 + 112,

        // Arrow keys
        262 => 39, // RIGHT
        263 => 37, // LEFT
        264 => 40, // DOWN
        265 => 38, // UP

        // Special keys
        256 => 27, // ESCAPE
        257 => 13, // ENTER
        258 => 9, // TAB
        259 => 8, // BACKSPACE
        260 => 45, // INSERT
        261 => 46, // DELETE
        266 => 33, // PAGE_UP
        267 => 34, // PAGE_DOWN
        268 => 36, // HOME
        269 => 35, // END

        // Modifiers
        340, 344 => 16, // SHIFT (LEFT/RIGHT)
        341, 345 => 17, // CTRL (LEFT/RIGHT)
        342, 346 => 18, // ALT (LEFT/RIGHT)
        343, 347 => 91, // SUPER/META (LEFT/RIGHT)

        // Space
        32 => 32,

        else => sokol_code,
    };
}

pub fn sokolKeyCodeToKey(sokol_code: u32, shift: bool) []const u8 {
    // Map Sokol key codes to DOM key strings
    return switch (sokol_code) {
        // Letters
        65 => if (shift) "A" else "a",
        66 => if (shift) "B" else "b",
        67 => if (shift) "C" else "c",
        68 => if (shift) "D" else "d",
        69 => if (shift) "E" else "e",
        70 => if (shift) "F" else "f",
        71 => if (shift) "G" else "g",
        72 => if (shift) "H" else "h",
        73 => if (shift) "I" else "i",
        74 => if (shift) "J" else "j",
        75 => if (shift) "K" else "k",
        76 => if (shift) "L" else "l",
        77 => if (shift) "M" else "m",
        78 => if (shift) "N" else "n",
        79 => if (shift) "O" else "o",
        80 => if (shift) "P" else "p",
        81 => if (shift) "Q" else "q",
        82 => if (shift) "R" else "r",
        83 => if (shift) "S" else "s",
        84 => if (shift) "T" else "t",
        85 => if (shift) "U" else "u",
        86 => if (shift) "V" else "v",
        87 => if (shift) "W" else "w",
        88 => if (shift) "X" else "x",
        89 => if (shift) "Y" else "y",
        90 => if (shift) "Z" else "z",

        // Numbers
        48 => if (shift) ")" else "0",
        49 => if (shift) "!" else "1",
        50 => if (shift) "@" else "2",
        51 => if (shift) "#" else "3",
        52 => if (shift) "$" else "4",
        53 => if (shift) "%" else "5",
        54 => if (shift) "^" else "6",
        55 => if (shift) "&" else "7",
        56 => if (shift) "*" else "8",
        57 => if (shift) "(" else "9",

        // Special keys
        256 => "Escape",
        257 => "Enter",
        258 => "Tab",
        259 => "Backspace",
        260 => "Insert",
        261 => "Delete",
        262 => "ArrowRight",
        263 => "ArrowLeft",
        264 => "ArrowDown",
        265 => "ArrowUp",
        266 => "PageUp",
        267 => "PageDown",
        268 => "Home",
        269 => "End",
        32 => " ",

        // Modifiers
        340, 344 => "Shift",
        341, 345 => "Control",
        342, 346 => "Alt",
        343, 347 => "Meta",

        else => "",
    };
}

pub fn sokolKeyCodeToCode(sokol_code: u32) []const u8 {
    // Map Sokol key codes to DOM code strings
    return switch (sokol_code) {
        65 => "KeyA", 66 => "KeyB", 67 => "KeyC", 68 => "KeyD", 69 => "KeyE",
        70 => "KeyF", 71 => "KeyG", 72 => "KeyH", 73 => "KeyI", 74 => "KeyJ",
        75 => "KeyK", 76 => "KeyL", 77 => "KeyM", 78 => "KeyN", 79 => "KeyO",
        80 => "KeyP", 81 => "KeyQ", 82 => "KeyR", 83 => "KeyS", 84 => "KeyT",
        85 => "KeyU", 86 => "KeyV", 87 => "KeyW", 88 => "KeyX", 89 => "KeyY",
        90 => "KeyZ",

        48 => "Digit0", 49 => "Digit1", 50 => "Digit2", 51 => "Digit3", 52 => "Digit4",
        53 => "Digit5", 54 => "Digit6", 55 => "Digit7", 56 => "Digit8", 57 => "Digit9",

        256 => "Escape",
        257 => "Enter",
        258 => "Tab",
        259 => "Backspace",
        260 => "Insert",
        261 => "Delete",
        262 => "ArrowRight",
        263 => "ArrowLeft",
        264 => "ArrowDown",
        265 => "ArrowUp",
        266 => "PageUp",
        267 => "PageDown",
        268 => "Home",
        269 => "End",
        32 => "Space",

        340 => "ShiftLeft",
        344 => "ShiftRight",
        341 => "ControlLeft",
        345 => "ControlRight",
        342 => "AltLeft",
        346 => "AltRight",
        343 => "MetaLeft",
        347 => "MetaRight",

        else => "",
    };
}

// =============================================================================
// Tests
// =============================================================================

test "EventType fromString" {
    const testing = std.testing;
    try testing.expectEqual(EventType.mousedown, EventType.fromString("mousedown").?);
    try testing.expectEqual(EventType.keyup, EventType.fromString("keyup").?);
    try testing.expect(EventType.fromString("invalid") == null);
}

test "sokolKeyCodeToDom mapping" {
    const testing = std.testing;
    // Letters should map 1:1
    try testing.expectEqual(@as(u32, 65), sokolKeyCodeToDom(65));
    // Arrow keys
    try testing.expectEqual(@as(u32, 37), sokolKeyCodeToDom(263)); // LEFT
    try testing.expectEqual(@as(u32, 38), sokolKeyCodeToDom(265)); // UP
    try testing.expectEqual(@as(u32, 39), sokolKeyCodeToDom(262)); // RIGHT
    try testing.expectEqual(@as(u32, 40), sokolKeyCodeToDom(264)); // DOWN
    // Escape
    try testing.expectEqual(@as(u32, 27), sokolKeyCodeToDom(256));
}
