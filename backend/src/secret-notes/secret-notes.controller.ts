// backend/src/secret-notes/secret-notes.controller.ts
import {
  Controller, Post, Get, Body, Param, Res, UseGuards,
} from '@nestjs/common';
import { IsString, IsNotEmpty, IsInt, MaxLength } from 'class-validator';
import { JwtAuthGuard } from '../auth/jwt-auth.guard';
import { SecretNotesService } from './secret-notes.service';
import type { Response } from 'express';
import { randomBytes } from 'crypto';
import { Throttle } from '@nestjs/throttler';

class CreateNoteDto {
  @IsString()
  @IsNotEmpty()
  @MaxLength(65536)
  ciphertext: string;

  @IsInt()
  expiresIn: number; // seconds; whitelist 3600 | 21600 | 43200 | 86400 (else -> 21600)
}

@Controller()
export class SecretNotesController {
  /** Tokens are 32 lowercase hex chars (crypto.randomBytes(16).toString('hex')).
   *  Gate BEFORE any DB hit or HTML interpolation: nothing else may ever be
   *  embedded into the served pages. */
  private static readonly TOKEN_RE = /^[0-9a-f]{32}$/;

  constructor(private readonly service: SecretNotesService) {}

  @UseGuards(JwtAuthGuard)
  @Post('notes')
  async createNote(@Body() dto: CreateNoteDto) {
    const validTtls = [3600, 21600, 43200, 86400];
    const expiresIn = validTtls.includes(dto.expiresIn) ? dto.expiresIn : 21600;
    return this.service.create(dto.ciphertext, expiresIn);
  }

  @Get('note/:token')
  @Throttle({ default: { limit: 60, ttl: 60000 } })
  async getNotePage(@Param('token') token: string, @Res() res: Response) {
    if (!SecretNotesController.TOKEN_RE.test(token)) {
      this.setNoteHeaders(res, randomBytes(16).toString('base64'));
      res.send(this.destroyedPage());
      return;
    }
    const note = await this.service.findByToken(token);
    const nonce = randomBytes(16).toString('base64');
    this.setNoteHeaders(res, nonce);
    if (!note) {
      res.send(this.destroyedPage());
      return;
    }
    const remainingMs = new Date(note.expiresAt).getTime() - Date.now();
    const remainingLabel = this.formatRemaining(remainingMs);
    res.send(this.landingPage(token, remainingLabel, nonce));
  }

  /** Existence check for the in-chat note banner: the client flips the card
   *  to a "burned — it was read" remnant when the note is gone BEFORE its
   *  clock (the `e=` fragment param) ran out. JWT-guarded — only app clients
   *  query it; the public reveal page never calls this. Malformed tokens get
   *  `alive:false` (no oracle beyond what GET /note/:token already exposes).
   */
  @UseGuards(JwtAuthGuard)
  @Get('note/:token/status')
  @Throttle({ default: { limit: 120, ttl: 60000 } })
  async noteStatus(@Param('token') token: string): Promise<{ alive: boolean }> {
    if (!SecretNotesController.TOKEN_RE.test(token)) return { alive: false };
    const note = await this.service.findByToken(token);
    return { alive: note !== null };
  }

  @Post('note/:token/reveal')
  @Throttle({ default: { limit: 30, ttl: 60000 } })
  async revealNote(@Param('token') token: string, @Res() res: Response) {
    if (!SecretNotesController.TOKEN_RE.test(token)) {
      res.status(404).json({ error: 'gone' });
      return;
    }
    const result = await this.service.revealAndDelete(token);
    if (!result) {
      res.status(404).json({ error: 'gone' });
      return;
    }
    res.json({ ciphertext: result.ciphertext });
  }

  private formatRemaining(ms: number): string {
    const h = Math.floor(ms / 3600000);
    const m = Math.floor((ms % 3600000) / 60000);
    if (h > 0) return `${h}h ${m}m`;
    return `${m}m`;
  }

  // Per-response CSP overriding helmet's global one so the nonce'd reveal script
  // runs, plus no-store: note pages must never be served from any cache.
  private setNoteHeaders(res: Response, nonce: string): void {
    res.setHeader(
      'Content-Security-Policy',
      `default-src 'self'; script-src 'nonce-${nonce}'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; base-uri 'none'`,
    );
    res.setHeader('Cache-Control', 'no-store');
  }

  private landingPage(token: string, remaining: string, nonce: string): string {
    return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Anti-Quantum Note</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{background:#111;color:#eee;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
    display:flex;align-items:center;justify-content:center;min-height:100vh;padding:20px}
  .card{background:#1e1e1e;border-radius:16px;padding:36px 28px;max-width:440px;width:100%;text-align:center;
    box-shadow:0 8px 32px rgba(0,0,0,0.5)}
  .icon{font-size:48px;margin-bottom:16px}
  h1{font-size:20px;font-weight:700;margin-bottom:8px;letter-spacing:0.3px}
  .sub{color:#888;font-size:14px;line-height:1.6;margin-bottom:28px}
  .btn{background:linear-gradient(135deg,#c0392b,#922b21);border:none;border-radius:10px;
    color:#fff;font-size:15px;font-weight:700;padding:14px 32px;cursor:pointer;width:100%;
    letter-spacing:0.3px;transition:opacity 0.2s}
  .btn:hover{opacity:0.9}
  .btn:disabled{opacity:0.5;cursor:not-allowed}
  .expires{color:#555;font-size:12px;margin-top:16px}
  .content{background:#151515;border:1px solid #333;border-radius:10px;padding:20px;
    text-align:left;line-height:1.7;font-size:14px;color:#ddd;word-break:break-word;
    white-space:pre-wrap;margin-bottom:16px}
  .revealed-header{color:#888;font-size:11px;text-transform:uppercase;letter-spacing:1px;margin-bottom:16px}
  .footer{color:#444;font-size:11px;margin-top:12px}
  #error{color:#e74c3c;font-size:13px;margin-top:12px;display:none}
  .applink{display:inline-block;margin-top:20px;color:#888;font-size:13px;font-weight:600;text-decoration:none}
  .applink:hover{color:#ccc}
</style>
</head>
<body>
<div class="card" id="landing">
  <div class="icon">⚛️</div>
  <h1>Anti-Quantum Note</h1>
  <p class="sub">Someone sent you a self-destructing message.<br>It will be permanently destroyed after you read it.</p>
  <button class="btn" id="revealBtn">🔓 Reveal &amp; Destroy</button>
  <div class="expires">Expires in ${remaining} · Powered by Umbra</div>
  <div id="error">Failed to load note. It may have already been read.</div>
  <a class="applink" href="/">← Open Umbra</a>
</div>

<div class="card" id="revealed" style="display:none">
  <div class="icon">🔓</div>
  <div class="revealed-header">Message revealed · Now permanently destroyed</div>
  <div class="content" id="noteContent"></div>
  <div class="footer">This note has been deleted from the server.<br>Refreshing this page will show nothing.</div>
  <a class="applink" href="/">← Open Umbra</a>
</div>

<script nonce="${nonce}">
async function reveal() {
  const btn = document.getElementById('revealBtn');
  btn.disabled = true;
  btn.textContent = 'Decrypting...';

  try {
    // Fragment: <key>[&c=<convId>][&e=<expiry ms>] — key is always first.
    const fragment = location.hash.slice(1).split('&')[0];
    if (!fragment) throw new Error('No key in URL');

    // Validate and import the key BEFORE the destructive reveal call: a
    // mangled/truncated fragment must never burn the note. Only a fetch that
    // reaches the server can destroy it, so everything checkable stays first.
    const keyBytes = base64ToBytes(fragment);
    if (keyBytes.length !== 32) throw new Error('bad key length');
    const cryptoKey = await crypto.subtle.importKey(
      'raw', keyBytes, { name: 'AES-GCM' }, false, ['decrypt']
    );

    const res = await fetch('/note/${token}/reveal', { method: 'POST' });
    if (!res.ok) throw new Error('gone');
    const { ciphertext } = await res.json();

    const parts = ciphertext.split(':');
    if (parts.length !== 2) throw new Error('bad format');
    const iv = base64ToBytes(parts[0]);
    const enc = base64ToBytes(parts[1]);

    const decrypted = await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, cryptoKey, enc);
    const text = new TextDecoder().decode(decrypted);

    document.getElementById('landing').style.display = 'none';
    document.getElementById('noteContent').textContent = text;
    document.getElementById('revealed').style.display = '';
  } catch (e) {
    btn.disabled = false;
    btn.textContent = '🔓 Reveal & Destroy';
    document.getElementById('error').style.display = 'block';
  }
}

function base64ToBytes(b64) {
  const bin = atob(b64.replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(bin, c => c.charCodeAt(0));
}

// Deep link back into the chat the note came from: c=<convId> rides the URL
// fragment (never sent to the server). Digits-only guard before templating.
(function wireAppLinks() {
  const match = location.hash.match(/[#&]c=(\\d+)(&|$)/);
  if (!match) return;
  document.querySelectorAll('a.applink').forEach(a => {
    a.href = '/?notify_conv=' + match[1];
  });
})();
document.getElementById('revealBtn').addEventListener('click', reveal);
</script>
</body>
</html>`;
  }

  private destroyedPage(): string {
    return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Anti-Quantum Note</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{background:#111;color:#eee;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
    display:flex;align-items:center;justify-content:center;min-height:100vh}
  .card{background:#1e1e1e;border-radius:16px;padding:36px 28px;max-width:440px;width:100%;
    text-align:center;box-shadow:0 8px 32px rgba(0,0,0,0.5)}
  .icon{font-size:48px;margin-bottom:16px}
  h1{font-size:18px;font-weight:700;margin-bottom:10px}
  p{color:#666;font-size:14px;line-height:1.6}
  .applink{display:inline-block;margin-top:20px;color:#888;font-size:13px;font-weight:600;text-decoration:none}
  .applink:hover{color:#ccc}
</style>
</head>
<body>
<div class="card">
  <div class="icon">💀</div>
  <h1>This note no longer exists</h1>
  <p>It was either already read or has expired.<br>Ask the sender to create a new one.</p>
  <a class="applink" href="/">← Open Umbra</a>
</div>
</body>
</html>`;
  }
}
