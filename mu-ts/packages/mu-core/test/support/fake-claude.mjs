#!/usr/bin/env node
// Fake Claude Code CLI for harness tests. Speaks the documented
// stream-json surface: system/session_id, stream_event deltas,
// assistant message, and a terminal result.

const args = process.argv.slice(2)

if (args.includes('--version')) {
  process.stdout.write('0.1.0-fake\n')
  process.exit(0)
}

if (args.includes('auth') && args.includes('status')) {
  process.stdout.write(
    JSON.stringify({ loggedIn: true, authMethod: 'oauth', apiProvider: 'anthropic' }) + '\n',
  )
  process.exit(0)
}

const sessionID = 'fake-session-0001'
function line(object) {
  return `${JSON.stringify(object)}\n`
}

process.stdout.write(
  line({ type: 'system', session_id: sessionID, model: 'claude-sonnet-5' }),
)

const chunks = ['The renderer ', 'reads frames ', 'from the queue.']
for (const text of chunks) {
  process.stdout.write(
    line({
      type: 'stream_event',
      event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } },
    }),
  )
}

process.stdout.write(
  line({
    type: 'assistant',
    message: {
      id: 'msg_fake_1',
      model: 'claude-sonnet-5',
      content: [{ type: 'text', text: 'The renderer reads frames from the queue.' }],
    },
  }),
)

process.stdout.write(
  line({
    type: 'result',
    subtype: 'success',
    result: 'The renderer reads frames from the queue.',
    is_error: false,
    total_cost_usd: 0.01,
    duration_ms: 120,
  }),
)
process.exit(0)
