import { Check, Column, Entity, PrimaryColumn } from 'typeorm';

/**
 * The box's running totals, ONE row (`id = 1`): what the global ceiling
 * (decision 30) is checked against. `msgCount` counts every `box_msgs` row,
 * `mediaBytes` every `box_media` row at its rung size. A counter, not a
 * count: a send reads and bumps one primary-key row, never a table scan.
 *
 * Prod truth is migration 0024 (which seeds the row); dev `synchronize` runs
 * after the runner, so every name here matches that file exactly.
 */
@Entity('box_totals')
@Check('ck_box_totals_one_row', '"id" = 1')
export class BoxTotals {
  @PrimaryColumn({
    type: 'smallint',
    primaryKeyConstraintName: 'pk_box_totals',
  })
  id: number;

  @Column({ type: 'int', default: 0 })
  msgCount: number;

  /** Postgres `bigint`: 2 GiB does not fit an `integer`; pg hands it back as a string. */
  @Column({ type: 'bigint', default: 0 })
  mediaBytes: string;
}
