#!/usr/bin/python3
"""Takes mail that Cloudflare's Email Worker sends over the tunnel and hands
it to Postfix.

Managed by Ansible (librenfra mail_server, role mail_receiver).

The Worker POSTs each message to /inbound, through the Cloudflare Tunnel that
cloudflared runs on this server:

    X-Receiver-Secret: <the shared secret>
    X-Envelope-From:   <sender>      percent-encoded; empty for a bounce
    X-Envelope-To:     <recipient>   percent-encoded; one per request
    body:              the raw message, as received (with a Content-Length,
                       or chunked)

and gets back what Postfix said, so a refusal reaches the sender:

    200  Postfix queued it
    422  Postfix refused it for good (5xx): the Worker rejects the message
    503  Postfix refused it for now (4xx) or could not be reached: the Worker
         keeps the message some other way
    400, 403, 404, 413  the request itself was wrong

It listens on 127.0.0.1 only; cloudflared is the one thing that talks to it.
Message contents are never logged.
"""
import hmac
import http.server
import os
import smtplib
import sys
import urllib.parse

LISTEN = ('127.0.0.1', int(os.environ.get('RECEIVER_PORT', '8025')))
POSTFIX = ('127.0.0.1', 25)
HELO = os.environ.get('RECEIVER_HELO', 'localhost')
MAX_BYTES = int(os.environ.get('RECEIVER_MAX_BYTES', str(30 * 1024 * 1024)))
# systemd hands the secret over as a credential (LoadCredential=secret:...).
with open(os.path.join(os.environ['CREDENTIALS_DIRECTORY'], 'secret'), 'rb') as f:
    SECRET = f.read().strip()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = 'mail-receiver'
    sys_version = ''

    def do_POST(self):
        if self.path != '/inbound':
            return self.answer(404, 'not found')
        if not hmac.compare_digest(self.headers.get('X-Receiver-Secret', '').encode(), SECRET):
            return self.answer(403, 'forbidden')
        sender = urllib.parse.unquote(self.headers.get('X-Envelope-From', ''))
        recipient = urllib.parse.unquote(self.headers.get('X-Envelope-To', ''))
        try:
            message = self.read_body()
        except ValueError as e:
            return self.answer(400, str(e))
        except OverflowError:
            return self.answer(413, 'message too large')
        if not recipient or not message:
            return self.answer(400, 'a recipient and a message are required')
        length = len(message)

        options = ['BODY=8BITMIME']
        if not (sender + recipient).isascii():
            options.append('SMTPUTF8')
        try:
            with smtplib.SMTP(*POSTFIX, local_hostname=HELO, timeout=120) as smtp:
                smtp.sendmail(sender, [recipient], message, mail_options=options)
        except smtplib.SMTPRecipientsRefused as e:
            code, text = e.recipients[recipient]
            return self.postfix_said(code, text, sender, recipient)
        except smtplib.SMTPResponseException as e:
            return self.postfix_said(e.smtp_code, e.smtp_error, sender, recipient)
        except (OSError, smtplib.SMTPException) as e:
            self.log_message('%s -> %s: Postfix unreachable: %s', sender, recipient, e)
            return self.answer(503, 'mail server unavailable')
        self.log_message('%s -> %s: queued (%d bytes)', sender, recipient, length)
        return self.answer(200, 'queued')

    def read_body(self):
        """The request body, sent with a Content-Length or chunked (as a proxy
        in front may pass it on); at most MAX_BYTES."""
        if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
            body = bytearray()
            while True:
                try:
                    size = int(self.rfile.readline().split(b';')[0].strip(), 16)
                except ValueError:
                    raise ValueError('malformed chunked body')
                if size == 0:
                    while self.rfile.readline() not in (b'\r\n', b'\n', b''):
                        pass  # trailers
                    return bytes(body)
                if len(body) + size > MAX_BYTES:
                    raise OverflowError
                body += self.rfile.read(size)
                self.rfile.readline()  # the CRLF after each chunk
        try:
            length = int(self.headers.get('Content-Length', ''))
        except ValueError:
            raise ValueError('Content-Length or chunked transfer encoding is required')
        if length > MAX_BYTES:
            raise OverflowError
        return self.rfile.read(length)

    def postfix_said(self, code, text, sender, recipient):
        text = text.decode(errors='replace') if isinstance(text, bytes) else str(text)
        self.log_message('%s -> %s: Postfix said %d %s', sender, recipient, code, text)
        return self.answer(422 if 500 <= code < 600 else 503, f'{code} {text}')

    def answer(self, status, text):
        body = (text + '\n').encode()
        self.send_response(status)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # To the journal, without the client address: it is always cloudflared.
        sys.stderr.write((fmt % args) + '\n')


if __name__ == '__main__':
    http.server.ThreadingHTTPServer(LISTEN, Handler).serve_forever()
