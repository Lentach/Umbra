import { Test } from '@nestjs/testing';
import { ConfigService } from '@nestjs/config';
import { VersionController } from './version.controller';

describe('VersionController', () => {
  let controller: VersionController;

  const createModule = (env: Record<string, string | undefined>) => {
    return Test.createTestingModule({
      controllers: [VersionController],
      providers: [
        {
          provide: ConfigService,
          useValue: {
            get: (key: string) => env[key],
          },
        },
      ],
    }).compile();
  };

  it('returns version metadata from environment', async () => {
    const module = await createModule({
      APP_VERSION: '1.2.3',
      GIT_COMMIT: 'abc1234',
      BUILD_TIME: '2026-05-22T12:00:00Z',
    });
    controller = module.get(VersionController);

    expect(controller.getVersion()).toEqual({
      version: '1.2.3',
      gitCommit: 'abc1234',
      buildTime: '2026-05-22T12:00:00Z',
      android: null,
    });
  });

  it('returns defaults when env vars are unset', async () => {
    const module = await createModule({});
    controller = module.get(VersionController);

    expect(controller.getVersion()).toEqual({
      version: '0.0.2',
      gitCommit: 'unknown',
      buildTime: '',
      android: null,
    });
  });

  it('publishes the APK channel once all three vars are set', async () => {
    const module = await createModule({
      ANDROID_APK_VERSION_CODE: '20050',
      ANDROID_APK_VERSION_NAME: '0.2.50',
      ANDROID_APK_URL: 'https://example.invalid/umbra-0.2.50.apk',
    });
    controller = module.get(VersionController);

    expect(controller.getVersion().android).toEqual({
      versionCode: 20050,
      versionName: '0.2.50',
      url: 'https://example.invalid/umbra-0.2.50.apk',
    });
  });

  // A half-filled channel must read as "nothing published": a prompt the user
  // cannot act on is worse than staying quiet.
  it.each([
    ['no url', { ANDROID_APK_VERSION_CODE: '20050', ANDROID_APK_VERSION_NAME: '0.2.50' }],
    ['no code', { ANDROID_APK_VERSION_NAME: '0.2.50', ANDROID_APK_URL: 'https://e.invalid/a.apk' }],
    [
      'unparsable code',
      {
        ANDROID_APK_VERSION_CODE: 'latest',
        ANDROID_APK_VERSION_NAME: '0.2.50',
        ANDROID_APK_URL: 'https://e.invalid/a.apk',
      },
    ],
    [
      'zero code',
      {
        ANDROID_APK_VERSION_CODE: '0',
        ANDROID_APK_VERSION_NAME: '0.2.50',
        ANDROID_APK_URL: 'https://e.invalid/a.apk',
      },
    ],
  ])('withholds the channel when %s', async (_label, env) => {
    const module = await createModule(env);
    controller = module.get(VersionController);

    expect(controller.getVersion().android).toBeNull();
  });
});
