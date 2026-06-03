pub const loader = @import("loader.zig");
pub const Config = loader.Config;
pub const RepoConfig = loader.RepoConfig;
pub const PatternConfig = loader.PatternConfig;
pub const ProvidersConfig = loader.ProvidersConfig;
pub const LinearConfig = loader.LinearConfig;
pub const RefreshConfig = loader.RefreshConfig;
pub const ProviderTemplates = loader.ProviderTemplates;
pub const UiConfig = loader.UiConfig;
pub const ColorScheme = loader.ColorScheme;
pub const LoadError = loader.LoadError;
pub const load = loader.load;
pub const loadSecretsToken = loader.loadSecretsToken;

test {
    _ = loader;
}
