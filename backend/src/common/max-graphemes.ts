import {
  registerDecorator,
  ValidationArguments,
  ValidationOptions,
} from 'class-validator';

const graphemes = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

/**
 * At most `max` user-perceived characters (extended grapheme clusters), what
 * the user counts: a heart + U+FE0F or a family emoji is ONE. Always pair it
 * with `MaxCodePoints`: a cluster has no upper size (a letter plus 700
 * combining marks is one).
 */
export function MaxGraphemes(
  max: number,
  validationOptions?: ValidationOptions,
) {
  return (object: object, propertyName: string): void => {
    registerDecorator({
      name: 'maxGraphemes',
      target: object.constructor,
      propertyName,
      constraints: [max],
      options: validationOptions,
      validator: {
        validate(value: unknown): boolean {
          return (
            typeof value === 'string' &&
            Array.from(graphemes.segment(value)).length <= max
          );
        },
        defaultMessage(args?: ValidationArguments): string {
          return `${args?.property} must be at most ${max} characters`;
        },
      },
    });
  };
}
