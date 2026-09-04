import { z } from 'zod';
import type { Database } from '../database';
import { evmAddress, type WebhookEvent } from '../schemas';
import { eventTitle } from './eventKinds';
import { getTokenInfo, type PriceFetcher, type TokenInfo } from './tokenInfo';

interface SubjectLeg {
  direction: 'incoming' | 'outgoing';
  symbol: string;
  humanAmount: string;
  usdValue: number;
}

const MAX_EFFECTS = 25;
export const MAX_NOTIFICATION_SUBJECT_LENGTH = 120;

const fungibleEffectSchema = z
  .object({
    kind: z.enum(['native', 'erc20']),
    direction: z.enum(['incoming', 'outgoing']),
    amount: z.string().regex(/^[0-9]+$/),
    assetAddress: evmAddress.optional(),
  })
  .passthrough();

export async function notificationSubject(params: {
  db: Database;
  event: WebhookEvent;
  eventKind: string;
  now: number;
  fetchImpl: PriceFetcher;
}): Promise<string> {
  const { db, event, eventKind, now, fetchImpl } = params;
  if (eventKind === 'activityReverted' || eventKind === 'transactionFailed') {
    return eventTitle(eventKind);
  }

  const legs: SubjectLeg[] = [];
  let hasNativeEffect = false;

  for (const effect of (event.effects ?? []).slice(0, MAX_EFFECTS)) {
    const parsed = fungibleEffectSchema.safeParse(effect);
    if (!parsed.success) continue;
    const { kind, direction, amount } = parsed.data;

    const address = parsed.data.assetAddress?.toLowerCase() ?? null;
    if (kind === 'erc20' && !address) continue;
    if (kind === 'native') hasNativeEffect = true;

    const token = await getTokenInfo({
      db,
      chainId: event.chainId,
      address,
      native: kind === 'native',
      now,
      fetchImpl,
    });
    const leg = resolveLeg({ direction, amount, token });
    if (leg) legs.push(leg);
  }

  if (!hasNativeEffect && hasPositiveInteger(event.transactionValue)) {
    const token = await getTokenInfo({
      db,
      chainId: event.chainId,
      address: null,
      native: true,
      now,
      fetchImpl,
    });
    const direction = event.initiatedByTrackedAddress === true ? 'outgoing' : 'incoming';
    const leg = resolveLeg({ direction, amount: event.transactionValue!, token });
    if (leg) legs.push(leg);
  }

  const incoming = legs.filter((leg) => leg.direction === 'incoming');
  const outgoing = legs.filter((leg) => leg.direction === 'outgoing');
  if (incoming.length > 0 && outgoing.length > 0) {
    const sent = highestValue(outgoing)!;
    const received = highestValue(incoming)!;
    return boundSubject(
      `Swapped ${sent.humanAmount} ${sent.symbol} for ${received.humanAmount} ${received.symbol}`,
    );
  }

  const primary = highestValue(legs);
  if (!primary) return eventTitle(eventKind);
  const verb = primary.direction === 'incoming' ? 'Received' : 'Sent';
  return boundSubject(`${verb} ${formatSubjectDollars(primary.usdValue)} of ${primary.symbol}`);
}

const resolveLeg = (params: {
  direction: 'incoming' | 'outgoing';
  amount: string;
  token: TokenInfo | null;
}): SubjectLeg | null => {
  const { direction, amount, token } = params;
  if (!token || !hasPositiveInteger(amount)) return null;
  const symbol = safeSymbol(token.symbol);
  if (!symbol) return null;
  const humanValue = Number(amount) / 10 ** token.decimals;
  const usdValue = humanValue * token.priceUsd;
  if (!Number.isFinite(humanValue) || !Number.isFinite(usdValue) || usdValue <= 0) return null;
  return {
    direction,
    symbol,
    humanAmount: humanValue.toLocaleString('en-US', { maximumFractionDigits: 6 }),
    usdValue,
  };
};

const highestValue = (legs: SubjectLeg[]): SubjectLeg | undefined =>
  [...legs].sort((left, right) => right.usdValue - left.usdValue)[0];

const hasPositiveInteger = (value: string | undefined): value is string =>
  typeof value === 'string' && /^[0-9]+$/.test(value) && BigInt(value) > 0n;

const safeSymbol = (value: string): string | null => {
  const symbol = value.trim();
  return /^[A-Za-z0-9._-]{1,16}$/.test(symbol) ? symbol : null;
};

const formatSubjectDollars = (value: number): string =>
  value.toLocaleString('en-US', {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: value >= 1 ? 0 : 2,
    maximumFractionDigits: value >= 1 ? 0 : 2,
  });

const boundSubject = (value: string): string => {
  const normalized = value.replace(/\s+/g, ' ').trim();
  if (normalized.length <= MAX_NOTIFICATION_SUBJECT_LENGTH) return normalized;
  return `${normalized.slice(0, MAX_NOTIFICATION_SUBJECT_LENGTH - 1)}…`;
};
