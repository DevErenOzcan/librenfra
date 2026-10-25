// mail-inbound - Cloudflare Email Worker for deverenozcan.com.
// Managed by Terraform (librenfra mail_server/cloudflare).
//
// Email Routing hands every message for the domain to this Worker. It POSTs
// the raw message, through Cloudflare Access and the Cloudflare Tunnel, to the
// receiver on the mail server (../../roles/mail_receiver/files/receiver.py),
// and acts on the answer:
//
//   200 "queued"   Postfix took it: done.
//   422            Postfix refused it for good (unknown address, spam): the
//                  message is rejected, so the sender gets a bounce.
//   anything else  the server is down, busy or not answering as expected:
//                  the message is forwarded to FALLBACK_ADDRESS, never lost.
//
// Bindings: RECEIVER_URL, FALLBACK_ADDRESS (text); RECEIVER_SECRET,
// ACCESS_CLIENT_ID, ACCESS_CLIENT_SECRET (secrets).

export default {
  async email(message, env) {
    const answer = await deliver(message, env);

    if (answer.status === 200 && answer.text.startsWith('queued')) {
      return;
    }
    if (answer.status === 422) {
      message.setReject(answer.text.slice(0, 400) || 'Recipient refused');
      return;
    }

    console.log(`mail-inbound: ${message.from} -> ${message.to}: ${answer.why}; forwarding to the fallback address`);
    try {
      await message.forward(env.FALLBACK_ADDRESS, new Headers({ 'X-Librenfra-Fallback': answer.why }));
    } catch (error) {
      console.log(`mail-inbound: fallback failed too: ${error}`);
      message.setReject('Mail server unavailable, please try again later');
    }
  },
};

async function deliver(message, env) {
  // Buffered, so the request carries a Content-Length, which the receiver
  // requires. Cloudflare takes messages up to 25 MiB.
  const raw = await new Response(message.raw).arrayBuffer();
  let response;
  try {
    response = await fetch(env.RECEIVER_URL, {
      method: 'POST',
      // Access answers a request it does not let through with a redirect to
      // its login page; followed, that would look like a 200.
      redirect: 'manual',
      headers: {
        'CF-Access-Client-Id': env.ACCESS_CLIENT_ID,
        'CF-Access-Client-Secret': env.ACCESS_CLIENT_SECRET,
        'X-Receiver-Secret': env.RECEIVER_SECRET,
        'X-Envelope-From': encodeURIComponent(message.from || ''),
        'X-Envelope-To': encodeURIComponent(message.to),
        'Content-Type': 'message/rfc822',
      },
      body: raw,
    });
  } catch (error) {
    return { status: 0, text: '', why: `unreachable (${error})` };
  }
  const text = (await response.text()).trim();
  return { status: response.status, text, why: `HTTP ${response.status} ${text.slice(0, 80)}` };
}
