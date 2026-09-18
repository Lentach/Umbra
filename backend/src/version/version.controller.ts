import { Controller, Get } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

/**
 * The published APK, when there is one.
 *
 * DELIBERATELY separate from `version` above. `version` is whatever tier was
 * deployed last and the web tier deploys on its own — `0.2.50` shipped a
 * web-only boot loader with no native change at all. Driving an Android
 * update prompt off it would nag every APK user for releases that have no
 * APK behind them.
 *
 * `versionCode` is the Android packaging integer
 * (`major*1_000_000 + minor*10_000 + patch`, `build-android.ps1`), which is
 * what the installer actually compares. Semver is display only.
 */
export interface AndroidReleasePayload {
  versionCode: number;
  versionName: string;
  url: string;
}

export interface VersionPayload {
  version: string;
  gitCommit: string;
  buildTime: string;
  /** `null` until an APK is published — clients must then prompt for nothing. */
  android: AndroidReleasePayload | null;
}

@Controller('version')
export class VersionController {
  constructor(private readonly configService: ConfigService) {}

  @Get()
  getVersion(): VersionPayload {
    return {
      version: this.configService.get<string>('APP_VERSION') ?? '0.0.2',
      gitCommit: this.configService.get<string>('GIT_COMMIT') ?? 'unknown',
      buildTime: this.configService.get<string>('BUILD_TIME') ?? '',
      android: this.androidRelease(),
    };
  }

  /**
   * Reads the APK channel from env so publishing a build is an `.env` edit and
   * a backend restart — never a rebuild of either tier.
   *
   * All three must be present and the code must parse as a positive integer;
   * anything else returns `null` rather than a half-filled record, because a
   * prompt with no download URL is worse than no prompt.
   */
  private androidRelease(): AndroidReleasePayload | null {
    const rawCode = this.configService.get<string>('ANDROID_APK_VERSION_CODE');
    const versionName = this.configService.get<string>('ANDROID_APK_VERSION_NAME');
    const url = this.configService.get<string>('ANDROID_APK_URL');
    if (!rawCode || !versionName || !url) return null;

    const versionCode = Number(rawCode);
    if (!Number.isInteger(versionCode) || versionCode <= 0) return null;

    return { versionCode, versionName, url };
  }
}
