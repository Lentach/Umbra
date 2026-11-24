export const PASSWORD_MIN_LENGTH = 8;

/**
 * Requires at least one lowercase letter, one uppercase letter, and one digit.
 * Allows any characters (no whitelist restriction).
 */
export const PASSWORD_REGEX = /^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).+$/;

export const PASSWORD_REGEX_MESSAGE =
  'Password must contain at least one uppercase letter, one lowercase letter, and one number';
