import { Module } from '@nestjs/common';
import { BoxDelivery } from './box-delivery.service';
import { BoxMediaController } from './box-media.controller';
import { BoxMediaStore } from './box-media.store';
import { BoxNotifierService } from './box-notifier.service';
import {
  BOX_PUSH_TRANSPORT,
  FirebaseWebPushTransport,
} from './box-push.transport';
import { BoxReaper } from './box-reaper.service';
import { BoxGateway } from './box.gateway';
import {
  BOX_GLOBAL_MEDIA_CEILING_BYTES,
  BOX_GLOBAL_MSG_CEILING,
} from './box.constants';
import { BOX_CEILING, BoxService, type BoxCeiling } from './box.service';
import { BoxMedia } from './entities/box-media.entity';
import { BoxMsg } from './entities/box-msg.entity';
import { BoxNotifier } from './entities/box-notifier.entity';
import { BoxQueue } from './entities/box-queue.entity';
import { BoxTotals } from './entities/box-totals.entity';

/** The box's tables, for the root TypeORM config (AppModule, the integration suite). */
export const BOX_ENTITIES = [
  BoxQueue,
  BoxMsg,
  BoxMedia,
  BoxNotifier,
  BoxTotals,
];

/**
 * The box: a second logical service in the same process (design §4.1). It
 * reads its tables through the root `DataSource` and depends on nothing but
 * `common/` and config — never on `auth/`, `users/` or `chat/` (I1).
 *
 * Its HTTP routes are throttled by the app's global `HttpThrottlerGuard`
 * (per-route limits and tracker on the controller) — which is also why
 * `POST /box/media` has no body parser: the controller reads the body only
 * after that guard ran. Its socket events are throttled by
 * `BoxThrottlerGuard`.
 */
@Module({
  controllers: [BoxMediaController],
  providers: [
    BoxService,
    BoxDelivery,
    BoxNotifierService,
    BoxMediaStore,
    BoxReaper,
    BoxGateway,
    { provide: BOX_PUSH_TRANSPORT, useClass: FirebaseWebPushTransport },
    {
      provide: BOX_CEILING,
      useValue: {
        msgs: BOX_GLOBAL_MSG_CEILING,
        mediaBytes: BOX_GLOBAL_MEDIA_CEILING_BYTES,
      } satisfies BoxCeiling,
    },
  ],
})
export class BoxModule {}
