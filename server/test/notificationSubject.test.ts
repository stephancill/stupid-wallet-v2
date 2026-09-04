import { describe, expect, it } from 'vitest';
import { notificationSubject } from '../src/services/notificationSubject';
import type { WebhookEvent } from '../src/schemas';
import { createTestDb } from './helpers';

const event = (overrides: Partial<WebhookEvent> = {}): WebhookEvent => ({
  eventId: 'event-1',
  eventType: 'activity.observed',
  observationId: 'observation-1',
  chainId: '1',
  address: '0x1111111111111111111111111111111111111111',
  transactionValue: '1000000000000000000',
  initiatedByTrackedAddress: false,
  ...overrides,
});

const prices =
  (entries: Record<string, { symbol: string; decimals: number; price: number }>) =>
  async (input: string): Promise<Response> => {
    const key = input.split('/').at(-1) ?? '';
    const coin = entries[key];
    return coin ? Response.json({ coins: { [key]: coin } }) : new Response('', { status: 404 });
  };

describe('notification subject enrichment', () => {
  it('adds the native asset and rounded USD value', async () => {
    const subject = await notificationSubject({
      db: createTestDb(),
      event: event(),
      eventKind: 'nativeReceived',
      now: 1_000,
      fetchImpl: prices({
        'ethereum:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee': {
          symbol: 'ETH',
          decimals: 18,
          price: 2_500,
        },
      }),
    });
    expect(subject).toBe('Received $2,500 of ETH');
  });

  it('pairs priced incoming and outgoing effects as a swap', async () => {
    const subject = await notificationSubject({
      db: createTestDb(),
      event: event({
        chainId: '8453',
        transactionValue: '0',
        initiatedByTrackedAddress: true,
        effects: [
          {
            kind: 'erc20',
            direction: 'outgoing',
            assetAddress: '0x1111111111111111111111111111111111111111',
            amount: '50000000',
          },
          {
            kind: 'erc20',
            direction: 'incoming',
            assetAddress: '0x2222222222222222222222222222222222222222',
            amount: '20000000000000000',
          },
        ],
      }),
      eventKind: 'tokenSent',
      now: 1_000,
      fetchImpl: prices({
        'base:0x1111111111111111111111111111111111111111': {
          symbol: 'USDC',
          decimals: 6,
          price: 1,
        },
        'base:0x2222222222222222222222222222222222222222': {
          symbol: 'WETH',
          decimals: 18,
          price: 2_500,
        },
      }),
    });
    expect(subject).toBe('Swapped 50 USDC for 0.02 WETH');
  });

  it('uses the categorical title when enrichment is unavailable', async () => {
    const subject = await notificationSubject({
      db: createTestDb(),
      event: event(),
      eventKind: 'nativeReceived',
      now: 1_000,
      fetchImpl: prices({}),
    });
    expect(subject).toBe('Received funds');
  });

  it('uses the categorical title for an unsafe asset symbol', async () => {
    const subject = await notificationSubject({
      db: createTestDb(),
      event: event(),
      eventKind: 'nativeReceived',
      now: 1_000,
      fetchImpl: prices({
        'ethereum:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee': {
          symbol: '<script>',
          decimals: 18,
          price: 2_500,
        },
      }),
    });
    expect(subject).toBe('Received funds');
  });

  it('does not replace failure and reorg titles with transfer details', async () => {
    const subject = await notificationSubject({
      db: createTestDb(),
      event: event(),
      eventKind: 'activityReverted',
      now: 1_000,
      fetchImpl: prices({}),
    });
    expect(subject).toBe('Activity reverted');
  });
});
