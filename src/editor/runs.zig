//! Runs: a workflow executed against a workspace, with every result kept.
//!
//! The vocabulary is the product's: a workflow is a definition, a run is one
//! execution of it, a step is one invocation, and an artifact is what a step
//! produced. The engine knows nothing about ACP, panels, or the editor: a
//! caller asks what the current step should receive, hands back what came of
//! it, and the run moves on. That seam is what lets a pipeline run without an
//! open transcript, and what lets it be tested without a harness.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// What an artifact is, which is also what a step can produce and consume.
pub const Kind = enum {
    /// A piece of the workspace a run started from.
    context,
    /// A plan written by an agent.
    plan,
    /// A change described or applied by an agent.
    implementation,
    /// What a command printed, with the command that printed it. Named for
    /// the check rather than for the tool: `test` is a keyword.
    checks,
    /// A judgement of an earlier artifact.
    review,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .context => "context",
            .plan => "plan",
            .implementation => "implementation",
            .checks => "checks",
            .review => "review",
        };
    }
};

/// One invocation. Steps name a harness by index rather than by handle: the
/// engine does not own processes, so a run outlives any panel that shows it.
pub const Step = struct {
    name: []const u8,
    /// What this step hands to the harness, and therefore what it needs first.
    produces: Kind,
    /// Which harness, by index into the caller's list. A command step ignores
    /// it.
    harness: usize = 0,
    /// What this step is asked to do, in the workflow's own words. The engine
    /// keeps it so a run can be described without a transcript being open.
    request: []const u8 = "",
    /// What the harness had finished when this step was sent, and where its
    /// words stood. A turn counter answers *whether* the step is done; the
    /// offset is used to take the answer, and is checked against a transcript
    /// that is bounded and drops its oldest bytes.
    turns_mark: usize = 0,
    transcript_mark: usize = 0,
    state: State = .waiting,

    pub const State = enum { waiting, running, done, failed };
};

pub const Artifact = struct {
    kind: Kind,
    /// The step that produced it, or "source" for what the run started from.
    source: []const u8,
    body: []u8,
};

pub const Run = struct {
    allocator: Allocator,
    name: []u8,
    steps: []Step,
    artifacts: std.ArrayList(Artifact) = .empty,
    state: State = .running,

    pub const State = enum { running, waiting_for_approval, done, failed };

    pub fn init(a: Allocator, name: []const u8, steps: []const Step) !Run {
        const owned = try a.dupe(Step, steps);
        errdefer a.free(owned);
        return .{ .allocator = a, .name = try a.dupe(u8, name), .steps = owned };
    }

    pub fn deinit(self: *Run) void {
        self.allocator.free(self.name);
        self.allocator.free(self.steps);
        for (self.artifacts.items) |artifact| {
            self.allocator.free(artifact.source);
            self.allocator.free(artifact.body);
        }
        self.artifacts.deinit(self.allocator);
    }

    /// The step that should run now, or null when there is nothing to run.
    ///
    /// A failed step stops the run rather than being stepped over: the next
    /// step's input would be missing, and an invented one is worse than a run
    /// that stopped where it broke.
    pub fn current(self: *Run) ?*Step {
        for (self.steps) |*step| {
            switch (step.state) {
                .failed => return null,
                .waiting, .running => return step,
                .done => {},
            }
        }
        return null;
    }

    pub fn isDone(self: *const Run) bool {
        for (self.steps) |step| {
            if (step.state != .done) return false;
        }
        return true;
    }

    /// What a step receives: everything earlier steps produced, each named by
    /// the step it came from. A step is never handed a summary of its input.
    pub fn promptFor(self: *Run, a: Allocator, step: *const Step, request: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        const produces = step.produces;
        for (self.artifacts.items) |artifact| {
            try out.appendSlice(a, artifact.kind.label());
            try out.appendSlice(a, " from ");
            try out.appendSlice(a, artifact.source);
            try out.appendSlice(a, ":\n```\n");
            try out.appendSlice(a, artifact.body);
            try out.appendSlice(a, "\n```\n\n");
        }
        try out.appendSlice(a, "Step ");
        try out.appendSlice(a, step.name);
        try out.appendSlice(a, " should produce ");
        try out.appendSlice(a, produces.label());
        try out.appendSlice(a, ".\n\n");
        try out.appendSlice(a, request);
        return out.toOwnedSlice(a);
    }

    /// Record what a step produced. A result is data: it cannot grant the next
    /// step anything, which is why an artifact carries its origin and kind but
    /// no authority.
    pub fn record(self: *Run, step: *Step, body: []const u8) !void {
        if (step.state == .failed) return error.StepFailed;
        try self.artifacts.append(self.allocator, .{
            .kind = step.produces,
            .source = try self.allocator.dupe(u8, step.name),
            .body = try self.allocator.dupe(u8, body),
        });
        step.state = .done;
        if (self.isDone()) self.state = .done;
    }

    /// A step that did not finish stops the run rather than being skipped: the
    /// next step's input would be missing, and an invented one is worse than a
    /// stopped run.
    pub fn fail(self: *Run, step: *Step) void {
        step.state = .failed;
        self.state = .failed;
    }
};

test "a run hands each step what the last one produced" {
    const a = std.testing.allocator;
    const steps = [_]Step{
        .{ .name = "plan", .produces = .plan, .harness = 0, .request = "Produce an implementation plan" },
        .{ .name = "implement", .produces = .implementation, .harness = 1, .request = "Implement the plan" },
        .{ .name = "review", .produces = .review, .harness = 2, .request = "Review the change" },
    };
    var run = try Run.init(a, "parser fix", &steps);
    defer run.deinit();

    // The run owns what it records, so the test hands over the strings and
    // lets deinit release them: the testing allocator would see a leak here
    // otherwise, and a double free if the test freed them too.
    try run.artifacts.append(a, .{
        .kind = .context,
        .source = try a.dupe(u8, "source"),
        .body = try a.dupe(u8, "fn parse() {}"),
    });

    const plan_step = run.current().?;
    const plan_prompt = try run.promptFor(a, plan_step, "Produce an implementation plan");
    defer a.free(plan_prompt);
    try std.testing.expect(std.mem.indexOf(u8, plan_prompt, "context from source:") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan_prompt, "fn parse() {}") != null);
    try std.testing.expect(std.mem.endsWith(u8, plan_prompt, "Produce an implementation plan"));
    try run.record(plan_step, "1. change the parser");

    // The next step is handed the plan itself, not a note that a plan exists.
    const implement = run.current().?;
    try std.testing.expectEqualStrings("implement", implement.name);
    const implement_prompt = try run.promptFor(a, implement, "Implement the plan");
    defer a.free(implement_prompt);
    try std.testing.expect(std.mem.indexOf(u8, implement_prompt, "plan from plan:") != null);
    try std.testing.expect(std.mem.indexOf(u8, implement_prompt, "1. change the parser") != null);
    try std.testing.expect(std.mem.indexOf(u8, implement_prompt, "should produce implementation") != null);
    try run.record(implement, "diff --git a/parser.zig");
    try std.testing.expect(!run.isDone());
    try run.record(run.current().?, "looks right");
    try std.testing.expect(run.isDone());
    try std.testing.expectEqual(Run.State.done, run.state);
}

test "a failed step stops the run instead of feeding the next one" {
    const a = std.testing.allocator;
    const steps = [_]Step{
        .{ .name = "zig build test", .produces = .checks, .request = "Run the suite" },
        .{ .name = "review", .produces = .review, .harness = 1, .request = "Review the result" },
    };
    var run = try Run.init(a, "verify", &steps);
    defer run.deinit();
    const step = run.current().?;
    try std.testing.expectEqualStrings("zig build test", step.name);
    run.fail(step);
    try std.testing.expectEqual(Run.State.failed, run.state);
    // Nothing downstream may start: the run has no current step at all, which
    // is what stops a pipeline at the step that broke.
    try std.testing.expect(run.current() == null);
    try std.testing.expect(!run.isDone());
    try std.testing.expectError(error.StepFailed, run.record(step, "2 errors"));
}
