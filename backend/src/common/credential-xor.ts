import {
  registerDecorator,
  ValidationArguments,
  ValidationOptions,
} from 'class-validator';

/** base64 of exactly 32 bytes: 43 symbols plus one `=`. */
export const AUTH_SECRET_PATTERN = /^[A-Za-z0-9+/]{43}=$/;

/**
 * Plan B7: a recovery credential travels as EITHER the legacy plaintext
 * `phrase` field OR the client-derived `authSecret`, never both and (where
 * `required`) never neither. Put on the `authSecret`-style field; the other
 * field keeps its own `@IsOptional()` rules.
 *
 * It must be a custom validator: `@IsOptional()` skips every other decorator
 * on an absent field, which is exactly the "neither present" case.
 * `isValid` runs on the field's own value when it is present.
 */
export function CredentialXor(
  other: string,
  options: { required: boolean; isValid: (value: unknown) => boolean },
  validationOptions?: ValidationOptions,
) {
  return (object: object, propertyName: string): void => {
    registerDecorator({
      name: 'credentialXor',
      target: object.constructor,
      propertyName,
      constraints: [other],
      options: validationOptions,
      validator: {
        validate(value: unknown, args?: ValidationArguments): boolean {
          const peer = (args?.object as Record<string, unknown>)[other];
          const mine = value !== undefined && value !== null;
          const theirs = peer !== undefined && peer !== null;
          if (mine && theirs) return false;
          if (!mine && !theirs) return !options.required;
          return !mine || options.isValid(value);
        },
        defaultMessage(args?: ValidationArguments): string {
          return options.required
            ? `exactly one of ${args?.property} and ${other} is required`
            : `${args?.property} and ${other} are mutually exclusive`;
        },
      },
    });
  };
}
