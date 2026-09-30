import {
  IsIn,
  IsNumber,
  IsOptional,
  IsString,
  MinLength,
  MaxLength,
  Matches,
  ValidateNested,
} from 'class-validator';
import { Type } from 'class-transformer';
import {
  PASSWORD_MIN_LENGTH,
  PASSWORD_REGEX,
  PASSWORD_REGEX_MESSAGE,
} from '../../auth/password.constants';

export class ResetPasswordDto {
  @IsString()
  @MinLength(1)
  oldPassword: string;

  @IsString()
  @MinLength(PASSWORD_MIN_LENGTH, {
    message: `Password must be at least ${PASSWORD_MIN_LENGTH} characters long`,
  })
  @Matches(PASSWORD_REGEX, { message: PASSWORD_REGEX_MESSAGE })
  newPassword: string;
}

export class DeleteAccountDto {
  @IsString()
  @MinLength(1)
  password: string;
}

export class VerifyPasswordDto {
  @IsString()
  @MinLength(1)
  @MaxLength(128) // bcrypt reads 72 bytes; 128 chars as LoginDto
  password: string;
}

export class UpdateProfileAboutDto {
  @IsOptional()
  @IsString()
  @MaxLength(80)
  about?: string | null;
}

export class RegisterFcmTokenDto {
  @IsString()
  @MinLength(10)
  token: string;

  @IsIn(['web', 'android', 'ios'])
  platform: string;
}

export class RemoveFcmTokenDto {
  @IsString()
  @MinLength(1)
  token: string;
}

class WebPushKeysDto {
  @IsString()
  @MinLength(1)
  p256dh: string;

  @IsString()
  @MinLength(1)
  auth: string;
}

export class RegisterWebPushSubscriptionDto {
  @IsString()
  @MinLength(1)
  endpoint: string;

  @ValidateNested()
  @Type(() => WebPushKeysDto)
  keys: WebPushKeysDto;

  @IsOptional()
  @IsNumber()
  expirationTime?: number | null;

  @IsOptional()
  @IsString()
  userAgent?: string;
}

export class RemoveWebPushSubscriptionDto {
  @IsString()
  @MinLength(1)
  endpoint: string;
}
