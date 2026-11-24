import { IsString, Matches, MaxLength, MinLength } from 'class-validator';
import {
  PASSWORD_MIN_LENGTH,
  PASSWORD_REGEX,
  PASSWORD_REGEX_MESSAGE,
} from '../../auth-core/password.constants';

export class RegisterDto {
  @IsString()
  @MinLength(3)
  @MaxLength(20)
  @Matches(/^[a-zA-Z0-9_]+$/, {
    message: 'Username can only contain letters, numbers and underscores',
  })
  username: string;

  @MinLength(PASSWORD_MIN_LENGTH, {
    message: `Password must be at least ${PASSWORD_MIN_LENGTH} characters long`,
  })
  @MaxLength(128) // M2: 128 chars reasonable
  @Matches(PASSWORD_REGEX, { message: PASSWORD_REGEX_MESSAGE })
  password: string;
}
