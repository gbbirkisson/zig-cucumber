const gherkin = @import("gherkin.zig");

pub const run = @import("runner.zig").run;
pub const Scenario = @import("runner.zig").Scenario;

/// Types a step definition or a hook names in its own signature.
pub const Result = @import("runner.zig").Result;
pub const Table = @import("table.zig").Table;
pub const DocString = gherkin.DocString;
pub const Step = gherkin.Step;

/// The rest of the parse tree, for a consumer that drives `ast.parse` directly.
/// `ast.Scenario` is a scenario as written; `Scenario` is one ready to run.
pub const ast = gherkin;

test {
    _ = gherkin;
    _ = @import("expression.zig");
    _ = @import("tags.zig");
    _ = @import("convert.zig");
    _ = @import("table.zig");
    _ = @import("runner.zig");
}
