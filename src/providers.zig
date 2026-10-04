const std = @import("std");

pub const Auth = enum { none, key, oauth, copilot };
pub const Transport = enum { chat, responses, ollama, copilot };
pub const Spec = struct {
    id: []const u8,
    label: []const u8,
    endpoint: []const u8 = "",
    default_model: []const u8 = "",
    key_env: []const u8 = "",
    auth: Auth = .key,
    transport: Transport = .chat,
};

pub const all = [_]Spec{
    .{ .id = "manual", .label = "Manual — no model needed", .auth = .none },
    .{ .id = "ollama", .label = "Local model — Ollama", .endpoint = "http://127.0.0.1:11434", .auth = .none, .transport = .ollama },
    .{ .id = "api", .label = "Custom API — compatible provider", .endpoint = "https://api.openai.com/v1", .key_env = "DOIN_API_KEY" },
    .{ .id = "chatgpt", .label = "Continue with ChatGPT", .endpoint = "https://api.openai.com/v1", .auth = .oauth, .transport = .responses },
    .{ .id = "grok", .label = "Continue with Grok", .endpoint = "https://cli-chat-proxy.grok.com/v1", .auth = .oauth, .transport = .responses },
    .{ .id = "vercel", .label = "Continue with Vercel AI Gateway", .endpoint = "https://ai-gateway.vercel.sh/v1", .key_env = "AI_GATEWAY_API_KEY", .auth = .oauth },
    .{ .id = "openrouter", .label = "Continue with OpenRouter", .endpoint = "https://openrouter.ai/api/v1", .key_env = "OPENROUTER_API_KEY", .auth = .oauth },
    .{ .id = "copilot", .label = "Continue with GitHub Copilot", .default_model = "auto", .auth = .copilot, .transport = .copilot },
    .{ .id = "cloudflare", .label = "Cloudflare AI Gateway — gateway token", .key_env = "CLOUDFLARE_API_TOKEN" },
    .{ .id = "deepseek", .label = "DeepSeek — API key", .endpoint = "https://api.deepseek.com/v1", .key_env = "DEEPSEEK_API_KEY" },
    .{ .id = "openai", .label = "OpenAI — API key", .endpoint = "https://api.openai.com/v1", .key_env = "OPENAI_API_KEY" },
    .{ .id = "groq", .label = "Groq — API key", .endpoint = "https://api.groq.com/openai/v1", .key_env = "GROQ_API_KEY" },
    .{ .id = "mistral", .label = "Mistral — API key", .endpoint = "https://api.mistral.ai/v1", .key_env = "MISTRAL_API_KEY" },
    .{ .id = "together", .label = "Together AI — API key", .endpoint = "https://api.together.ai/v1", .key_env = "TOGETHER_API_KEY" },
    .{ .id = "fireworks", .label = "Fireworks AI — API key", .endpoint = "https://api.fireworks.ai/inference/v1", .key_env = "FIREWORKS_API_KEY" },
};

pub fn lookup(id: []const u8) ?Spec {
    for (all) |spec| if (std.mem.eql(u8, id, spec.id)) return spec;
    return null;
}
