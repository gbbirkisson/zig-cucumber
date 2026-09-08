const gherkin = @import("gherkin.zig");

pub const parse = gherkin.parse;
pub const Error = gherkin.Error;
pub const Diagnostic = gherkin.Diagnostic;

pub const Feature = gherkin.Feature;
pub const Rule = gherkin.Rule;
pub const Background = gherkin.Background;
pub const Scenario = gherkin.Scenario;
pub const Examples = gherkin.Examples;
pub const Row = gherkin.Row;
pub const Step = gherkin.Step;
pub const Keyword = gherkin.Keyword;
pub const Argument = gherkin.Argument;
pub const DocString = gherkin.DocString;

test {
    _ = gherkin;
}
