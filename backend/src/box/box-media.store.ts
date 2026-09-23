import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { randomUUID } from 'crypto';
import { createReadStream, createWriteStream, type ReadStream } from 'fs';
import type { Readable } from 'stream';
import { pipeline } from 'stream/promises';
import * as fs from 'fs/promises';
import * as path from 'path';

/**
 * Box media on disk, under `MEDIA_DIR/box/` — its own directory on purpose:
 * `MediaCleanupService` deletes every file in `msgs/` that no `messages` row
 * references, which would be every box file. The filename is a fresh UUID,
 * never the capability id, so a directory listing grants no downloads.
 */
@Injectable()
export class BoxMediaStore {
  private readonly root: string;

  constructor(config: ConfigService) {
    this.root = path.resolve(
      config.get<string>('MEDIA_DIR', '/app/media'),
      'box',
    );
  }

  /** A fresh path, relative to the box directory. */
  newPath(): string {
    return `${randomUUID()}.bin`;
  }

  /**
   * Streams `source` to a new file; true only when exactly `bytes` landed.
   * An aborted or short upload leaves no file behind.
   */
  async writeFrom(
    relative: string,
    source: Readable,
    bytes: number,
  ): Promise<boolean> {
    const full = this.contained(relative);
    if (!full) throw new Error('box media path escapes its directory');
    await fs.mkdir(this.root, { recursive: true });
    const sink = createWriteStream(full, { flags: 'wx', mode: 0o600 });
    try {
      await pipeline(source, sink);
    } catch {
      await this.remove(relative);
      return false;
    }
    if (sink.bytesWritten === bytes) return true;
    await this.remove(relative);
    return false;
  }

  async open(
    relative: string,
  ): Promise<{ stream: ReadStream; size: number } | null> {
    const full = this.contained(relative);
    if (!full) return null;
    try {
      const { size } = await fs.stat(full);
      return { stream: createReadStream(full), size };
    } catch (error) {
      // fs/promises rejects with an ErrnoException.
      const failure = error as NodeJS.ErrnoException;
      if (failure.code === 'ENOENT') return null;
      throw error;
    }
  }

  /** Missing is fine: the row may have outlived a crash between its insert and the write. */
  async remove(relative: string): Promise<void> {
    const full = this.contained(relative);
    if (!full) return;
    try {
      await fs.unlink(full);
    } catch (error) {
      // fs/promises rejects with an ErrnoException.
      const failure = error as NodeJS.ErrnoException;
      if (failure.code !== 'ENOENT') throw error;
    }
  }

  /** The absolute path when it stays inside the box directory; else null. */
  private contained(relative: string): string | null {
    const full = path.resolve(this.root, relative);
    const rel = path.relative(this.root, full);
    return rel === '' || rel.startsWith('..') || path.isAbsolute(rel)
      ? null
      : full;
  }
}
