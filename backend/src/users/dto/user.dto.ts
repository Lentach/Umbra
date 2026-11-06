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
