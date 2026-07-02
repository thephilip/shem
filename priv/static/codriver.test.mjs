// priv/static/codriver.test.mjs
// Run: node priv/static/codriver.test.mjs
import assert from 'node:assert';

// Mirror of toolTemplate in app.js — kept in sync by hand, like divergence.test.mjs.
function toolTemplate(tool) {
  const args = {};
  for (const [k, v] of Object.entries(tool.schema || {})) {
    const ty = (v && v.type) || 'string';
    args[k] =
      ty === 'number' || ty === 'integer' ? 0 :
      ty === 'boolean' ? false :
      ty === 'array' ? [] :
      ty === 'object' ? {} : '';
  }
  return JSON.stringify({ tool: tool.id, args });
}

// one placeholder key per schema property, typed
assert.equal(
  toolTemplate({ id: 'diff_text', schema: { a: { type: 'string' }, b: { type: 'string' } } }),
  '{"tool":"diff_text","args":{"a":"","b":""}}'
);

// numbers and booleans get typed placeholders
assert.equal(
  toolTemplate({ id: 't', schema: { n: { type: 'integer' }, f: { type: 'boolean' } } }),
  '{"tool":"t","args":{"n":0,"f":false}}'
);

// no schema -> empty args object
assert.equal(toolTemplate({ id: 'bare' }), '{"tool":"bare","args":{}}');

// the template itself parses as a Turn.step tool call
const parsed = JSON.parse(toolTemplate({ id: 'x', schema: { q: {} } }));
assert.equal(parsed.tool, 'x');
assert.deepEqual(parsed.args, { q: '' });

console.log('codriver.test.mjs: all assertions passed');
