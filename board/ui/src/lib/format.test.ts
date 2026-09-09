import { describe, it, expect } from 'vitest';
import { ago, duration, plural, stripPrefix } from './format';

const NOW = Date.parse('2026-09-09T12:00:00Z');

describe('ago', () => {
  it('handles null', () => expect(ago(null, NOW)).toBe('—'));
  it('says just now under a minute', () => expect(ago('2026-09-09T11:59:40Z', NOW)).toBe('just now'));
  it('minutes', () => expect(ago('2026-09-09T11:56:00Z', NOW)).toBe('4m ago'));
  it('hours', () => expect(ago('2026-09-09T09:10:00Z', NOW)).toBe('2h ago'));
  it('days', () => expect(ago('2026-09-07T09:10:00Z', NOW)).toBe('2d ago'));
  it('garbage is a dash', () => expect(ago('not a date', NOW)).toBe('—'));
});

describe('plural', () => {
  it('zero takes the s', () => expect(plural(0, 'finding')).toBe('0 findings'));
  it('one does not', () => expect(plural(1, 'finding')).toBe('1 finding'));
  it('many do', () => expect(plural(4, 'ring')).toBe('4 rings'));
});

describe('stripPrefix', () => {
  it('drops the opening the row already shows', () => {
    expect(stripPrefix('scout published a.type@1 2026-09-09T12:00:00Z key=k', 'scout', 'published'))
      .toBe('a.type@1 2026-09-09T12:00:00Z key=k');
    expect(stripPrefix('bidder accepted · 2026-09-09T12:00:00Z', 'bidder', 'accepted'))
      .toBe('2026-09-09T12:00:00Z');
  });
  it('leaves a line that does not open that way', () => {
    expect(stripPrefix('bidder accepted 2026-09-09T12:00:00Z', 'closer', 'accepted'))
      .toBe('bidder accepted 2026-09-09T12:00:00Z');
    expect(stripPrefix('scoutful published a.type@1', 'scout', 'published'))
      .toBe('scoutful published a.type@1');
  });
  it('leaves the line whole when there is no kind to strip', () => {
    expect(stripPrefix('scout published a.type@1', 'scout', null))
      .toBe('scout published a.type@1');
  });
});

describe('duration', () => {
  it('null', () => expect(duration(null)).toBe('—'));
  it('seconds', () => expect(duration(45)).toBe('45s'));
  it('minutes', () => expect(duration(720)).toBe('12m'));
  it('hours', () => expect(duration(3 * 3600 + 5)).toBe('3h'));
  it('days', () => expect(duration(2 * 86400 + 100)).toBe('2d'));
});
