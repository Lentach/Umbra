import {
  IsBoolean,
  IsNotEmpty,
  IsOptional,
  IsString,
  MinLength,
} from 'class-validator';

export class RefreshBodyDto {
  @IsString()
  @IsNotEmpty()
  @MinLength(32)
  refresh_token!: string;

  /**
   * `/auth/refresh` only: the client stores whatever `refresh_token` comes
   * back, so the session's token may rotate (plan B4). Absent on web, on
   * builds before 0.2.88, and on native after a refused token write: their
   * token stays, only the expiry slides.
   */
  @IsOptional()
  @IsBoolean()
  rotate?: boolean;
}
