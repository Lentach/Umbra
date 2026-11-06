import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import * as fs from 'fs/promises';
import * as path from 'path';
import { randomUUID } from 'crypto';

export interface UploadAvatarResult {
  secureUrl: string;
  publicId: string;
}

/**
 * Self-hosted avatar storage under `MEDIA_DIR/avatars/`. Message attachments
 * no longer pass through the server's account-keyed storage: old-path `msgs/`
 * uploads were removed in Phase 4 step 5 and box media lives under
 * `MEDIA_DIR/box/` (its own store).
 */
@Injectable()
export class LocalStorageService {
  private readonly baseUrl: string;
  private readonly mediaDir: string;

  constructor(private configService: ConfigService) {
    this.baseUrl = configService.get<string>(
      'MEDIA_BASE_URL',
      'http://localhost:3000',
    );
    this.mediaDir = configService.get<string>('MEDIA_DIR', '/app/media');
  }

  async uploadAvatar(
    userId: number,
    buffer: Buffer,
    mimeType: string,
  ): Promise<UploadAvatarResult> {
    const ext = mimeType.includes('png') ? 'png' : 'jpg';
    const filename = `${randomUUID()}.${ext}`;
    const publicId = `avatars/${filename}`;
    await fs.mkdir(path.join(this.mediaDir, 'avatars'), { recursive: true });
    await fs.writeFile(path.join(this.mediaDir, publicId), buffer, {
      mode: 0o644,
    });
    return { secureUrl: `${this.baseUrl}/media/${publicId}`, publicId };
  }

  async deleteAvatar(publicId: string): Promise<void> {
    await this.deleteFile(publicId);
  }

  /** publicId = relative path like 'avatars/uuid.jpg'.
   *  Full Cloudinary URLs are skipped (legacy avatars). ENOENT is silently ignored. */
  async deleteFile(publicId: string): Promise<void> {
    if (publicId.startsWith('http')) return;
    // H-02 defense in depth: never unlink outside mediaDir, even if a crafted
    // publicId (e.g. '../../etc/passwd') slips past mediaUrl validation. Gate on
    // a resolved-path containment check; the unlink itself keeps using
    // path.join so the on-disk target is unchanged for legitimate ids.
    const root = path.resolve(this.mediaDir);
    const rel = path.relative(root, path.resolve(this.mediaDir, publicId));
    if (rel === '' || rel.startsWith('..') || path.isAbsolute(rel)) {
      return;
    }
    try {
      await fs.unlink(path.join(this.mediaDir, publicId));
    } catch (err: any) {
      if (err?.code !== 'ENOENT') throw err;
    }
  }
}
