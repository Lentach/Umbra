import {
  Injectable,
  UnauthorizedException,
  Logger,
  HttpException,
  HttpStatus,
} from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import * as bcrypt from 'bcrypt';
import * as argon2 from 'argon2';
import { User } from '../users/user.entity';
import { UsersService } from '../users/users.service';
import { RefreshTokensService } from './refresh-tokens.service';
import { DevicesService } from '../key-bundles/devices.service';
import {
  IdentityResetService,
  TIMING_SAFE_DUMMY_VERIFIER,
} from '../key-bundles/identity-reset.service';
import { DEFAULT_DEVICE_ID } from '../key-bundles/key-bundles.service';

// Precomputed bcrypt hash used for a constant-time comparison when the
// identifier matches no user, so "no such user" takes the same time as a wrong
// password (defeats timing-based user enumeration). The value is arbitrary.
const TIMING_SAFE_DUMMY_HASH =
  '$2b$10$pwiFDkB3zcAu0PKQqI13b.fGqVMlVlB8aCB22BL/qyvTghAEiP2N2';

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
  ) {}

  async register(username: string, password: string) {
    // Password strength is validated at the DTO layer (RegisterDto)
    const user = await this.usersService.create(username, password);
    return { id: user.id, username: user.username, tag: user.tag };
  }

  async login(identifier: string, password: string) {
    const user = await this.resolveIdentifier(identifier);
    if (!user) {
      // Constant-time guard: perform a real bcrypt compare so a missing user
      // is indistinguishable by timing from a wrong password.
      await bcrypt.compare(password, TIMING_SAFE_DUMMY_HASH);
      this.auditLogger.log(`login failed`);
      throw new UnauthorizedException('Invalid credentials');
    }

    const passwordValid = await bcrypt.compare(password, user.password);
    if (!passwordValid) {
      this.auditLogger.log(`login failed`);
      throw new UnauthorizedException('Invalid credentials');
    }

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
    phrase: string,
    newPassword: string,
  ) {
    const user = await this.resolveIdentifier(identifier);
    if (!user) {
      // Constant-time guard, as login's bcrypt twin: no per-account counter
      // exists to spend, but the verify itself must cost the same.
      await argon2
        .verify(TIMING_SAFE_DUMMY_VERIFIER, phrase)
        .catch(() => false);
      this.auditLogger.log(`recoverPassword failed`);
      throw new UnauthorizedException('Invalid credentials');
    }
    const verdict = await this.identityResetService.verifyRecoveryPhrase(
      user.id,
      phrase,
    );
    if (verdict === 'locked') {
      this.auditLogger.log(`recoverPassword locked`);
      throw new HttpException('recovery_locked', HttpStatus.LOCKED);
    }
    if (verdict !== 'accepted') {
      this.auditLogger.log(`recoverPassword failed`);
      throw new UnauthorizedException('Invalid credentials');
    }

    const changedAt = await this.usersService.setPassword(user.id, newPassword);
    this.auditLogger.log(`recoverPassword success`);
    // `JwtStrategy` and the socket handshake reject `iat <= passwordChangedAt`
    // in WHOLE SECONDS, and a JWT's `iat` is floored — a token signed in the
    // same second as the stamp is dead on arrival. Wait for the next second
    // (≤ 1 s) rather than back-dating the stamp, which would let a token
    // stolen in that second survive the change.
    const nextSecondMs = (Math.floor(changedAt.getTime() / 1000) + 1) * 1000;
    const waitMs = nextSecondMs - Date.now();
    if (waitMs > 0) {
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
    if (identifier.includes('#')) {
      const [u, t] = identifier.split('#');
      if (!u || !t) return null;
      return this.usersService.findByUsernameAndTag(u.trim(), t.trim());
    }
    const users = await this.usersService.findByUsername(identifier.trim());
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

  async refreshWithToken(refreshTokenPlain: string) {
    const session =
      await this.refreshTokensService.consumeAndSlide(refreshTokenPlain);
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
      refresh_token: refreshTokenPlain,
    };
  }

  async logoutRefreshToken(refreshTokenPlain: string): Promise<void> {
    await this.refreshTokensService.revokeByPlain(refreshTokenPlain);
  }
}
