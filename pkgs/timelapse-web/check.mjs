import assert from 'node:assert/strict';
import fs from 'node:fs';

const source = fs.readFileSync(new URL('site/app.js', import.meta.url), 'utf8');

function checkSource(text) {
  assert.match(text, /if \(nextProfile\.mode !== previousProfile\.mode\) \{ slot = quantizedSlot\(nextProfile\); render\(\); load\(\); \}/);
  assert.doesNotMatch(text, /if \(desiredPlaying && nextProfile\.mode !== previousProfile\.mode\)/);
  assert.match(text, /transaction\.oncomplete = resolve/);
  assert.match(text, /transaction\.onabort = transaction\.onerror = \(\) => reject\(new StorageFailure\(transaction\.error\)\)/);
  assert.doesNotMatch(text, /request\.onsuccess = \(\) => resolve\(\)/);
  assert.doesNotMatch(text, /captureFreeze|showTargetPreview|class="(?:freeze|preview)"/);
  assert.match(text, /selectTarget\([^)]*\).*this\.video\.style\.visibility = 'hidden'/);
  assert.match(text, /finishTarget\([^)]*\).*this\.video\.style\.visibility = ''/);
}

function extractFunction(text, name) {
  const start = text.indexOf(`async function ${name}(`);
  assert.notEqual(start, -1, `${name} missing`);
  const brace = text.indexOf('{', start);
  let depth = 0;
  for (let index = brace; index < text.length; index += 1) {
    if (text[index] === '{') depth += 1;
    if (text[index] === '}' && --depth === 0) return text.slice(start, index + 1);
  }
  throw new Error(`${name} is unbalanced`);
}

class StorageFailure extends Error {
  constructor(error) { super(error?.message); this.name = 'StorageFailure'; }
}

async function exerciseStagedPut(action) {
  let transaction;
  const db = { transaction() { transaction = { error: null, objectStore: () => ({ put() {} }) }; return transaction; } };
  const factory = new Function('stagedDb', 'StorageFailure', `return ${extractFunction(source, 'stagedPut')};`);
  const stagedPut = factory(Promise.resolve(db), StorageFailure);
  let settled = false;
  const result = stagedPut('key', new Blob()).finally(() => { settled = true; });
  await Promise.resolve();
  assert.equal(settled, false, 'put settled before its transaction');
  action(transaction);
  return result;
}

checkSource(source);
await exerciseStagedPut((transaction) => transaction.oncomplete());
await assert.rejects(exerciseStagedPut((transaction) => { transaction.error = new Error('aborted'); transaction.onabort(); }), StorageFailure);

assert.throws(() => checkSource(source.replace('if (nextProfile.mode !== previousProfile.mode)', 'if (desiredPlaying && nextProfile.mode !== previousProfile.mode)')));
assert.throws(() => checkSource(source.replace('transaction.oncomplete = resolve', 'request.onsuccess = () => resolve()')));
console.log('timelapse-web checks passed');
