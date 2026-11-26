import {
  IsOptional,
  IsString,
  MinLength,
  MaxLength,
  Matches,
} from 'class-validator';
import {
  PASSWORD_MIN_LENGTH,
  PASSWORD_REGEX,
  PASSWORD_REGEX_MESSAGE,
} from '../../auth-core/password.constants';
import { MaxCodePoints } from '../../common/max-code-points';
import { MaxGraphemes } from '../../common/max-graphemes';

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
  @MaxLength(128) // 128 chars as LoginDto
  password: string;
}

export class UpdateProfileAboutDto {
  @IsOptional()
  @IsString()
  // 80 characters as the user sees them; 640 code points is the column's
  // CHECK (migration 0032), the backstop for a cluster of unbounded size.
  @MaxGraphemes(80)
  @MaxCodePoints(640)
  about?: string | null;
}
