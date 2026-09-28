// Asks Claude a question with the KROK connector attached (Anthropic MCP connector).
import Anthropic from '@anthropic-ai/sdk';

const client = new Anthropic();

export async function askClaude(question, mcpUrl) {
  const response = await client.beta.messages.create({
    model: process.env.CLAUDE_EVAL_MODEL ?? 'claude-opus-5',
    max_tokens: 16000,
    betas: ['mcp-client-2025-11-20', 'server-side-fallback-2026-07-01'],
    fallbacks: 'default',
    mcp_servers: [{ type: 'url', url: mcpUrl, name: 'health-sync' }],
    tools: [{ type: 'mcp_toolset', mcp_server_name: 'health-sync' }],
    system: 'You are answering questions about the user\'s Apple Health data using the health-sync tools. Answer with the number requested.',
    messages: [{ role: 'user', content: question }],
  });
  if (response.stop_reason === 'refusal') return { text: '', refused: true };
  const text = response.content.filter((b) => b.type === 'text').map((b) => b.text).join('\n');
  const toolCalls = response.content.filter((b) => b.type === 'mcp_tool_use').map((b) => b.name);
  return { text, toolCalls };
}
