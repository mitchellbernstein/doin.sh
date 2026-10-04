const options = @import("build_options");
pub const current: []const u8 = if (@hasDecl(options, "app_version")) options.app_version else "0.3.0";
