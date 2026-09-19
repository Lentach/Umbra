import { validate } from 'class-validator';
import { plainToInstance } from 'class-transformer';
import { AddReactionDto, RemoveReactionDto, SendMessageDto } from './chat.dto';
import { ClearChatHistoryDto } from './clear-chat-history.dto';
import { DeleteConversationOnlyDto } from './delete-conversation-only.dto';
import { EditMessageDto } from './edit-message.dto';
import { SetDisappearingTimerDto } from './set-disappearing-timer.dto';
import { validateDto } from '../utils/dto.validator';

function createDto(data: Partial<SendMessageDto>): SendMessageDto {
  return plainToInstance(SendMessageDto, data);
}

describe('SendMessageDto', () => {
  describe('unencrypted messages', () => {
    it('should accept valid TEXT message', async () => {
      const dto = createDto({ recipientId: 1, content: 'Hello!' });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });

    it('should reject empty content for TEXT', async () => {
      const dto = createDto({ recipientId: 1, content: '' });
      const errors = await validate(dto);
      expect(errors.length).toBeGreaterThan(0);
    });

    it('should accept empty content for VOICE', async () => {
      const dto = createDto({
        recipientId: 1,
        content: '',
        messageType: 'VOICE',
        mediaUrl: 'https://res.cloudinary.com/demo/video/upload/v1/a.m4a',
      });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });

    it('should accept empty content for PING', async () => {
      const dto = createDto({
        recipientId: 1,
        content: '',
        messageType: 'PING',
      });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });

    it('should accept empty content for VIDEO', async () => {
      const dto = createDto({
        recipientId: 1,
        content: '',
        messageType: 'VIDEO',
        mediaUrl: 'http://localhost:3000/media/msgs/video.bin',
        mediaDuration: 30,
      });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });
  });

  describe('encrypted messages (E2E)', () => {
    it('should accept encrypted message without content validation', async () => {
      const dto = createDto({
        recipientId: 1,
        content: '[encrypted]',
        encryptedContent: '3:base64ciphertext==',
      });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });

    it('should accept encrypted message with empty content', async () => {
      const dto = createDto({
        recipientId: 1,
        content: '',
        encryptedContent: '3:base64ciphertext==',
      });
      const errors = await validate(dto);
      // encryptedContent present -> content validation skipped
      expect(errors).toHaveLength(0);
    });

    it('should accept encrypted PING (no content, no mediaUrl)', async () => {
      const dto = createDto({
        recipientId: 1,
        content: '[encrypted]',
        encryptedContent: '3:pingCipher==',
        // No messageType or mediaUrl — hidden in envelope
      });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });

    it('should accept encrypted VOICE with self-hosted mediaUrl', async () => {
      const dto = createDto({
        recipientId: 1,
        content: '[encrypted]',
        encryptedContent: '3:voiceCipher==',
        messageType: 'VOICE',
        mediaUrl: 'http://localhost:3000/media/msgs/voice.bin',
        mediaDuration: 5,
      });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });

    it('should accept encrypted VIDEO with self-hosted mediaUrl', async () => {
      const dto = createDto({
        recipientId: 1,
        content: '[encrypted]',
        encryptedContent: '3:videoCipher==',
        messageType: 'VIDEO',
        mediaUrl: 'http://localhost:3000/media/msgs/video.bin',
        mediaDuration: 30,
      });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });

    it('should accept encrypted IMAGE with self-hosted mediaUrl', async () => {
      const dto = createDto({
        recipientId: 1,
        content: '[encrypted]',
        encryptedContent: '3:imageCipher==',
        messageType: 'IMAGE',
        mediaUrl: 'http://localhost:3000/media/msgs/image.bin',
      });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });

    it('should accept encrypted FILE with self-hosted mediaUrl', async () => {
      const dto = createDto({
        recipientId: 1,
        content: '[encrypted]',
        encryptedContent: '3:fileCipher==',
        messageType: 'FILE',
        mediaUrl: 'http://localhost:3000/media/msgs/file.bin',
      });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });

    it('should reject non-allowlisted mediaUrl even with encryptedContent', async () => {
      const dto = createDto({
        recipientId: 1,
        content: '[encrypted]',
        encryptedContent: '3:cipher==',
        mediaUrl: 'https://evil.com/malware.exe',
      });
      const errors = await validate(dto);
      expect(errors.length).toBeGreaterThan(0);
      const mediaUrlError = errors.find((e) => e.property === 'mediaUrl');
      expect(mediaUrlError).toBeDefined();
    });

    it('should accept Cloudinary mediaUrl with encryptedContent', async () => {
      const dto = createDto({
        recipientId: 1,
        content: '[encrypted]',
        encryptedContent: '3:cipher==',
        mediaUrl:
          'https://res.cloudinary.com/demo/video/upload/v1/voice/abc.m4a',
      });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });
  });

  describe('messageType validation', () => {
    it('rejects an unknown messageType', async () => {
      const dto = createDto({ content: 'hi', messageType: 'BOGUS' });
      const errors = await validate(dto);
      expect(errors.some((e) => e.property === 'messageType')).toBe(true);
    });

    it('accepts a valid enum messageType', async () => {
      const dto = createDto({ content: 'hi', messageType: 'IMAGE' });
      const errors = await validate(dto);
      expect(errors.some((e) => e.property === 'messageType')).toBe(false);
    });
  });

  describe('mediaUrl validation', () => {
    it('should reject non-allowlisted media URL', async () => {
      const dto = createDto({
        recipientId: 1,
        content: '',
        messageType: 'VOICE',
        mediaUrl: 'https://evil.com/payload.mp3',
      });
      const errors = await validate(dto);
      const mediaUrlError = errors.find((e) => e.property === 'mediaUrl');
      expect(mediaUrlError).toBeDefined();
    });

    it('should accept valid Cloudinary image URL', async () => {
      const dto = createDto({
        recipientId: 1,
        content: 'image caption',
        messageType: 'IMAGE',
        mediaUrl:
          'https://res.cloudinary.com/demo/image/upload/v1/photos/pic.jpg',
      });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });

    it('should accept null/undefined mediaUrl', async () => {
      const dto = createDto({
        recipientId: 1,
        content: 'hello',
      });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });

    it('should accept self-hosted media URL', async () => {
      const base = process.env.MEDIA_BASE_URL ?? 'http://localhost:3000';
      const dto = createDto({
        recipientId: 1,
        content: 'caption',
        messageType: 'IMAGE',
        mediaUrl: `${base}/media/msgs/abc.bin`,
      });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });

    it('should accept Cloudinary raw/upload URL (FILE backward compat)', async () => {
      const dto = createDto({
        recipientId: 1,
        content: 'file.pdf',
        messageType: 'FILE',
        mediaUrl: 'https://res.cloudinary.com/demo/raw/upload/sample.pdf',
      });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    });

    it('should reject an internal/loopback SSRF target (metadata endpoint)', async () => {
      const dto = createDto({
        recipientId: 1,
        content: '',
        messageType: 'VOICE',
        // Distinct SSRF vector: cloud metadata / link-local host, not a generic evil.com host.
        mediaUrl: 'http://169.254.169.254/latest/meta-data/',
      });
      const errors = await validate(dto);
      const mediaUrlError = errors.find((e) => e.property === 'mediaUrl');
      expect(mediaUrlError).toBeDefined();
    });
  });

  // H-02: a self-hosted mediaUrl is later turned into a filesystem path and
  // unlinked. The regex must forbid path traversal / nested paths so a crafted
  // mediaUrl cannot delete arbitrary files.
  describe('mediaUrl path-traversal rejection (H-02)', () => {
    const base = process.env.MEDIA_BASE_URL ?? 'http://localhost:3000';

    async function mediaUrlRejected(mediaUrl: string): Promise<boolean> {
      const dto = createDto({
        recipientId: 1,
        content: '[encrypted]',
        encryptedContent: '3:cipher==',
        messageType: 'FILE',
        mediaUrl,
      });
      const errors = await validate(dto);
      return errors.some((e) => e.property === 'mediaUrl');
    }

    it('rejects ../ escaping the media root', async () => {
      expect(await mediaUrlRejected(`${base}/media/../../../etc/passwd`)).toBe(
        true,
      );
    });

    it('rejects a msgs/.. traversal', async () => {
      expect(
        await mediaUrlRejected(`${base}/media/msgs/../../etc/passwd`),
      ).toBe(true);
    });

    it('rejects nested sub-paths under msgs (extra slashes)', async () => {
      expect(await mediaUrlRejected(`${base}/media/msgs/sub/dir/x.bin`)).toBe(
        true,
      );
    });

    it('still accepts a normal single-segment msgs blob', async () => {
      expect(await mediaUrlRejected(`${base}/media/msgs/a1b2-c3d4.bin`)).toBe(
        false,
      );
    });

    it('still accepts a normal avatar blob', async () => {
      expect(await mediaUrlRejected(`${base}/media/avatars/abc123.jpg`)).toBe(
        false,
      );
    });
  });
});

describe('Reaction DTOs', () => {
  // D10 closed 2026-09-19: the compat window that also accepted a plain emoji
  // grapheme (design §3.3) is over. A legacy emoji — simple, ZWJ family,
  // tag-sequence flag — is REFUSED on both events, never stored in the clear.
  const legacyEmojiCases = ['👍', '👨‍👩‍👧‍👦', '🏴󠁧󠁢󠁳󠁣󠁴󠁿'];
  const invalidCases = ['hi', '😀😀', '123', '#', '', ' ', '👍 reaction'];

  it.each([...legacyEmojiCases, ...invalidCases])(
    'should reject a non-token reaction: %s',
    async (emoji) => {
      expect(
        (
          await validate(
            plainToInstance(AddReactionDto, { messageId: 1, emoji }),
          )
        ).length,
      ).toBeGreaterThan(0);
      expect(
        (
          await validate(
            plainToInstance(RemoveReactionDto, { messageId: 1, emoji }),
          )
        ).length,
      ).toBeGreaterThan(0);
    },
  );

  const tokenCases = [
    'AAAAAAAAAAAAAAAAAAAAAA',
    '0123456789abcdefABCDEF',
    '-_-_-_-_-_-_-_-_-_-_-_',
  ];
  // A token is 16 bytes of HMAC in base64url — exactly 22 characters. A
  // shorter one is a truncation (R6: collisions merge two emoji into one
  // chip); a longer one is not a token at all.
  const nonTokenCases = [
    'AAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAA+/',
  ];

  it.each(tokenCases)(
    'should accept a blinded reaction token: %s',
    async (emoji) => {
      expect(
        await validate(
          plainToInstance(AddReactionDto, { messageId: 1, emoji }),
        ),
      ).toHaveLength(0);
      expect(
        await validate(
          plainToInstance(RemoveReactionDto, { messageId: 1, emoji }),
        ),
      ).toHaveLength(0);
    },
  );

  it.each(nonTokenCases)(
    'should reject a mis-sized token shape: %s',
    async (emoji) => {
      expect(
        (
          await validate(
            plainToInstance(AddReactionDto, { messageId: 1, emoji }),
          )
        ).length,
      ).toBeGreaterThan(0);
      expect(
        (
          await validate(
            plainToInstance(RemoveReactionDto, { messageId: 1, emoji }),
          )
        ).length,
      ).toBeGreaterThan(0);
    },
  );
});

// BE-553: id fields were under-constrained (@IsNumber/@IsInt only), accepting
// negative, zero and (for @IsNumber) float ids. They now match the house
// standard `@IsInt() @IsPositive()` used by served-message-ids/pin-message.
describe('Id-field constraints (BE-553)', () => {
  // [dtoClass, id property name]
  const idDtos: [new () => object, string][] = [
    [ClearChatHistoryDto, 'conversationId'],
    [DeleteConversationOnlyDto, 'conversationId'],
    [SetDisappearingTimerDto, 'conversationId'],
    [EditMessageDto, 'messageId'],
  ];

  // A valid sibling payload so only the id field under test can fail.
  const validExtras = (prop: string): Record<string, unknown> =>
    prop === 'messageId' ? { encryptedContent: '3:cipher==' } : {};

  describe.each(idDtos)('%p', (dtoClass, prop) => {
    it.each([-1, 0, 1.5, -2.5])(
      'rejects a non-positive-int %s',
      async (bad) => {
        const dto = plainToInstance(dtoClass, {
          [prop]: bad,
          ...validExtras(prop),
        });
        const errors = await validate(dto);
        expect(errors.some((e) => e.property === prop)).toBe(true);
      },
    );

    it('accepts a positive integer id', async () => {
      const dto = plainToInstance(dtoClass, {
        [prop]: 42,
        ...validExtras(prop),
      });
      const errors = await validate(dto);
      expect(errors.some((e) => e.property === prop)).toBe(false);
    });

    it('coerces a string-numeric id from socket input (WS validator)', async () => {
      // The WS validator uses enableImplicitConversion, so '42' -> 42 and passes.
      const instance = validateDto(dtoClass, {
        [prop]: '42',
        ...validExtras(prop),
      }) as Record<string, unknown>;
      expect(instance[prop]).toBe(42);
    });

    it('rejects a string-numeric negative id from socket input (WS validator)', () => {
      expect(() =>
        validateDto(dtoClass, { [prop]: '-1', ...validExtras(prop) }),
      ).toThrow();
    });
  });
});
