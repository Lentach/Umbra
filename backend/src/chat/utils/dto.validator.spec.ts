import { BadRequestException } from '@nestjs/common';
import { IsNumber, IsPositive, IsString, MinLength } from 'class-validator';
import { validateDto } from './dto.validator';

class SimpleDto {
  @IsNumber()
  @IsPositive()
  id: number;

  @IsString()
  @MinLength(2)
  name: string;
}

describe('validateDto', () => {
  it('should return validated instance for valid data', () => {
    const data = { id: 1, name: 'Alice' };
    const result = validateDto(SimpleDto, data);
    expect(result).toBeInstanceOf(SimpleDto);
    expect(result.id).toBe(1);
    expect(result.name).toBe('Alice');
  });

  it('should accept numeric strings when they parse to valid numbers', () => {
    const data = { id: '42', name: 'Bob' };
    const result = validateDto(SimpleDto, data);
    expect(typeof result.id).toBe('number');
    expect(result.id).toBe(42);
    expect(result.name).toBe('Bob');
  });

  it('should throw BadRequestException for invalid data', () => {
    const data = { id: -1, name: 'X' };
    expect(() => validateDto(SimpleDto, data)).toThrow(BadRequestException);
    expect(() => validateDto(SimpleDto, data)).toThrow(/Validation failed/);
  });

  it('should throw for missing required fields', () => {
    const data = { id: 1 };
    expect(() => validateDto(SimpleDto, data)).toThrow(BadRequestException);
  });
});
