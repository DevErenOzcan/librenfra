// Tests mail-inbound's decisions in Node, with fetch and the message object
// faked - no Cloudflare needed. From this directory: node mail-inbound.test.mjs
import assert from 'node:assert/strict';
const worker = (await import('./mail-inbound.js')).default;

const env = { RECEIVER_URL: 'https://mx-in.example/inbound', FALLBACK_ADDRESS: 'me@gmail.com',
              RECEIVER_SECRET: 's3cret', ACCESS_CLIENT_ID: 'id.access', ACCESS_CLIENT_SECRET: 'acc-secret' };
function fakeMessage(from = 'Jane <jane@gmail.com>'.replace(/.*<|>/g, ''), to = 'ali@deverenozcan.com') {
  const body = 'Subject: hi\r\n\r\nMerhaba, şükrü\r\n';
  return { from, to, raw: new Response(body).body, rawSize: Buffer.byteLength(body),
           rejected: null, forwarded: null,
           setReject(r) { this.rejected = r; },
           async forward(addr, headers) { if (addr === 'broken') throw new Error('not verified'); this.forwarded = { addr, fb: headers.get('X-Librenfra-Fallback') }; } };
}
let seen;
function respond(status, text, extra = {}) {
  globalThis.fetch = async (url, init) => { seen = { url, init, body: Buffer.from(init.body).toString() }; return new Response(text, { status, ...extra }); };
}

// 1. queued
respond(200, 'queued\n'); let m = fakeMessage(); await worker.email(m, env);
assert.equal(m.rejected, null); assert.equal(m.forwarded, null);
assert.equal(seen.init.redirect, 'manual');
assert.equal(seen.init.headers['X-Envelope-To'], 'ali%40deverenozcan.com');
assert.equal(seen.init.headers['CF-Access-Client-Id'], 'id.access');
assert.equal(seen.init.headers['X-Receiver-Secret'], 's3cret');
assert.match(seen.body, /şükrü/);
console.log('ok 1 - 200 queued: delivered, nothing else');

// 2. permanent refusal -> reject with Postfix's words
respond(422, '550 5.1.1 <nobody@deverenozcan.com>: Recipient address rejected: User unknown\n');
m = fakeMessage('jane@gmail.com', 'nobody@deverenozcan.com'); await worker.email(m, env);
assert.match(m.rejected, /^550 5\.1\.1/); assert.equal(m.forwarded, null);
console.log('ok 2 - 422: rejected with Postfix\'s answer');

// 3. temporary trouble -> fallback
respond(503, 'mail server unavailable'); m = fakeMessage(); await worker.email(m, env);
assert.equal(m.rejected, null); assert.equal(m.forwarded.addr, 'me@gmail.com'); assert.match(m.forwarded.fb, /^HTTP 503/);
console.log('ok 3 - 503: forwarded to the fallback address');

// 4. Access login redirect, not followed -> fallback (not a fake success)
globalThis.fetch = async () => new Response(null, { status: 302, headers: { Location: 'https://x.cloudflareaccess.com/login' } });
m = fakeMessage(); await worker.email(m, env);
assert.equal(m.forwarded.addr, 'me@gmail.com'); assert.match(m.forwarded.fb, /^HTTP 302/);
console.log('ok 4 - Access redirect: forwarded, not taken for success');

// 5. a 200 that is not the receiver (e.g. some HTML page) -> fallback
respond(200, '<html>login</html>'); m = fakeMessage(); await worker.email(m, env);
assert.equal(m.forwarded.addr, 'me@gmail.com');
console.log('ok 5 - 200 without "queued": forwarded');

// 6. network error -> fallback
globalThis.fetch = async () => { throw new TypeError('fetch failed'); };
m = fakeMessage(); await worker.email(m, env);
assert.equal(m.forwarded.addr, 'me@gmail.com'); assert.match(m.forwarded.fb, /^unreachable/);
console.log('ok 6 - network error: forwarded');

// 7. fallback fails too -> rejected (the sender learns it was not delivered)
respond(503, 'down'); m = fakeMessage(); await worker.email(m, { ...env, FALLBACK_ADDRESS: 'broken' });
assert.match(m.rejected, /unavailable/);
console.log('ok 7 - fallback broken: rejected');

// 8. bounce (empty envelope sender)
respond(200, 'queued'); m = fakeMessage('', 'ali@deverenozcan.com'); await worker.email(m, env);
assert.equal(seen.init.headers['X-Envelope-From'], ''); assert.equal(m.rejected, null);
console.log('ok 8 - empty sender passed on as empty');
