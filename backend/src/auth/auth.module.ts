import { Module } from '@nestjs/common';
import { JwtModule } from '@nestjs/jwt';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { PassportModule } from '@nestjs/passport';
import { AuthService } from './auth.service';
import { LoginBackoffService } from './login-backoff.service';
import { AuthController } from './auth.controller';
import { JwtStrategy } from './strategies/jwt.strategy';
import { UsersModule } from '../users/users.module';
import { RefreshTokensModule } from './refresh-tokens.module';
import { KeyBundlesModule } from '../key-bundles/key-bundles.module';
import { resolveJwtSecret } from './jwt-secret';

@Module({
  imports: [
    UsersModule,
    RefreshTokensModule,
    // The HTTP guard needs the per-device revocation predicate (§5.5): a
    // revoked device's access JWT stays cryptographically valid until expiry.
    KeyBundlesModule,
    PassportModule,
    ConfigModule,
    JwtModule.registerAsync({
      imports: [ConfigModule],
      inject: [ConfigService],
      useFactory: (configService: ConfigService) => ({
        secret: resolveJwtSecret(configService),
        // Short-lived access JWT; long sessions use opaque refresh tokens (auth.service).
        signOptions: { expiresIn: '24h' },
      }),
    }),
  ],
  controllers: [AuthController],
  providers: [AuthService, LoginBackoffService, JwtStrategy],
  exports: [AuthService, JwtModule, RefreshTokensModule],
})
export class AuthModule {}
