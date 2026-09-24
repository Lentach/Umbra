import { AccountAuthorization } from '../../key-bundles/account-authorization.entity';

/**
 * The wire form of an account's enrollment + signed device list, as a peer
 * needs it to run the I7 chain itself (`deviceList`, and `searchUsersResult`
 * since metadata-privacy PR3.2). `listCanonical` is the STORED base64 string
 * verbatim (falsification 23) and `enrollmentCreatedAt` the signed integer
 * milliseconds, so E re-verifies bit-for-bit. Null = not enrolled.
 */
export function deviceAuthorizationPayload(row: AccountAuthorization | null) {
  return row
    ? {
        dakPub: row.dakPub,
        enrollmentSig: row.enrollmentSig,
        enrollmentCreatedAt: row.enrollmentCreatedAt.getTime(),
        listVersion: row.listVersion,
        listSignature: row.listSignature,
        listCanonical: row.listCanonical,
      }
    : null;
}
