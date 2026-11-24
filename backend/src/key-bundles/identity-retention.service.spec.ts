import { Logger } from '@nestjs/common';
import { DataSource } from 'typeorm';
import { IdentityRetentionService } from './identity-retention.service';

// `repo.query()` on Postgres answers a DELETE as [rows, rowCount].
const deleted = (count: number): [unknown[], number] => [[], count];

describe('IdentityRetentionService (BE-29, decision 150)', () => {
  let query: jest.Mock;
  let service: IdentityRetentionService;
  let logSpy: jest.SpyInstance;
  let errorSpy: jest.SpyInstance;

  beforeEach(() => {
    query = jest.fn();
    service = new IdentityRetentionService({ query } as unknown as DataSource);
    logSpy = jest
      .spyOn(Logger.prototype, 'log')
      .mockImplementation(() => undefined);
    errorSpy = jest
      .spyOn(Logger.prototype, 'error')
      .mockImplementation(() => undefined);
  });

  afterEach(() => {
    logSpy.mockRestore();
    errorSpy.mockRestore();
  });

  it('prunes both tables and logs the two counts and nothing else', async () => {
    query.mockResolvedValueOnce(deleted(3)).mockResolvedValueOnce(deleted(2));

    await service.sweep();

    expect(query).toHaveBeenCalledTimes(2);
    expect(logSpy).toHaveBeenCalledTimes(1);
    expect(logSpy).toHaveBeenCalledWith(
      '[identity-retention] swept auditRows=3 resetRows=2',
    );
  });

  it('stays silent when there was nothing to prune', async () => {
    query.mockResolvedValue(deleted(0));

    await service.sweep();

    expect(logSpy).not.toHaveBeenCalled();
  });

  it('a failing audit prune does not stop the reset-request prune, and never throws into the scheduler', async () => {
    query
      .mockRejectedValueOnce(new Error('db down'))
      .mockResolvedValueOnce(deleted(4));

    await expect(service.sweep()).resolves.toBeUndefined();

    expect(query).toHaveBeenCalledTimes(2);
    expect(errorSpy).toHaveBeenCalledTimes(1);
    expect(logSpy).toHaveBeenCalledWith(
      '[identity-retention] swept auditRows=0 resetRows=4',
    );
  });
});
