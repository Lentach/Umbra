// backend/src/secret-notes/secret-note.entity.ts
import {
  Entity,
  PrimaryGeneratedColumn,
  Column,
  CreateDateColumn,
} from 'typeorm';

// No creator column (metadata privacy step 0, 2026-09-20): a note is a random
// token + ciphertext + expiry, owned by nobody the server knows. Account
// deletion therefore no longer cascades into notes; they expire within 24h.
@Entity('secret_notes')
export class SecretNote {
  @PrimaryGeneratedColumn()
  id: number;

  @Column({ unique: true, length: 64 })
  token: string;

  @Column({ type: 'text' })
  ciphertext: string;

  @Column({ type: 'timestamp' })
  expiresAt: Date;

  @CreateDateColumn()
  createdAt: Date;
}
