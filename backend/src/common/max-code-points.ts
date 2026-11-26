import {
  registerDecorator,
  ValidationArguments,
  ValidationOptions,
} from 'class-validator';

/**
 * At most `max` Unicode code points. `@MaxLength` is NOT a stand-in for a
 * `varchar(n)` column: it goes through `validator.isLength`, which counts a
 * base character plus a variation selector (U+FE0F) as ONE, so 80 hearts
 * with U+FE0F (160 code points) pass it and the INSERT fails with a 500.
 * Non-strings fail; pair with `@IsString()` for the clearer message.
 */
export function MaxCodePoints(
  max: number,
  validationOptions?: ValidationOptions,
) {
  return (object: object, propertyName: string): void => {
    registerDecorator({
      name: 'maxCodePoints',
      target: object.constructor,
      propertyName,
      constraints: [max],
      options: validationOptions,
      validator: {
        validate(value: unknown): boolean {
          return typeof value === 'string' && Array.from(value).length <= max;
        },
        defaultMessage(args?: ValidationArguments): string {
          return `${args?.property} must be at most ${max} code points`;
        },
      },
    });
  };
}
