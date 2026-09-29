// Asks ChatGPT's API a question with the KROK connector attached (Responses API MCP tool).
import OpenAI from 'openai';

const client = new OpenAI();

export async function askOpenAI(question, mcpUrl) {
  const response = await client.responses.create({
    model: process.env.OPENAI_EVAL_MODEL ?? 'gpt-5',
    tools: [{ type: 'mcp', server_label: 'health_sync', server_url: mcpUrl, require_approval: 'never' }],
    instructions: "You are answering questions about the user's Apple Health workouts using the health_sync tools. Answer with the number requested.",
    input: question,
  });
  const toolCalls = (response.output ?? []).filter((o) => o.type === 'mcp_call').map((o) => o.name);
  return { text: response.output_text ?? '', toolCalls };
}
