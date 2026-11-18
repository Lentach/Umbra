import {
  Entity,
  PrimaryGeneratedColumn,
  Column,
  CreateDateColumn,
  Unique,
  OneToMany,
} from 'typeorm';
import { ProfilePhoto } from './profile-photo.entity';

@Entity('users')
@Unique(['username', 'tag'])
export class User {
  @PrimaryGeneratedColumn()
  id: number;

  @Column()
  username: string;

  @Column({ length: 4, default: '0000' })
  tag: string;

  // Argon2id PHC string (legacy rows: bcrypt `$2…`, rehashed at next login) — never plain text
  @Column()
  password: string;

  @Column({ type: 'varchar', nullable: true })
  profilePictureUrl: string | null;

  @Column({ type: 'varchar', nullable: true })
  profilePicturePublicId: string | null;

  @Column({ type: 'varchar', length: 80, nullable: true })
  about: string | null;

  @OneToMany(() => ProfilePhoto, (photo) => photo.user)
  profilePhotos: ProfilePhoto[];

  @CreateDateColumn()
  createdAt: Date;

  @Column({ type: 'timestamp', nullable: true })
  passwordChangedAt: Date | null;

  /**
   * The per-account deviceId allocator (Phase 2, spec §12 Stage-0 amendment
   * (a), migration 0016). Every existing account is single-device device 1,
   * so the NEXT id is 2 — the default IS the backfill. Allocation is one
   * atomic UPDATE ... RETURNING (DevicesService.allocateDeviceId); the value
   * only ever grows — gaps from aborted ceremonies are expected and safe
   * (monotonic-never-reused, not dense).
   */
  @Column({ default: 2 })
  nextDeviceId: number;
}
