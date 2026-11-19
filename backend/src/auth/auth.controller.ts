import {
  Controller,
  Post,
  Body,
  HttpCode,
  HttpStatus,
  Req,
} from '@nestjs/common';
import type { Request } from 'express';
import { proxiedClientIp } from '../common/client-ip';
import { Throttle } from '@nestjs/throttler';
import { AuthService } from './auth.service';
import { RegisterDto } from './dto/register.dto';
import { LoginDto } from './dto/login.dto';
import { RefreshBodyDto } from './dto/refresh-body.dto';
import { RecoverPasswordDto } from './dto/recover-password.dto';
import { recoveryCredentialOf } from '../key-bundles/identity-reset.service';

@Controller('auth')
export class AuthController {
  constructor(private authService: AuthService) {}

  // POST /auth/register — creates a new user
  // Rate limit: 10 requests per hour per IP (tolerates shared NAT; still blocks abuse)
  @Throttle({ default: { limit: 10, ttl: 3600000 } })
  @Post('register')
  register(@Body() dto: RegisterDto) {
    return this.authService.register(dto.username, dto.password);
  }

  // POST /auth/login — returns JWT access token + opaque refresh token
  // Rate limit: 30 requests per 15 minutes per IP (shared-NAT tolerant; blocks credential stuffing)
  @Throttle({ default: { limit: 30, ttl: 900000 } })
  @Post('login')
  login(@Body() dto: LoginDto, @Req() req: Request) {
    // Same client identity the throttlers use (X-Real-IP, then the socket).
    const clientIp = proxiedClientIp(req.headers) ?? req.ip;
    return this.authService.login(dto.identifier, dto.password, clientIp);
  }

  /**
   * POST /auth/recover — the recovery phrase alone sets a new password and
   * answers with login tokens (spec §12 amendment (lxxxii) clause 2).
   * Unauthenticated by design. 5 per 15 minutes per IP: every attempt with a
   * real identifier costs a 19 MiB Argon2id verify, so the throttle is the
   * DoS control, not a courtesy.
   */
  @Throttle({ default: { limit: 5, ttl: 900000 } })
  @Post('recover')
  recover(@Body() dto: RecoverPasswordDto) {
    return this.authService.recoverPassword(
      dto.identifier,
      recoveryCredentialOf(dto.authSecret, dto.phrase)!,
      dto.newPassword,
    );
  }

  /**
   * Exchange an opaque refresh token for a fresh access JWT and the refresh
   * token to keep: a new one when the body asks to `rotate` (plan B4).
   */
  @Throttle({ default: { limit: 60, ttl: 60000 } })
  @Post('refresh')
  refresh(@Body() dto: RefreshBodyDto) {
    return this.authService.refreshWithToken(
      dto.refresh_token,
      dto.rotate === true,
    );
  }

  /** Revoke one refresh session (call on logout from this device). */
  @Throttle({ default: { limit: 30, ttl: 60000 } })
  @Post('logout')
  @HttpCode(HttpStatus.NO_CONTENT)
  logout(@Body() dto: RefreshBodyDto) {
    return this.authService.logoutRefreshToken(dto.refresh_token);
  }
}
