import { plainToInstance } from 'class-transformer';
import {
  IsEnum,
  IsIn,
  IsNotEmpty,
  IsNumber,
  IsOptional,
  IsString,
  MinLength,
  ValidateIf,
  validateSync,
} from 'class-validator';

enum Environment {
  Development = 'development',
  Production = 'production',
  Test = 'test',
}

export class EnvironmentVariables {
  @IsEnum(Environment)
  NODE_ENV: Environment = Environment.Development;

  @IsNumber()
  PORT: number = 3000;

  @IsString()
  DB_HOST: string = 'localhost';

  @IsNumber()
  DB_PORT: number = 5432;

  @IsString()
  DB_USER: string = 'postgres';

  @IsString()
  DB_PASS: string = 'postgres';

  @IsString()
  DB_NAME: string = 'chatdb';

  @IsString()
  @MinLength(32, { message: 'JWT_SECRET must be at least 32 characters' })
  JWT_SECRET: string;

  @ValidateIf((o) => o.NODE_ENV === Environment.Production)
  @IsString()
  @IsNotEmpty({ message: 'ALLOWED_ORIGINS is required in production' })
  ALLOWED_ORIGINS?: string;

  @IsOptional()
  @IsString()
  MEDIA_BASE_URL?: string;

  /**
   * `true` registers the box (`/box` namespace, `/box/media`); unset or
   * `false` leaves it out. Any other value fails boot, so a `1` or `yes`
   * cannot silently read as off.
   */
  @IsOptional()
  @IsIn(['true', 'false'])
  BOX_ENABLED?: string;

  /**
   * `true` freezes the old path (Phase 4 step 3, decision 111): no new
   * message, friend request or chat is written to the old tables. Unset or
   * `false` leaves it open; any other value fails boot, as for `BOX_ENABLED`.
   */
  @IsOptional()
  @IsIn(['true', 'false'])
  LEGACY_WRITES_FROZEN?: string;

  /**
   * `true` silences the old lists (Phase 4 step 4): no `friendsList`,
   * `conversationsList` or `servedMessageIds`, and `getDeviceList(s)` answers
   * only the caller's own id. Unset or `false` serves them; any other value
   * fails boot, as for `BOX_ENABLED`.
   */
  @IsOptional()
  @IsIn(['true', 'false'])
  LEGACY_LISTS_SILENT?: string;

  @IsOptional()
  @IsString()
  MEDIA_DIR?: string;

  @IsOptional()
  @IsString()
  WEB_PUSH_VAPID_PUBLIC_KEY?: string;

  @IsOptional()
  @IsString()
  WEB_PUSH_VAPID_PRIVATE_KEY?: string;

  @IsOptional()
  @IsString()
  WEB_PUSH_VAPID_SUBJECT?: string;

  @IsOptional()
  @IsString()
  APP_VERSION?: string;

  @IsOptional()
  @IsString()
  GIT_COMMIT?: string;

  @IsOptional()
  @IsString()
  BUILD_TIME?: string;

  /**
   * The published APK channel, read by `VersionController`. Optional: absent
   * means "no APK published", which is the correct state for a web-only
   * deploy. Kept as a string so an unset var and an empty one behave the
   * same; the controller parses and rejects a non-positive integer.
   */
  @IsOptional()
  @IsString()
  ANDROID_APK_VERSION_CODE?: string;

  @IsOptional()
  @IsString()
  ANDROID_APK_VERSION_NAME?: string;

  @IsOptional()
  @IsString()
  ANDROID_APK_URL?: string;
}

export function validate(config: Record<string, any>): EnvironmentVariables {
  const validatedConfig = plainToInstance(EnvironmentVariables, config, {
    enableImplicitConversion: true,
  });

  const errors = validateSync(validatedConfig, {
    skipMissingProperties: false,
  });

  if (errors.length > 0) {
    const errorMessages = errors
      .map(
        (error) =>
          `${error.property}: ${Object.values(error.constraints || {}).join(', ')}`,
      )
      .join('; ');
    throw new Error(`Environment validation failed: ${errorMessages}`);
  }

  // Phase 4 step 4: an open old path still answers a send's `deviceListStale`
  // with the recipient's signed list and can create chats no client is told
  // about, so the list silence is only coherent on a frozen old path.
  if (
    validatedConfig.LEGACY_LISTS_SILENT === 'true' &&
    validatedConfig.LEGACY_WRITES_FROZEN !== 'true'
  ) {
    throw new Error(
      'Environment validation failed: LEGACY_LISTS_SILENT=true requires LEGACY_WRITES_FROZEN=true',
    );
  }

  return validatedConfig;
}
