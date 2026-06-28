import assert from 'node:assert';

// Mirror of eventTimeline.computeForkIdx — kept in sync with app.js.
function computeForkIdx(orig, fork) {
  const n = Math.min(orig.length, fork.length);
  for (let i = 0; i < n; i++) {
    const a = orig[i], b = fork[i];
    if (a.type !== b.type) return i;
    if (a.type === 'llm_call_completed' && (a.payload?.content || '') !== (b.payload?.content || '')) return i;
  }
  return n;
}

const ev = (type, content) => ({ type, payload: content === undefined ? {} : { content } });

// shared prefix of 2, fork edits the answer at index 2
assert.equal(computeForkIdx(
  [ev('agent_started'), ev('llm_call_started'), ev('llm_call_completed', 'A'), ev('agent_done')],
  [ev('agent_started'), ev('llm_call_started'), ev('llm_call_completed', 'B')]
), 2);

// identical prefix, fork shorter (still running) -> divergence at fork length
assert.equal(computeForkIdx(
  [ev('a'), ev('b'), ev('c')],
  [ev('a'), ev('b')]
), 2);

// fully identical -> divergence at min length
assert.equal(computeForkIdx([ev('a'), ev('b')], [ev('a'), ev('b')]), 2);

console.log('divergence: all assertions passed');
