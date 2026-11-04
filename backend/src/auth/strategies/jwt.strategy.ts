import { Injectable, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PassportStrategy } from '@nestjs/passport';
import { ExtractJwt, Strategy } from 'passport-jwt';
import { UsersService } from '../../users/users.service';
import { DevicesService } from '../../key-bundles/devices.service';
import { DEFAULT_DEVICE_ID } from '../../key-bundles/key-bundles.service';

// Passport strategy — automatically verifies the JWT token
// and injects user data into request.user
@Injectable()
export class JwtStrategy extends PassportStrategy(Strategy) {
  constructor(
    private usersService: UsersService,
    private devicesService: DevicesService,
    configService: ConfigService,
  ) {
    const secret = configService.get<string>('JWT_SECRET');
    if (!secret) {
      throw new Error('JWT_SECRET is not configured');
    }
    super({
      jwtFromRequest: ExtractJwt.fromAuthHeaderAsBearerToken(),
      secretOrKey: secret,
    });
  }

  async validate(payload: {
    sub: number;
    username: string;
    tag: string;
    iat: number;
    deviceId?: number;
  }) {
    const user = await this.usersService.findById(payload.sub);
    if (!user) {
      throw new UnauthorizedException();
    }
    if (user.passwordChangedAt) {
      const changedAtSeconds = Math.floor(
        user.passwordChangedAt.getTime() / 1000,
      );
      if (payload.iat <= changedAtSeconds) {
        throw new UnauthorizedException('Token invalidated by password change');
      }
    }
    // Which device this request is (multi-device spec §4/§5.5). A token issued
    // before the claim existed is device 1 (§8) — the same reading the socket
    // path applies, so the two surfaces cannot disagree about who is calling.
    const deviceId = payload.deviceId ?? DEFAULT_DEVICE_ID;
    // A revoked device keeps a valid access JWT until natural expiry, and
    // without this it would keep every guarded REST route (account delete,
    // contact backup, profile photos). Amendment (xxii): deny ONLY on an explicit `revokedAt`; a MISSING
    // row must never deny, or every pre-Phase-1 account (no `devices` row
    // until its first socket connect) loses HTTP access.
    if (await this.devicesService.isRevoked(user.id, deviceId)) {
      throw new UnauthorizedException('Device revoked');
    }
    return {
      id: user.id,
      username: user.username,
      tag: user.tag,
      profilePictureUrl: user.profilePictureUrl,
      deviceId,
    };
  }
}
