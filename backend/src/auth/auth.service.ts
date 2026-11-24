import {
  Injectable,
  UnauthorizedException,
  Logger,
  HttpException,
  HttpStatus,
} from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import * as argon2 from 'argon2';
import { User } from '../users/user.entity';
import { UsersService } from '../users/users.service';
import { RefreshTokensService } from '../refresh-tokens/refresh-tokens.service';
import { LoginBackoffService } from './login-backoff.service';
import { passwordFormatOf, verifyDummyPasswords } from '../auth-core/password-hash';
import { DevicesService } from '../key-bundles/devices.service';
import {
  IdentityResetService,
  RecoveryCredential,
  TIMING_SAFE_DUMMY_VERIFIER,
} from '../key-bundles/identity-reset.service';
import { DEFAULT_DEVICE_ID } from '../key-bundles/key-bundles.service';

// `/auth/recover`'s timing guard lives with the verifier it mirrors:
// `TIMING_SAFE_DUMMY_VERIFIER` in identity-reset.service.

@Injectable()
export class AuthService {
  private readonly auditLogger = new Logger('Audit');

  constructor(
    private usersService: UsersService,
    private jwtService: JwtService,
    private refreshTokensService: RefreshTokensService,
    private devicesService: DevicesService,
    private identityResetService: IdentityResetService,
    private loginBackoff: LoginBackoffService,
  ) {}

  async register(username: string, password: string) {
    // Password strength is validated at the DTO layer (RegisterDto)
    const user = await this.usersService.create(username, password);
    return { id: user.id, username: user.username, tag: user.tag };
  }

  async login(identifier: string, password: string, clientIp?: string) {
    const parsed = parseIdentifier(identifier);
    const user = await this.resolveIdentifier(identifier);
    // Backoff per (NAME, client address) (plan D4). The account part is the
    // parsed, lower-cased NAME for everyone, resolved or not: keyed on the
    // resolved id, a locked `alice` would answer 429 to `alice#1234` (real) and
    // 401 to `alice#1111` (no such tag), which tells valid tags apart. The
    // attempt is reserved NOW, before any await, so parallel requests cannot
    // all slip past the check.
    const key = this.loginBackoff.reserve(
      parsed ? `name:${parsed.name.toLowerCase()}` : '-',
      clientIp,
    );

    try {
      if (!user) {
        // Unknown name: pay both formats, so it costs what a wrong password
        // costs against either kind of stored hash.
        await verifyDummyPasswords(password, ['bcrypt', 'argon2id']);
        this.auditLogger.log(`login failed`);
        throw new UnauthorizedException('Invalid credentials');
      }

      // Also upgrades a bcrypt hash to Argon2id after a correct password.
      const passwordValid = await this.usersService.checkPassword(
        user,
        password,
      );
      if (!passwordValid) {
        // The real verify paid the row's own format; pay the other one.
        await verifyDummyPasswords(password, [
          passwordFormatOf(user.password) === 'bcrypt' ? 'argon2id' : 'bcrypt',
        ]);
        this.auditLogger.log(`login failed`);
        throw new UnauthorizedException('Invalid credentials');
      }
    } catch (err) {
      // The hash gate was full: that is the server's failure, not a guess.
      if (err instanceof HttpException && err.getStatus() === 503) {
        this.loginBackoff.refund(key);
      }
      throw err;
    }

    this.loginBackoff.succeed(key);
    this.auditLogger.log(`login success`);
    return this.issueSession(user);
  }

  /**
   * The recovery phrase as a credential (spec §12 amendment (lxxxii) clause
   * 2): a correct phrase sets a new password, drops every session, and
   * answers with login tokens — the door proved ownership, so a second
   * round-trip to sign in would be ceremony.
   *
   * Order is load-bearing: the identifier is resolved BEFORE any verify, so
   * an unknown name never pays the 19 MiB Argon2id cost (the IP throttle on
   * the route is the DoS control; no dummy hash here, for that same memory
   * reason). One refusal wording for unknown name, wrong phrase and no phrase
   * enrolled — no enumeration. The lockout is the SAME counter the §6.2
   * shortcut spends, so guessing at either door draws on one budget.
   */
  async recoverPassword(
    identifier: string,
    credential: RecoveryCredential,
    newPassword: string,
  ) {
    const user = await this.resolveIdentifier(identifier);
    if (!user) {
      // Constant-time guard, as login's twin: no per-account counter
      // exists to spend, but the verify itself must cost the same.
      await argon2
        .verify(TIMING_SAFE_DUMMY_VERIFIER, credential.value)
        .catch(() => false);
      this.auditLogger.log(`recoverPassword failed reason=unknown_account`);
      throw new UnauthorizedException('Invalid credentials');
    }
    const verdict = await this.identityResetService.verifyRecoveryPhrase(
      user.id,
      credential,
    );
    if (verdict === 'legacy_recovery_key') {
      // The stored key predates plan B7 and cannot check an authSecret. Answered
      // EXACTLY like a wrong phrase: this door is unauthenticated, so a distinct
      // answer would tell anyone which accounts hold an old key. The client's
      // refusal text says what to do. (The authenticated reset door does say so.)
      this.auditLogger.log(`recoverPassword refused reason=legacy_key`);
      throw new UnauthorizedException('Invalid credentials');
    }
    if (verdict === 'locked') {
      this.auditLogger.log(`recoverPassword locked`);
      throw new HttpException('recovery_locked', HttpStatus.LOCKED);
    }
    if (verdict !== 'accepted') {
      this.auditLogger.log(`recoverPassword failed reason=wrong_phrase`);
      throw new UnauthorizedException('Invalid credentials');
    }

    const changedAt = await this.usersService.setPassword(user.id, newPassword);
    // The owner proved themselves by the phrase: forget every client's failures.
    this.loginBackoff.clearAccount(`name:${user.username.toLowerCase()}`); // log-guard: key
    this.auditLogger.log(`recoverPassword success`);
    // `JwtStrategy` and the socket handshake reject `iat <= passwordChangedAt`
    // in WHOLE SECONDS, and a JWT's `iat` is floored — a token signed in the
    // same second as the stamp is dead on arrival. Wait for the next second
    // (≤ 1 s) rather than back-dating the stamp, which would let a token
    // stolen in that second survive the change. Re-check after each wait:
    // timers run on the monotonic clock and can fire ~1 ms before
    // `Date.now()` reaches the target, which signed in the stamp's second.
    const nextSecondMs = (Math.floor(changedAt.getTime() / 1000) + 1) * 1000;
    for (
      let waitMs = nextSecondMs - Date.now();
      waitMs > 0;
      waitMs = nextSecondMs - Date.now()
    ) {
      // Executor form on purpose: the tsconfig lib predates Promise.withResolvers.
      await new Promise<void>((resolve) => setTimeout(resolve, waitMs));
    }
    return this.issueSession(user);
  }

  /**
   * `username#tag`, or a bare username that matches exactly one account. An
   * ambiguous bare name resolves to nobody: revealing that several accounts
   * share it is enumeration, and the callers route "nobody" through the same
   * refusal as a wrong secret. Lookup stays case-insensitive (findByUsername).
   */
  private async resolveIdentifier(identifier: string): Promise<User | null> {
    const parsed = parseIdentifier(identifier);
    if (!parsed) return null;
    if (parsed.tag !== undefined) {
      return this.usersService.findByUsernameAndTag(parsed.name, parsed.tag);
    }
    const users = await this.usersService.findByUsername(parsed.name);
    if (users.length > 1) {
      this.auditLogger.log(`login failed (multiple users)`);
    }
    return users.length === 1 ? users[0] : null;
  }

  private async issueSession(user: User) {
    // Every session belongs to a device (Phase 1, spec §4). This is the
    // account's LIVE PRIMARY, never a hardcoded 1: a §6.2 reset revokes the
    // pre-reset roster and moves the account onto a freshly allocated id
    // (amendment (xxviii)), so claiming device 1 here would hand the owner a
    // token for a revoked device — which the §5.5 session gates then refuse,
    // locking them out with the correct password. Legacy accounts with no
    // rows still resolve to device 1 (§8).
    const deviceId = await this.devicesService.resolveLoginDeviceId(user.id);
    const payload = {
      sub: user.id,
      username: user.username,
      tag: user.tag,
      deviceId,
    };
    const refresh_token = await this.refreshTokensService.createToken(
      user.id,
      deviceId,
    );
    return {
      access_token: this.jwtService.sign(payload),
      refresh_token,
    };
  }

  /**
   * [rotate]: the client keeps whatever `refresh_token` comes back, so the
   * session's token can rotate (plan B4); without it the token stays.
   */
  async refreshWithToken(refreshTokenPlain: string, rotate = false) {
    const session = await this.refreshTokensService.redeem(
      refreshTokenPlain,
      (userId, deviceId) =>
        this.devicesService.isRevoked(userId, deviceId ?? DEFAULT_DEVICE_ID),
      { rotate },
    );
    const user = await this.usersService.findById(session.userId);
    if (!user) {
      throw new UnauthorizedException();
    }
    const payload = {
      sub: user.id,
      username: user.username,
      tag: user.tag,
      // The refresh row remembers which device the session belongs to; a row
      // predating the column is device 1 (§8).
      deviceId: session.deviceId ?? DEFAULT_DEVICE_ID,
    };
    return {
      access_token: this.jwtService.sign(payload),
      refresh_token: session.refreshToken,
    };
  }

  async logoutRefreshToken(refreshTokenPlain: string): Promise<void> {
    await this.refreshTokensService.revokeByPlain(refreshTokenPlain);
  }
}

/** `name` or `name#tag`, trimmed; null for a `#` with an empty side. */
function parseIdentifier(
  identifier: string,
): { name: string; tag?: string } | null {
  if (identifier.includes('#')) {
    const [u, t] = identifier.split('#');
    if (!u || !t) return null;
    return { name: u.trim(), tag: t.trim() };
  }
  return { name: identifier.trim() };
}
