import { describe, expect, it } from 'vitest';
import { notificationSummary } from '../src/services/notificationSubject';
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
    const { subject } = await notificationSummary({
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
    const { subject } = await notificationSummary({
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
    const { subject } = await notificationSummary({
      db: createTestDb(),
      event: event(),
      eventKind: 'nativeReceived',
      now: 1_000,
      fetchImpl: prices({}),
    });
    expect(subject).toBe('Received funds');
  });

  it('uses the categorical title for an unsafe asset symbol', async () => {
    const { subject } = await notificationSummary({
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
    const { subject } = await notificationSummary({
      db: createTestDb(),
      event: event(),
      eventKind: 'activityReverted',
      now: 1_000,
      fetchImpl: prices({}),
    });
    expect(subject).toBe('Activity reverted');
  });
});

const tokenAddress = '0x2222222222222222222222222222222222222222';
const receipt = (amount: string, direction = 'incoming') => ({
  kind: 'erc20',
  direction,
  amount,
  assetAddress: tokenAddress,
});

describe('received token alert policy', () => {
  it.each([
    ['0', false],
    ['1', false],
    ['499999', false],
    ['500000', false],
    ['500001', true],
    ['510000', true],
    ['5000000', true],
  ])('filters raw USDC amount %s with a strict $0.50 threshold', async (amount, expected) => {
    const result = await notificationSummary({
      db: createTestDb(),
      event: event({ chainId: '10', transactionValue: '0', effects: [receipt(amount)] }),
      eventKind: 'tokenReceived',
      now: 1_000,
      fetchImpl: prices({
        [`optimism:${tokenAddress}`]: { symbol: 'USDC', decimals: 6, price: 1 },
      }),
    });
    expect(result.shouldNotify).toBe(expected);
    if (amount === '510000') expect(result.subject).toBe('Received $0.51 of USDC');
    if (amount === '5000000') expect(result.subject).toBe('Received $5 of USDC');
  });

  it.each([false, true])(
    'keeps the initiation exemption when prices fail: %s',
    async (initiated) => {
      const result = await notificationSummary({
        db: createTestDb(),
        event: event({
          transactionValue: '0',
          initiatedByTrackedAddress: initiated,
          effects: [receipt('1')],
        }),
        eventKind: 'tokenReceived',
        now: 1_000,
        fetchImpl: async () => {
          throw new Error('price service unavailable');
        },
      });
      expect(result.shouldNotify).toBe(initiated);
      expect(result.subject).toBe('Token received');
    },
  );

  it('sums incoming legs without counting outgoing value toward the threshold', async () => {
    for (const [effects, expected] of [
      [[receipt('300000'), receipt('300000')], true],
      [[receipt('250000'), receipt('250000')], false],
      [[receipt('100000'), receipt('10000000', 'outgoing')], false],
    ] as const) {
      const result = await notificationSummary({
        db: createTestDb(),
        event: event({ transactionValue: '0', effects: [...effects] }),
        eventKind: 'tokenReceived',
        now: 1_000,
        fetchImpl: prices({
          [`ethereum:${tokenAddress}`]: { symbol: 'USDC', decimals: 6, price: 1 },
        }),
      });
      expect(result.shouldNotify).toBe(expected);
    }
  });

  it('keeps an initiated dust receipt and includes its known token and value', async () => {
    const result = await notificationSummary({
      db: createTestDb(),
      event: event({
        transactionValue: '0',
        initiatedByTrackedAddress: true,
        effects: [receipt('100000')],
      }),
      eventKind: 'tokenSent',
      now: 1_000,
      fetchImpl: prices({
        [`ethereum:${tokenAddress}`]: { symbol: 'USDC', decimals: 6, price: 1 },
      }),
    });
    expect(result).toEqual({ subject: 'Received $0.10 of USDC', shouldNotify: true });
  });
});
