//! A tool call, read out of the ACP update that announced it.
//!
//! An agent announces work as JSON: a title, a status, a kind, `locations`,
//! `rawInput`, `rawOutput`, and content parts that are either text or the two
//! sides of an edit. An interface wants none of that. It wants a chip: a kind,
//! a state, one line a reader scans, a few fields behind it, and a diff it can
//! colour. This is the reader between the two, and it has one rule - nothing
//! JSON-shaped reaches the interface. A field is `path` / `src/app.zig`, never
//! a key and its escaped value, and nothing is unbounded either: an update past
//! `max_update_bytes` or `max_parts` is refused by name, and a value that does
//! not fit keeps its first line and says how many bytes it left out.
//!
//! A call is not a message in the transcript, it is a record with an offset
//! into it: `at` says where the chip belongs, and `merge` is what keeps that
//! offset across the updates a call arrives in.

const std = @import("std");
const diff = @import("../ui/diff.zig");
const rpc = @import("protocol.zig");
const Allocator = std.mem.Allocator;

/// The work a call is doing, which is what its chip is labelled with. `other`
/// is a call whose kind this does not recognise, not a call without one.
pub const Kind = enum { read, edit, delete, move, search, execute, think, fetch, switch_mode, other };

/// Where a call has got to. These are the four states ACP names.
pub const State = enum {
    pending,
    in_progress,
    completed,
    failed,

    /// Whether the call has stopped moving. `merge` asks before it lets an
    /// unnamed state through, because a finished call must not be dragged back
    /// to pending by an update that only reports something else.
    pub fn finished(self: State) bool {
        return switch (self) {
            .completed, .failed => true,
            .pending, .in_progress => false,
        };
    }
};

/// One labelled piece of a call's detail, already semantic: a field is
/// `path` / `src/app.zig`, not a JSON key and its escaped value.
pub const Field = struct { label: []const u8, value: []const u8 };

/// One call, as the interface draws it: the kind and the state on the chip, the
/// subject on its closed line, and the fields behind it.
pub const ToolCall = struct {
    /// The agent's id for the call, so an update finds the record it belongs
    /// to. It arrives as `toolCallId`.
    id: []const u8,
    /// What the agent called the call.
    title: []const u8,
    kind: Kind,
    state: State,
    /// The one line a reader scans: a path, a command, a query, or a URL.
    subject: []const u8,
    fields: []const Field,
    /// A unified diff the call carries, when it carries one.
    diff: ?[]const u8,
    /// Where in the transcript bytes this call belongs: the offset the call
    /// arrived at. `merge` keeps the first one it saw, so a chip does not slide
    /// down the transcript as the call progresses.
    at: usize,
};

/// The most bytes one update may carry. Past this the call is refused rather
/// than read, because the point of the reader is that a call is a summary and a
/// megabyte of JSON is not one.
pub const max_update_bytes: usize = 1 << 20;

/// The most content parts one update may carry. A call with more parts than
/// this is a stream, not a call.
pub const max_parts: usize = 64;

/// The most fields a chip opens to. A reader opening a chip wants the handful
/// of things the call is about, not everything the agent knew.
pub const max_fields: usize = 8;

/// The most bytes one field value may take. A file body pasted into a field is
/// the dump this reader exists to replace, so a longer value keeps its first
/// line and says how many bytes it left out.
pub const max_value_bytes: usize = 512;

/// The most bytes the title and the subject may take: these are the lines on
/// the chip itself, and a line stops being one long before a field does.
pub const max_line_bytes: usize = 200;

/// The most bytes a field label may take, for the labels that are a raw key.
pub const max_label_bytes: usize = 48;

/// The most calls a client keeps. A session can run for hours, and a list that
/// only grows is a leak in slow motion; the oldest call goes first.
pub const max_calls: usize = 512;

/// Read one ACP `tool_call` or `tool_call_update` into the record an interface
/// draws. Everything returned belongs to `a`, labels and values included; give
/// it back with `deinit`.
///
/// `at` is left at zero, because where a call belongs in the transcript is the
/// client's to know and is the one thing an update never changes.
///
/// Errors are `error.MalformedToolCall` for an update that is not the object
/// this reads, `error.ToolCallTooLarge` past `max_update_bytes`, and
/// `error.TooManyParts` past `max_parts`.
pub fn parse(a: Allocator, update: std.json.Value) !ToolCall {
    if (update != .object) return error.MalformedToolCall;
    if (carriedBytes(update) > max_update_bytes) return error.ToolCallTooLarge;

    // The reading is scaffolding: what is built while looking around lives in a
    // scratch arena, and only the record survives this function.
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const temp = scratch.allocator();

    const id = optional(update, "toolCallId") orelse "";
    const title = optional(update, "title") orelse "";
    const named_kind = optional(update, "kind") orelse "";
    // An update often carries no kind: it is the same call, and its title is
    // where the words for it are.
    const kind: Kind = if (named_kind.len != 0) kindOf(named_kind) else kindOf(title);
    const state = stateOf(optional(update, "status") orelse "");

    var reading = Reading{};
    // A location is the agent saying where it is working, which is the line a
    // reader scans for everything that touches a file.
    if (rpc.field(update, "locations")) |locations| reading.readLocations(locations);
    if (rpc.field(update, "content")) |parts| {
        if (parts != .array) return error.MalformedToolCall;
        if (parts.array.items.len > max_parts) return error.TooManyParts;
        for (parts.array.items) |part| try reading.readPart(temp, part);
    }
    const input = rpc.field(update, "rawInput");
    const output = rpc.field(update, "rawOutput");
    if (input) |value| try reading.readInput(temp, value);
    if (output) |value| try reading.readOutput(temp, value);
    // A tool's own result: what it returned is the text it wrote, unless it
    // named a field of its own for it.
    if (reading.output.len == 0) reading.output = reading.text.items;
    // The `oldText`/`newText` pair some agents put in `rawInput` is the change a
    // diff content part carries, spelled differently.
    if (kind == .edit and reading.diff.items.len == 0) {
        if (input) |value| {
            const old = textField(value, &.{ "oldText", "old_text", "old_string", "old_str" }) orelse "";
            const new = textField(value, &.{ "newText", "new_text", "new_string", "new_str", "content", "content_text" }) orelse "";
            if (old.len != 0 or new.len != 0) try writeDiff(temp, &reading.diff, reading.path, old, new);
        }
    }
    // An edit whose result arrives as text - a patch pasted into content rather
    // than sent as a diff part - is still a change worth showing as a diff.
    if (kind == .edit and reading.diff.items.len == 0 and reading.text_diff.len != 0) {
        try appendSection(temp, &reading.diff, reading.text_diff);
    }

    var fields = Fields{ .a = temp };
    if (rpc.field(update, "locations")) |locations| try fields.readLocations(locations);
    try fields.forKind(kind, &reading);
    if (input) |value| try fields.readKeys(value);
    if (output) |value| try fields.readKeys(value);

    // The record owns what it keeps; the scratch arena dies with this call.
    var call: ToolCall = .{
        .id = try bounded(a, id, max_value_bytes),
        .title = &.{},
        .kind = kind,
        .state = state,
        .subject = &.{},
        .fields = &.{},
        .diff = null,
        .at = 0,
    };
    errdefer deinit(&call, a);
    call.title = try bounded(a, title, max_line_bytes);
    call.subject = try bounded(a, subjectOf(kind, &reading, title), max_line_bytes);
    if (reading.diff.items.len != 0) call.diff = try a.dupe(u8, reading.diff.items);
    var owned: std.ArrayList(Field) = .empty;
    errdefer {
        for (owned.items) |field| freeField(field, a);
        owned.deinit(a);
    }
    for (fields.list.items) |field| {
        const label = try a.dupe(u8, field.label);
        errdefer a.free(label);
        const value = try a.dupe(u8, field.value);
        errdefer a.free(value);
        try owned.append(a, .{ .label = label, .value = value });
    }
    call.fields = try owned.toOwnedSlice(a);
    return call;
}

/// Release a record: every slice `parse` handed back is freed, labels and
/// values included, and the record is emptied as it goes, so releasing one
/// twice is a no-op rather than a fault.
pub fn deinit(call: *ToolCall, a: Allocator) void {
    a.free(call.id);
    a.free(call.title);
    a.free(call.subject);
    for (call.fields) |field| freeField(field, a);
    if (call.fields.len != 0) a.free(call.fields);
    if (call.diff) |text| a.free(text);
    call.* = .{
        .id = &.{},
        .title = &.{},
        .kind = .other,
        .state = .pending,
        .subject = &.{},
        .fields = &.{},
        .diff = null,
        .at = 0,
    };
}

/// Fold `parsed` into `calls`: a call already stored with the same id is
/// replaced in place, and anything else is appended.
///
/// An update is partial, so the parts of the record it does not carry are the
/// parts the call already answered, and the stored ones stand - which is what
/// keeps a call that goes from pending to completed showing the path, the title
/// and the kind it started with. The offset `at` is always the stored one. The
/// fields are the exception to replacing: what the update brought is added to
/// what the chip already showed, because an update that only carries a result
/// must not drop the command the chip was opened for.
///
/// The list is bounded by `max_calls`, oldest first, so a long session cannot
/// grow without bound.
///
/// On success `merge` takes ownership of `parsed`. On failure - the allocator
/// giving up - nothing has moved: the list is unchanged and `parsed` is still
/// the caller's to release.
pub fn merge(calls: *std.ArrayList(ToolCall), a: Allocator, parsed: ToolCall) !void {
    if (parsed.id.len != 0) {
        for (calls.items) |*stored| {
            if (!std.mem.eql(u8, stored.id, parsed.id)) continue;
            var next = parsed;
            // The fields are one list, so the two are laid out together on the
            // stack first and allocated in one go: the only fallible step
            // happens while both records are still whole, and a failure then
            // leaves the stored record as it was.
            const layout = layOutFields(stored.fields, next.fields);
            const combined: []Field = if (layout.used == 0) &.{} else a.alloc(Field, layout.used) catch |err| return err;
            @memcpy(combined, layout.fields[0..layout.used]);
            // Ownership moves now, and nothing below can fail. What the layout
            // did not hold is released here: a value the update replaced, and a
            // field the bound had no room for.
            for (next.fields, 0..) |field, index| {
                if (!layout.fresh_kept[index]) freeField(field, a);
            }
            for (stored.fields, 0..) |field, index| {
                if (!layout.stored_kept[index]) freeField(field, a);
            }
            if (next.fields.len != 0) a.free(next.fields);
            if (stored.fields.len != 0) a.free(stored.fields);
            next.fields = combined;
            stored.fields = &.{};
            // For the rest of the record the update replaces what it carries
            // and the stored value stands where it does not. Moving the kept
            // slices out of the stored record is what leaves one `deinit`
            // releasing exactly the parts the update dropped.
            next.at = stored.at;
            if (next.id.len == 0) {
                next.id = stored.id;
                stored.id = &.{};
            }
            if (next.title.len == 0) {
                next.title = stored.title;
                stored.title = &.{};
            }
            if (next.subject.len == 0) {
                next.subject = stored.subject;
                stored.subject = &.{};
            }
            if (next.diff == null) {
                next.diff = stored.diff;
                stored.diff = null;
            }
            if (next.kind == .other) next.kind = stored.kind;
            if (next.state == .pending and stored.state.finished()) next.state = stored.state;
            deinit(stored, a);
            stored.* = next;
            return;
        }
    }
    // The list is grown before the oldest is dropped, so a full list that
    // cannot take one more is left as it was.
    try calls.append(a, parsed);
    if (calls.items.len > max_calls) {
        var oldest = calls.orderedRemove(0);
        deinit(&oldest, a);
    }
}

/// Move every recorded offset up by the bytes that just left the front of the
/// transcript. A transcript is bounded by dropping what is oldest in it, and a
/// recorded offset is a position in those same bytes: leave it alone and a long
/// transcript puts old chips on the wrong line. Offsets that were already at or
/// before the drop land at zero, which is the front, where they belong.
pub fn shiftAt(calls: []ToolCall, dropped: usize) void {
    for (calls) |*call| call.at = call.at -| dropped;
}

/// The kind a name stands for. The ACP vocabulary is matched whole, and a name
/// that carries other words - a tool an agent titled "Read file", or a kind it
/// spelled "file_read" - is matched word by word, because that is all an
/// agent's name for a call is: words.
pub fn kindOf(text: []const u8) Kind {
    var words = std.mem.tokenizeAny(u8, text, word_separators);
    while (words.next()) |word| {
        if (kindOfWord(word)) |kind| return kind;
    }
    return .other;
}

/// The state a status names. A status this does not recognise, or none at all,
/// is `.pending`: the state a call starts in and the only one that claims
/// nothing happened. A cancelled call reads as failed, because the vocabulary
/// has no third ending and calling it pending would leave it looking unfinished
/// forever.
pub fn stateOf(text: []const u8) State {
    if (std.ascii.eqlIgnoreCase(text, "pending")) return .pending;
    if (std.ascii.eqlIgnoreCase(text, "in_progress") or
        std.ascii.eqlIgnoreCase(text, "in-progress") or
        std.ascii.eqlIgnoreCase(text, "working") or
        std.ascii.eqlIgnoreCase(text, "running")) return .in_progress;
    if (std.ascii.eqlIgnoreCase(text, "completed") or
        std.ascii.eqlIgnoreCase(text, "complete") or
        std.ascii.eqlIgnoreCase(text, "done") or
        std.ascii.eqlIgnoreCase(text, "success") or
        std.ascii.eqlIgnoreCase(text, "succeeded")) return .completed;
    if (std.ascii.eqlIgnoreCase(text, "failed") or
        std.ascii.eqlIgnoreCase(text, "fail") or
        std.ascii.eqlIgnoreCase(text, "error") or
        std.ascii.eqlIgnoreCase(text, "cancelled") or
        std.ascii.eqlIgnoreCase(text, "canceled")) return .failed;
    return .pending;
}

/// The words a name is split on before it is matched against the vocabulary.
const word_separators = " \t\r\n_-./:,;()[]{}\"'`*";

/// One word of a name, matched against the vocabulary. Case is not part of it:
/// an agent writes `read`, `Read`, and `READ` for the same tool.
fn kindOfWord(word: []const u8) ?Kind {
    const vocabulary = .{
        .{ "read", Kind.read },          .{ "view", Kind.read },
        .{ "open", Kind.read },          .{ "cat", Kind.read },
        .{ "edit", Kind.edit },          .{ "write", Kind.edit },
        .{ "create", Kind.edit },        .{ "replace", Kind.edit },
        .{ "patch", Kind.edit },         .{ "insert", Kind.edit },
        .{ "modify", Kind.edit },        .{ "delete", Kind.delete },
        .{ "remove", Kind.delete },      .{ "rm", Kind.delete },
        .{ "unlink", Kind.delete },      .{ "move", Kind.move },
        .{ "rename", Kind.move },        .{ "mv", Kind.move },
        .{ "search", Kind.search },      .{ "grep", Kind.search },
        .{ "glob", Kind.search },        .{ "find", Kind.search },
        .{ "query", Kind.search },       .{ "execute", Kind.execute },
        .{ "exec", Kind.execute },       .{ "bash", Kind.execute },
        .{ "shell", Kind.execute },      .{ "run", Kind.execute },
        .{ "command", Kind.execute },    .{ "cmd", Kind.execute },
        .{ "terminal", Kind.execute },   .{ "think", Kind.think },
        .{ "thought", Kind.think },      .{ "reason", Kind.think },
        .{ "reasoning", Kind.think },    .{ "fetch", Kind.fetch },
        .{ "webfetch", Kind.fetch },     .{ "http", Kind.fetch },
        .{ "https", Kind.fetch },        .{ "url", Kind.fetch },
        .{ "download", Kind.fetch },     .{ "curl", Kind.fetch },
        .{ "browse", Kind.fetch },       .{ "web", Kind.fetch },
        .{ "switch", Kind.switch_mode }, .{ "mode", Kind.switch_mode },
    };
    inline for (vocabulary) |entry| {
        if (std.ascii.eqlIgnoreCase(word, entry[0])) return entry[1];
    }
    return null;
}

/// The one line a reader scans, chosen by kind: the useful line is a different
/// thing for a command, a path, and a query. The title is the fallback rather
/// than the answer, because an agent's title is often the same for every call
/// of a tool, and the first line of what a call said is still better than a
/// blank chip.
fn subjectOf(kind: Kind, reading: *const Reading, title: []const u8) []const u8 {
    const named: []const u8 = switch (kind) {
        .read, .edit, .delete, .move => reading.path,
        .execute => reading.command,
        .search => reading.query,
        .fetch => reading.url,
        .think => firstLine(reading.first_text),
        .switch_mode => reading.mode,
        .other => "",
    };
    if (named.len != 0) return named;
    if (title.len != 0) return title;
    return firstLine(reading.first_text);
}

/// The first line of a value, without the line ending.
fn firstLine(text: []const u8) []const u8 {
    const stop = std.mem.indexOfScalar(u8, text, '\n') orelse return text;
    const line = text[0..stop];
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

/// A value no longer than `limit`, with what was left out said out loud. A
/// multi-line value keeps its first line: the rest of a file body in a chip is
/// the dump this replaces. Nothing is quiet about the cut, because a reader who
/// cannot see that a value continues reads a truncation as the value.
fn bounded(a: Allocator, text: []const u8, limit: usize) ![]u8 {
    // A value that ends in a newline is the same value without it, and the note
    // is about content rather than about line endings.
    const value = std.mem.trimEnd(u8, text, "\r\n");
    if (value.len == 0) return &.{};
    const line = firstLine(value);
    var cut = @min(line.len, limit);
    // Never cut a character in half: the next byte starts one.
    while (cut < line.len and line[cut] & 0xc0 == 0x80) : (cut += 1) {}
    const shown = line[0..cut];
    if (shown.len == value.len) return a.dupe(u8, value);
    return std.fmt.allocPrint(a, "{s} … ({d} bytes omitted)", .{ shown, value.len - shown.len });
}

fn freeField(field: Field, a: Allocator) void {
    a.free(field.label);
    a.free(field.value);
}

/// The string a key holds, or null when it holds something else or nothing.
fn optional(value: std.json.Value, key: []const u8) ?[]const u8 {
    return rpc.string(rpc.field(value, key) orelse return null);
}

/// The first of `keys` that holds a non-empty string.
fn textField(value: std.json.Value, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (optional(value, key)) |text| if (text.len != 0) return text;
    }
    return null;
}

/// A value as the text of a field. Strings are themselves; numbers and booleans
/// are written out; a nested array or object is written as compact JSON,
/// because a field with no name for its shape is still better than no field and
/// the bound on the value keeps it a field rather than a dump.
fn textOf(a: Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        .bool => |flag| if (flag) "true" else "false",
        .integer => |number| try std.fmt.allocPrint(a, "{d}", .{number}),
        .float => |number| try std.fmt.allocPrint(a, "{d}", .{number}),
        .number_string => |text| text,
        .null => "",
        .array, .object => try std.json.Stringify.valueAlloc(a, value, .{}),
    };
}

/// The bytes an update carries: every string in it, summed, with the keys of an
/// object counting too. Counting rather than serialising is what lets a call
/// this large be refused without allocating it first, and the walk is
/// depth-limited because the tree comes from the wire.
fn carriedBytes(value: std.json.Value) usize {
    var total: usize = 0;
    countBytes(value, walk_depth, &total);
    return total;
}

/// How deep into an update the size walk goes. A call is an object of scalars
/// and one array of parts; anything past this is not a shape this reads, and
/// the bound keeps the walk finite whatever arrives.
const walk_depth = 16;

fn countBytes(value: std.json.Value, depth: usize, total: *usize) void {
    if (depth == 0 or total.* > max_update_bytes) return;
    switch (value) {
        .string => |text| total.* += text.len,
        .array => |items| for (items.items) |item| countBytes(item, depth - 1, total),
        .object => |entries| {
            var it = entries.iterator();
            while (it.next()) |entry| {
                total.* += entry.key_ptr.len;
                countBytes(entry.value_ptr.*, depth - 1, total);
            }
        },
        else => {},
    }
}

/// What the parser noticed while reading, before any of it becomes a record.
/// The slices borrow the update (or the scratch arena for what is built), and
/// every value is raw: the bound is applied where one becomes a subject or a
/// field, so a value that is too long is cut once, at the place it is shown.
const Reading = struct {
    path: []const u8 = "",
    command: []const u8 = "",
    query: []const u8 = "",
    url: []const u8 = "",
    directory: []const u8 = "",
    mode: []const u8 = "",
    matches: []const u8 = "",
    exit_code: []const u8 = "",
    output: []const u8 = "",
    first_text: []const u8 = "",
    text_diff: []const u8 = "",
    text: std.ArrayList(u8) = .empty,
    diff: std.ArrayList(u8) = .empty,

    /// The first path a call says it is touching. A location's line is a field
    /// rather than part of the subject: the subject is where the call is, and
    /// the line is where in it the reader would jump.
    fn readLocations(self: *Reading, locations: std.json.Value) void {
        if (locations != .array) return;
        for (locations.array.items) |location| {
            const path = rpc.str(location, "path");
            if (path.len != 0) {
                self.path = path;
                return;
            }
        }
    }

    /// One content part: the two sides of an edit, the text a tool wrote, or a
    /// diff it printed.
    fn readPart(self: *Reading, a: Allocator, part: std.json.Value) !void {
        if (std.mem.eql(u8, rpc.str(part, "type"), "diff")) {
            const path = rpc.str(part, "path");
            if (self.path.len == 0 and path.len != 0) self.path = path;
            // A diff the agent wrote out is used as it is; the two sides are
            // written out as one, because the shape the transcript reads - and
            // the shape a reader of diffs recognises - is a unified diff.
            if (textField(part, &.{ "diff", "patch", "unified" })) |ready| {
                return appendSection(a, &self.diff, ready);
            }
            const old = textField(part, &.{ "oldText", "old_text" }) orelse "";
            const new = textField(part, &.{ "newText", "new_text" }) orelse "";
            if (old.len == 0 and new.len == 0) return;
            return writeDiff(a, &self.diff, path, old, new);
        }
        const text = partText(part);
        if (text.len == 0) return;
        if (self.first_text.len == 0) self.first_text = text;
        if (self.text.items.len != 0) try self.text.append(a, '\n');
        try self.text.appendSlice(a, text);
        if (self.text_diff.len == 0 and diff.looksLikeDiff(text)) self.text_diff = text;
    }

    /// `rawInput` is the tool's own arguments, so the keys are the tool's: the
    /// ones this knows are read for the subject, and the rest become fields
    /// under their own names.
    fn readInput(self: *Reading, a: Allocator, input: std.json.Value) !void {
        if (input != .object) {
            // Some agents send the input as one string: a command, in practice.
            if (rpc.string(input)) |text| {
                if (self.command.len == 0) self.command = text;
            }
            return;
        }
        if (self.path.len == 0) self.path = textField(input, path_keys) orelse "";
        if (self.query.len == 0) self.query = textField(input, query_keys) orelse "";
        if (self.url.len == 0) self.url = textField(input, url_keys) orelse "";
        if (self.directory.len == 0) self.directory = textField(input, directory_keys) orelse "";
        if (self.mode.len == 0) self.mode = textField(input, mode_keys) orelse "";
        if (self.command.len != 0) return;
        if (rpc.field(input, "command")) |value| {
            switch (value) {
                .string => |text| if (text.len != 0) {
                    self.command = try withArgs(a, text, rpc.field(input, "args") orelse rpc.field(input, "arguments"));
                },
                // An argv sent whole is the command line a reader wants, and
                // joining it is the only way it reads as one.
                .array => |items| self.command = try joinArgv(a, items.items),
                else => {},
            }
            if (self.command.len != 0) return;
        }
        self.command = textField(input, &.{ "cmd", "script" }) orelse "";
    }

    /// `rawOutput` is what the tool reported: the exit code a reader looks for
    /// first, the count a search found, and the text it wrote under whatever
    /// name the tool uses for it.
    fn readOutput(self: *Reading, a: Allocator, output: std.json.Value) !void {
        if (rpc.string(output)) |text| {
            if (self.output.len == 0) self.output = text;
            return;
        }
        if (output != .object) return;
        if (self.exit_code.len == 0) {
            if (rpc.field(output, exit_keys[0]) orelse rpc.field(output, exit_keys[1])) |value| {
                self.exit_code = try textOf(a, value);
            }
        }
        if (self.matches.len == 0) {
            if (fieldNumber(output, matches_keys)) |value| self.matches = try textOf(a, value);
        }
        if (self.output.len == 0) self.output = textField(output, output_keys) orelse "";
    }
};

/// The keys of `rawInput` this knows by name. A key that is not here is still
/// read: it becomes a field under its own name, which is the tool's word for
/// the thing.
const path_keys: []const []const u8 = &.{ "path", "file_path", "filePath", "file", "target_file", "absolute_path" };
const query_keys: []const []const u8 = &.{ "query", "pattern", "regex", "glob", "search" };
const url_keys: []const []const u8 = &.{ "url", "uri", "href", "link" };
const directory_keys: []const []const u8 = &.{ "cwd", "workdir", "working_directory", "directory" };
const mode_keys: []const []const u8 = &.{ "mode", "modeId", "mode_id" };
const exit_keys: []const []const u8 = &.{ "exitCode", "exit_code" };
const matches_keys: []const []const u8 = &.{ "matches", "count", "total", "numResults" };
const output_keys: []const []const u8 = &.{ "output", "stdout", "result", "text" };

/// The text of a content part, whatever shape the agent hung it on. ACP writes
/// `{type:"content", content:{type:"text", text}}`; an agent that writes the
/// text one level up is read all the same.
fn partText(part: std.json.Value) []const u8 {
    if (rpc.field(part, "content")) |inner| {
        if (rpc.string(inner)) |text| return text;
        const shape = rpc.str(inner, "type");
        if (shape.len == 0 or std.mem.eql(u8, shape, "text")) return rpc.str(inner, "text");
        return "";
    }
    if (std.mem.eql(u8, rpc.str(part, "type"), "text")) return rpc.str(part, "text");
    return "";
}

/// A value with a "line" in it, whichever of ACP's two shapes it is: a location
/// carries the line directly, or a range whose start is a position.
fn lineText(a: Allocator, location: std.json.Value) !?[]const u8 {
    const value = rpc.field(location, "line") orelse found: {
        const range = rpc.field(location, "range") orelse return null;
        const start = rpc.field(range, "start") orelse return null;
        break :found rpc.field(start, "line") orelse return null;
    };
    if (value == .null) return null;
    const text = try textOf(a, value);
    return if (text.len == 0) null else text;
}

/// The number a key holds, whether the agent wrote it as a number or as a
/// string, because both are how a count arrives.
fn fieldNumber(value: std.json.Value, keys: []const []const u8) ?std.json.Value {
    for (keys) |key| {
        if (rpc.field(value, key)) |found| switch (found) {
            .integer, .float, .number_string => return found,
            else => {},
        };
    }
    return null;
}

/// A command with its arguments: the line a reader can paste back into a shell.
fn withArgs(a: Allocator, command: []const u8, args: ?std.json.Value) ![]const u8 {
    const value = args orelse return command;
    if (value != .array or value.array.items.len == 0) return command;
    const joined = try joinArgv(a, value.array.items);
    if (joined.len == 0) return command;
    return std.fmt.allocPrint(a, "{s} {s}", .{ command, joined });
}

/// An argv joined into one line. Anything that is not a scalar is skipped:
/// a nested shape in an argv is a description of an argument, not one.
fn joinArgv(a: Allocator, items: []const std.json.Value) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    for (items) |item| {
        const text = switch (item) {
            .string, .integer, .float, .number_string => try textOf(a, item),
            else => "",
        };
        if (text.len == 0) continue;
        if (joined.items.len != 0) try joined.append(a, ' ');
        try joined.appendSlice(a, text);
    }
    return joined.toOwnedSlice(a);
}

/// The fields a chip opens to, gathered before the record is built. Values are
/// bounded as they arrive, so the list is what a reader would see.
const Fields = struct {
    a: Allocator,
    list: std.ArrayList(Field) = .empty,

    /// Add one field. An empty value is nothing to show, a repeated label and
    /// value is the same thing said twice, and the list stops at `max_fields`.
    fn add(self: *Fields, label: []const u8, value: []const u8) !void {
        if (value.len == 0 or self.list.items.len == max_fields) return;
        const shown = try bounded(self.a, value, max_value_bytes);
        if (shown.len == 0) return;
        for (self.list.items) |field| {
            if (std.mem.eql(u8, field.label, label) and std.mem.eql(u8, field.value, shown)) return;
        }
        const word = if (label.len <= max_label_bytes) label else try bounded(self.a, label, max_label_bytes);
        try self.list.append(self.a, .{ .label = word, .value = shown });
    }

    /// Whether a label is already one of the fields, which is how a key that
    /// fed the reading is kept from being repeated as itself.
    fn holds(self: *const Fields, label: []const u8) bool {
        for (self.list.items) |field| {
            if (std.mem.eql(u8, field.label, label)) return true;
        }
        return false;
    }

    /// Where a call says it is touching: the path is what a reader wants, and
    /// the line turns the field into the one a reader jumps to.
    fn readLocations(self: *Fields, locations: std.json.Value) !void {
        if (locations != .array) return;
        for (locations.array.items) |location| {
            if (self.list.items.len == max_fields) return;
            try self.add("path", rpc.str(location, "path"));
            if (try lineText(self.a, location)) |line| try self.add("line", line);
        }
    }

    /// The fields a reader wants first, which differ by what the call is doing.
    /// Whatever the update did not name is simply absent.
    fn forKind(self: *Fields, kind: Kind, reading: *const Reading) !void {
        switch (kind) {
            .read, .edit, .delete, .move => try self.add("path", reading.path),
            .execute => {
                try self.add("command", reading.command);
                try self.add("directory", reading.directory);
                try self.add("exit code", reading.exit_code);
                try self.add("output", reading.output);
            },
            .search => {
                try self.add("query", reading.query);
                try self.add("path", reading.path);
                try self.add("matches", reading.matches);
                try self.add("output", reading.output);
            },
            .fetch => {
                try self.add("url", reading.url);
                try self.add("output", reading.output);
            },
            .think => try self.add("thought", reading.text.items),
            .switch_mode => try self.add("mode", reading.mode),
            .other => {
                try self.add("path", reading.path);
                try self.add("command", reading.command);
                try self.add("query", reading.query);
                try self.add("url", reading.url);
                try self.add("output", reading.output);
            },
        }
    }

    /// The rest of a tool's own arguments and results, under the name a reader
    /// would use for them. A key that fed the reading is not repeated, and the
    /// body of a file is never a field: it is what `diff` carries when the call
    /// is an edit, and a truncated file body is the dump this replaces.
    fn readKeys(self: *Fields, value: std.json.Value) !void {
        const entries = switch (value) {
            .object => |object| object,
            else => return,
        };
        var it = entries.iterator();
        while (it.next()) |entry| {
            const label = labelFor(entry.key_ptr.*);
            if (label.len == 0 or self.holds(label)) continue;
            try self.add(label, try textOf(self.a, entry.value_ptr.*));
        }
    }
};

/// The name a reader would use for a key of `rawInput` or `rawOutput`. An empty
/// answer means the key is not a field at all: a body of file text, or an argv
/// that is already part of the command line.
fn labelFor(key: []const u8) []const u8 {
    const known = .{
        .{ "path", "path" },             .{ "file_path", "path" },
        .{ "filePath", "path" },         .{ "file", "path" },
        .{ "target_file", "path" },      .{ "absolute_path", "path" },
        .{ "command", "command" },       .{ "cmd", "command" },
        .{ "script", "command" },        .{ "cwd", "directory" },
        .{ "workdir", "directory" },     .{ "working_directory", "directory" },
        .{ "directory", "directory" },   .{ "exitCode", "exit code" },
        .{ "exit_code", "exit code" },   .{ "code", "exit code" },
        .{ "status_code", "exit code" }, .{ "query", "query" },
        .{ "pattern", "query" },         .{ "regex", "query" },
        .{ "glob", "query" },            .{ "matches", "matches" },
        .{ "count", "matches" },         .{ "total", "matches" },
        .{ "numResults", "matches" },    .{ "url", "url" },
        .{ "uri", "url" },               .{ "href", "url" },
        .{ "output", "output" },         .{ "stdout", "output" },
        .{ "stderr", "output" },         .{ "result", "output" },
        .{ "offset", "offset" },         .{ "start_line", "offset" },
        .{ "limit", "limit" },           .{ "end_line", "limit" },
        .{ "mode", "mode" },             .{ "modeId", "mode" },
        .{ "error", "error" },           .{ "message", "message" },
        // Not fields: a body of file text, or an argument list that is already
        // part of the command line.
        .{ "args", "" },                 .{ "arguments", "" },
        .{ "content", "" },              .{ "text", "" },
        .{ "oldText", "" },              .{ "newText", "" },
        .{ "diff", "" },                 .{ "patch", "" },
        .{ "file_text", "" },            .{ "content_text", "" },
    };
    inline for (known) |entry| {
        if (std.mem.eql(u8, key, entry[0])) return entry[1];
    }
    return key;
}

/// Write one side of a change as a hunk body: every line of that side, marked.
/// The old side comes first and then the new one rather than interleaved,
/// because pairing a removed line with the added one that replaced it is a
/// guess, and a reader is better served by the two lists the diff reader
/// colours than by the guess.
fn writeDiff(a: Allocator, out: *std.ArrayList(u8), path: []const u8, old: []const u8, new: []const u8) !void {
    if (old.len == 0 and new.len == 0) return;
    if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
    try out.appendSlice(a, "--- ");
    try headPath(a, out, "a/", path);
    try out.append(a, '\n');
    try out.appendSlice(a, "+++ ");
    try headPath(a, out, "b/", path);
    try out.append(a, '\n');
    var header: [96]u8 = undefined;
    var old_range: [32]u8 = undefined;
    var new_range: [32]u8 = undefined;
    try out.appendSlice(a, try std.fmt.bufPrint(&header, "@@ -{s} +{s} @@\n", .{
        try rangeText(&old_range, countLines(old)),
        try rangeText(&new_range, countLines(new)),
    }));
    try appendSide(a, out, '-', old);
    try appendSide(a, out, '+', new);
}

/// Add a diff the agent wrote out to the ones a call carries. Sections are
/// separated by the newline that ends the previous one, because two diffs run
/// together are not readable as either.
fn appendSection(a: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    if (text.len == 0) return;
    if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
    try out.appendSlice(a, text);
    if (out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
}

/// A diff header path. A relative path takes the `a/` and `b/` prefixes a
/// unified diff carries, so the shape is the one every reader of diffs knows;
/// an absolute path is already unambiguous and is written as it is, because
/// `a//home/x` is not a path any tool prints.
fn headPath(a: Allocator, out: *std.ArrayList(u8), prefix: []const u8, path: []const u8) !void {
    if (path.len == 0) return out.appendSlice(a, "/dev/null");
    if (path[0] != '/') try out.appendSlice(a, prefix);
    try out.appendSlice(a, path);
}

/// A hunk range: line one to line N, or the empty side of a file being created
/// or deleted, which a unified diff writes as `0,0`.
fn rangeText(buffer: []u8, count: usize) ![]const u8 {
    return if (count == 0) "0,0" else std.fmt.bufPrint(buffer, "1,{d}", .{count});
}

fn appendSide(a: Allocator, out: *std.ArrayList(u8), marker: u8, text: []const u8) !void {
    var lines = LineReader{ .bytes = text };
    while (lines.next()) |line| {
        try out.append(a, marker);
        try out.appendSlice(a, line);
        try out.append(a, '\n');
    }
}

fn countLines(text: []const u8) usize {
    var lines = LineReader{ .bytes = text };
    var count: usize = 0;
    while (lines.next()) |_| count += 1;
    return count;
}

/// The lines of the two sides, one at a time, with no trailing empty line after
/// a final newline: a hunk whose last line is blank is not what the change
/// carries.
const LineReader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(self: *LineReader) ?[]const u8 {
        if (self.at >= self.bytes.len) return null;
        const stop = std.mem.indexOfScalarPos(u8, self.bytes, self.at, '\n') orelse self.bytes.len;
        const line = self.bytes[self.at..stop];
        self.at = @min(stop + 1, self.bytes.len);
        return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
    }
};

/// How the fields of a record and an update to it come together.
const Merged = struct {
    /// What the merged record opens to, in order: what the call already said,
    /// with the update's value where it replaced one, then what the update
    /// added. Nothing here is owned: every entry still points at one of the two
    /// records until the caller allocates the list it becomes.
    fields: [max_fields]Field = undefined,
    used: usize = 0,
    /// Which entry of the update, and which entry of the call, the layout
    /// holds. What neither does is what the caller releases.
    fresh_kept: [max_fields]bool = undefined,
    stored_kept: [max_fields]bool = undefined,
};

/// Lay the fields of a merged record out in order. Infallible and moving
/// nothing, so the size of the list is known before the call that allocates it.
///
/// A field the call already showed under the same label is that field updated:
/// the update's value stands, in the place the reader already knows, so a chip
/// does not show yesterday's result beside today's. A label the call had not
/// shown is added rather than replacing anything, which is what keeps the
/// command a chip was opened for when an update arrives carrying only the
/// result. A repeated label and value is the same field and is not added twice,
/// and the list stops at `max_fields`.
///
/// The stored list never exceeds `max_fields`: every record in a list was built
/// by `merge` or by `parse`, and both stop at it.
fn layOutFields(kept: []const Field, fresh: []const Field) Merged {
    std.debug.assert(kept.len <= max_fields);
    var merged = Merged{};
    @memset(&merged.stored_kept, false);
    @memset(&merged.fresh_kept, false);
    for (kept, 0..) |field, slot| {
        merged.fields[merged.used] = field;
        merged.stored_kept[slot] = true;
        merged.used += 1;
    }
    for (fresh, 0..) |field, index| {
        var placed = false;
        for (merged.fields[0..merged.used], 0..) |seen, slot| {
            if (!merged.stored_kept[slot] or !std.mem.eql(u8, seen.label, field.label)) continue;
            merged.fields[slot] = field;
            merged.stored_kept[slot] = false;
            merged.fresh_kept[index] = true;
            placed = true;
            break;
        }
        if (placed) continue;
        var duplicate = false;
        for (merged.fields[0..merged.used]) |seen| {
            if (std.mem.eql(u8, seen.label, field.label) and std.mem.eql(u8, seen.value, field.value)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate or merged.used == max_fields) continue;
        merged.fields[merged.used] = field;
        merged.fresh_kept[index] = true;
        merged.used += 1;
    }
    return merged;
}

const testing = std.testing;

/// Parse a fixture. `alloc_always` matches the client, so nothing in a test
/// borrows the bytes it was parsed from.
fn readJson(a: Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, text, .{ .allocate = .alloc_always });
}

fn fieldOf(call: ToolCall, label: []const u8) ?[]const u8 {
    for (call.fields) |field| {
        if (std.mem.eql(u8, field.label, label)) return field.value;
    }
    return null;
}

test "a read call shows its path, not the JSON it arrived in" {
    const a = testing.allocator;
    const parsed = try readJson(a,
        \\{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read file","kind":"read","status":"pending",
        \\ "locations":[{"path":"src/app.zig","line":42}],
        \\ "rawInput":{"file_path":"src/app.zig","offset":1,"limit":2000}}
    );
    defer parsed.deinit();
    var call = try parse(a, parsed.value);
    defer deinit(&call, a);

    try testing.expectEqual(Kind.read, call.kind);
    try testing.expectEqual(State.pending, call.state);
    try testing.expectEqualStrings("t1", call.id);
    try testing.expectEqualStrings("src/app.zig", call.subject);
    try testing.expectEqualStrings("src/app.zig", fieldOf(call, "path").?);
    try testing.expectEqualStrings("42", fieldOf(call, "line").?);
    // The tool's own arguments are fields under a reader's words, and the key
    // the file path arrived under is not repeated as itself.
    try testing.expectEqualStrings("2000", fieldOf(call, "limit").?);
    try testing.expect(fieldOf(call, "file_path") == null);
    try testing.expect(fieldOf(call, "rawInput") == null);
    for (call.fields) |field| {
        try testing.expect(std.mem.indexOfScalar(u8, field.value, '{') == null);
    }
}

test "a read call that names its file only in locations still shows it" {
    const a = testing.allocator;
    // The path is the one thing the call is about, and an agent may say it in
    // `locations` and nowhere else; the title is what the chip falls back to
    // when nothing better exists, not what it shows instead.
    const parsed = try readJson(a,
        \\{"sessionUpdate":"tool_call","toolCallId":"t2","title":"Read file","kind":"read","status":"in_progress",
        \\ "locations":[{"path":"src/acp/client.zig","line":7}]}
    );
    defer parsed.deinit();
    var call = try parse(a, parsed.value);
    defer deinit(&call, a);

    try testing.expectEqual(Kind.read, call.kind);
    try testing.expectEqualStrings("src/acp/client.zig", call.subject);
    try testing.expectEqualStrings("src/acp/client.zig", fieldOf(call, "path").?);
    try testing.expectEqualStrings("7", fieldOf(call, "line").?);
}

test "an edit's two sides become a diff the reader recognises" {
    const a = testing.allocator;
    const parsed = try readJson(a,
        \\{"sessionUpdate":"tool_call","toolCallId":"e1","title":"Edit","kind":"edit","status":"in_progress",
        \\ "content":[{"type":"diff","path":"src/app.zig","oldText":"let a = 1;\nlet b = 2;\n","newText":"let a = 1;\nlet b = 3;\n"}]}
    );
    defer parsed.deinit();
    var call = try parse(a, parsed.value);
    defer deinit(&call, a);

    try testing.expectEqual(Kind.edit, call.kind);
    try testing.expectEqualStrings("src/app.zig", call.subject);
    const bytes = call.diff orelse return error.MissingDiff;
    try testing.expect(diff.looksLikeDiff(bytes));
    const files = (try diff.parse(a, bytes)) orelse return error.NotADiff;
    defer diff.deinit(files, a);
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expect(std.mem.endsWith(u8, files[0].path, "src/app.zig"));
    try testing.expectEqual(@as(usize, 1), files[0].hunks.len);
    var added = false;
    var removed = false;
    for (files[0].hunks[0].lines) |line| {
        if (std.mem.eql(u8, line.text, "+let b = 3;")) added = line.kind == .added;
        if (std.mem.eql(u8, line.text, "-let b = 2;")) removed = line.kind == .removed;
    }
    try testing.expect(added and removed);
}

test "an edit whose change arrives in rawInput is a diff too" {
    const a = testing.allocator;
    const parsed = try readJson(a,
        \\{"sessionUpdate":"tool_call","toolCallId":"w1","title":"Write","kind":"edit","status":"completed",
        \\ "rawInput":{"file_path":"notes.md","content":"first\nsecond\n"}}
    );
    defer parsed.deinit();
    var call = try parse(a, parsed.value);
    defer deinit(&call, a);

    try testing.expectEqualStrings("notes.md", call.subject);
    const bytes = call.diff orelse return error.MissingDiff;
    try testing.expect(diff.looksLikeDiff(bytes));
    // A file being created has no old side, which a unified diff writes as 0,0.
    try testing.expect(std.mem.indexOf(u8, bytes, "@@ -0,0 +1,2 @@") != null);
}

test "an update to a call already seen keeps its place, its kind and its fields" {
    const a = testing.allocator;
    var calls: std.ArrayList(ToolCall) = .empty;
    defer {
        for (calls.items) |*call| deinit(call, a);
        calls.deinit(a);
    }
    {
        const parsed = try readJson(a,
            \\{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Bash","kind":"execute","status":"in_progress",
            \\ "rawInput":{"command":"zig build test","cwd":"/src/seggs"}}
        );
        defer parsed.deinit();
        var call = try parse(a, parsed.value);
        call.at = 100;
        try merge(&calls, a, call);
    }
    {
        // An update as ACP writes one: the id and what changed, nothing else.
        const parsed = try readJson(a,
            \\{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed",
            \\ "rawOutput":{"exitCode":0,"output":"all tests passed"}}
        );
        defer parsed.deinit();
        var call = try parse(a, parsed.value);
        call.at = 9000;
        try merge(&calls, a, call);
    }
    try testing.expectEqual(@as(usize, 1), calls.items.len);
    const call = calls.items[0];
    // The offset is the one the call landed at, not the one the update arrived
    // at, so the chip stays where it was while the call progresses.
    try testing.expectEqual(@as(usize, 100), call.at);
    try testing.expectEqual(Kind.execute, call.kind);
    try testing.expectEqual(State.completed, call.state);
    try testing.expectEqualStrings("zig build test", call.subject);
    try testing.expectEqualStrings("Bash", call.title);
    // The command the chip was opened for is still there, beside what the
    // update reported.
    try testing.expectEqualStrings("zig build test", fieldOf(call, "command").?);
    try testing.expectEqualStrings("0", fieldOf(call, "exit code").?);
    try testing.expectEqualStrings("all tests passed", fieldOf(call, "output").?);

    // A call that has finished is not dragged back to pending by a later update
    // that names no state of its own.
    {
        const parsed = try readJson(a,
            \\{"sessionUpdate":"tool_call_update","toolCallId":"t1","content":[{"type":"content","content":{"type":"text","text":"one more line"}}]}
        );
        defer parsed.deinit();
        var update = try parse(a, parsed.value);
        update.at = 9999;
        try merge(&calls, a, update);
    }
    try testing.expectEqual(@as(usize, 1), calls.items.len);
    try testing.expectEqual(@as(usize, 100), calls.items[0].at);
    try testing.expectEqual(State.completed, calls.items[0].state);
    try testing.expectEqual(Kind.execute, calls.items[0].kind);
    try testing.expectEqualStrings("one more line", fieldOf(calls.items[0], "output").?);
}

test "a long value keeps its first line and says what it left out" {
    const a = testing.allocator;
    const long = try a.alloc(u8, 4000);
    defer a.free(long);
    @memset(long, 'x');
    const text = try std.fmt.allocPrint(a,
        \\{{"sessionUpdate":"tool_call","toolCallId":"x1","title":"Bash","kind":"execute","status":"completed",
        \\ "rawInput":{{"command":"cat big.txt"}},
        \\ "rawOutput":{{"exitCode":2,"output":"{s}\nsecond line"}}}}
    , .{long});
    defer a.free(text);
    const parsed = try readJson(a, text);
    defer parsed.deinit();
    var call = try parse(a, parsed.value);
    defer deinit(&call, a);

    try testing.expectEqualStrings("cat big.txt", call.subject);
    try testing.expectEqualStrings("2", fieldOf(call, "exit code").?);
    const output = fieldOf(call, "output").?;
    // One line, cut at the bound, and honest about the rest: the body of the
    // file is not passed through as if it were the value.
    try testing.expect(output.len < max_value_bytes + 64);
    try testing.expect(std.mem.startsWith(u8, output, "xxx"));
    try testing.expect(std.mem.endsWith(u8, output, "bytes omitted)"));
    try testing.expect(std.mem.indexOfScalar(u8, output, '\n') == null);
    try testing.expect(std.mem.indexOf(u8, output, "second line") == null);
}

test "a transcript that drops its oldest bytes moves every chip with it" {
    const a = testing.allocator;
    var calls: std.ArrayList(ToolCall) = .empty;
    defer {
        for (calls.items) |*call| deinit(call, a);
        calls.deinit(a);
    }
    for ([_]struct { id: []const u8, at: usize }{
        .{ .id = "first", .at = 5 },
        .{ .id = "second", .at = 20 },
    }) |fixture| {
        const text = try std.fmt.allocPrint(a,
            \\{{"sessionUpdate":"tool_call","toolCallId":"{s}","title":"Read","kind":"read","status":"pending","locations":[{{"path":"src/app.zig"}}]}}
        , .{fixture.id});
        defer a.free(text);
        const parsed = try readJson(a, text);
        defer parsed.deinit();
        var call = try parse(a, parsed.value);
        call.at = fixture.at;
        try merge(&calls, a, call);
    }
    // Eight bytes leave the front of the transcript: every offset moves up by
    // eight, and the one that was nearer than that lands at the front.
    shiftAt(calls.items, 8);
    try testing.expectEqual(@as(usize, 0), calls.items[0].at);
    try testing.expectEqual(@as(usize, 12), calls.items[1].at);
    // A drop past everything clamps rather than wrapping a chip to the wrong
    // end of the transcript.
    shiftAt(calls.items, 4096);
    try testing.expectEqual(@as(usize, 0), calls.items[0].at);
    try testing.expectEqual(@as(usize, 0), calls.items[1].at);
}

test "an update that is too much to be a call is refused by name" {
    const a = testing.allocator;

    // One content part more than a call carries.
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(a);
    try wire.appendSlice(a, "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"p1\",\"title\":\"Many\",\"content\":[");
    for (0..max_parts + 1) |index| {
        if (index != 0) try wire.append(a, ',');
        try wire.appendSlice(a, "{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"x\"}}");
    }
    try wire.appendSlice(a, "]}");
    const parsed = try readJson(a, wire.items);
    defer parsed.deinit();
    try testing.expectError(error.TooManyParts, parse(a, parsed.value));

    // A string, not an object, is not a call at all.
    try testing.expectError(error.MalformedToolCall, parse(a, .{ .string = "not a call" }));

    // A megabyte of JSON is refused rather than read.
    const big = try a.alloc(u8, max_update_bytes + 1);
    defer a.free(big);
    @memset(big, 'y');
    var oversized: std.json.ObjectMap = .empty;
    defer oversized.deinit(a);
    try oversized.put(a, "toolCallId", .{ .string = "big" });
    try oversized.put(a, "rawOutput", .{ .string = big });
    try testing.expectError(error.ToolCallTooLarge, parse(a, .{ .object = oversized }));
}

test "a kind and a status are read from the words an agent used" {
    try testing.expectEqual(Kind.read, kindOf("read"));
    try testing.expectEqual(Kind.read, kindOf("Read file"));
    try testing.expectEqual(Kind.edit, kindOf("file_write"));
    try testing.expectEqual(Kind.execute, kindOf("Bash"));
    try testing.expectEqual(Kind.search, kindOf("grep"));
    try testing.expectEqual(Kind.switch_mode, kindOf("switch_mode"));
    try testing.expectEqual(Kind.other, kindOf("something_new"));
    try testing.expectEqual(Kind.other, kindOf(""));

    try testing.expectEqual(State.pending, stateOf("pending"));
    try testing.expectEqual(State.in_progress, stateOf("in_progress"));
    try testing.expectEqual(State.completed, stateOf("completed"));
    try testing.expectEqual(State.failed, stateOf("failed"));
    // A state this does not know claims nothing, and neither does none at all.
    try testing.expectEqual(State.pending, stateOf(""));
    try testing.expectEqual(State.pending, stateOf("reticulating"));
    try testing.expect(State.completed.finished());
    try testing.expect(!State.in_progress.finished());
}

test "the list of calls is capped, oldest first" {
    const a = testing.allocator;
    var calls: std.ArrayList(ToolCall) = .empty;
    defer {
        for (calls.items) |*call| deinit(call, a);
        calls.deinit(a);
    }
    for (0..max_calls + 4) |index| {
        const text = try std.fmt.allocPrint(a,
            \\{{"sessionUpdate":"tool_call","toolCallId":"c{d}","title":"Read","kind":"read","status":"pending","locations":[{{"path":"src/app.zig"}}]}}
        , .{index});
        defer a.free(text);
        const parsed = try readJson(a, text);
        defer parsed.deinit();
        var call = try parse(a, parsed.value);
        call.at = index;
        try merge(&calls, a, call);
        try testing.expect(calls.items.len <= max_calls);
    }
    try testing.expectEqual(max_calls, calls.items.len);
    try testing.expectEqualStrings("c4", calls.items[0].id);
}

/// A call that uses every part of the reader at once: a location, a diff, a
/// text part, a tool's own arguments, and its result.
const rich_call =
    \\{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Edit and run","kind":"edit","status":"in_progress",
    \\ "locations":[{"path":"src/app.zig","line":12}],
    \\ "content":[{"type":"diff","path":"src/app.zig","oldText":"one\ntwo\n","newText":"one\nthree\n"},
    \\            {"type":"content","content":{"type":"text","text":"done"}}],
    \\ "rawInput":{"command":"zig build test","cwd":"/src/seggs","args":["--summary","all"],"offset":1,"limit":4000},
    \\ "rawOutput":{"exitCode":0,"output":"all tests passed","count":3}}
;

fn parseRichCall(a: Allocator) !void {
    const parsed = try readJson(a, rich_call);
    defer parsed.deinit();
    var call = try parse(a, parsed.value);
    deinit(&call, a);
}

test "an allocation that fails while reading a call leaves nothing behind" {
    const a = testing.allocator;
    // Every allocation the reader makes is made to fail in turn. The number of
    // allocations is not fixed - a container that grows in place allocates once
    // where another run copies - so this walks the failure points instead of
    // asking the standard harness for a fixed list, and checks what matters:
    // the failure comes back as an error, and the allocator is left with
    // nothing outstanding. That is the rule the record lives by, because a call
    // whose parts are half owned is a chip that draws freed memory.
    var failures: usize = 0;
    var index: usize = 0;
    while (true) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = index });
        const result = parseRichCall(failing.allocator());
        if (!failing.has_induced_failure) {
            // Nothing was made to fail this time: the run ended without
            // reaching that many allocations, which is where the walk is done.
            try result;
            break;
        }
        try testing.expectEqual(error.OutOfMemory, result);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        failures += 1;
    }
    try testing.expect(failures > 0);
}
