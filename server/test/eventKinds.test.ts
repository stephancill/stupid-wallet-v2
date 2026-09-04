import { describe, expect, it } from 'vitest';
import { EVENT_KINDS, eventTitle } from '../src/services/eventKinds';

describe('notification event titles', () => {
  it('maps every bounded event kind to the Swift presentation title', () => {
    expect(EVENT_KINDS.map(eventTitle)).toEqual([
      'Received funds',
      'Sent funds',
      'Token received',
      'Token sent',
      'NFT received',
      'NFT sent',
      'Transaction sent',
      'Transaction failed',
      'Activity reverted',
      'Wallet activity',
    ]);
  });

  it('fails closed to the generic title for an unknown kind', () => {
    expect(eventTitle('futureKind')).toBe('Wallet activity');
  });
});
