import { IsString, Matches, MaxLength, MinLength } from 'class-validator';

export class LoginDto {
  @IsString()
  @MinLength(3)
  @MaxLength(25)
  @Matches(/^[a-zA-Z0-9_]+(#[0-9]{4})?$/, {
    message: 'Use username or username#tag (e.g. john#0427)',
  })
  identifier: string;

  @IsString()
  @MaxLength(128) // M2: 128 chars reasonable for user input
  password: string;
}
