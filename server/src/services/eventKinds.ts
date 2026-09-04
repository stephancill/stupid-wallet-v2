import type { WebhookEvent } from '../schemas';

export const EVENT_KINDS = [
  'nativeReceived',
  'nativeSent',
  'tokenReceived',
  'tokenSent',
  'nftReceived',
  'nftSent',
  'transactionSent',
  'transactionFailed',
  'activityReverted',
  'activityDetected',
] as const;

export type EventKind = (typeof EVENT_KINDS)[number];

export const isEventKind = (value: string): value is EventKind =>
  (EVENT_KINDS as readonly string[]).includes(value);

const EVENT_TITLES: Record<EventKind, string> = {
  nativeReceived: 'Received funds',
  nativeSent: 'Sent funds',
  tokenReceived: 'Token received',
  tokenSent: 'Token sent',
  nftReceived: 'NFT received',
  nftSent: 'NFT sent',
  transactionSent: 'Transaction sent',
  transactionFailed: 'Transaction failed',
  activityReverted: 'Activity reverted',
  activityDetected: 'Wallet activity',
};

/** Privacy-safe categorical fallback used if iOS cannot run the service extension. */
export const eventTitle = (value: string): string =>
  isEventKind(value) ? EVENT_TITLES[value] : EVENT_TITLES.activityDetected;

/**
 * Bounded, guess-free classification. Reorg and failed-execution states take
 * precedence. When direction or asset type is ambiguous we return the generic kind.
 */
export const classifyEvent = (event: WebhookEvent): EventKind => {
  if (event.eventType === 'activity.reverted') return 'activityReverted';
  if (event.transactionStatus === 'reverted') return 'transactionFailed';

  const directed = event.initiatedByTrackedAddress === true;
  const hasNativeValue = hasPositiveValue(event.transactionValue);

  if (hasNativeValue) {
    return directed ? 'nativeSent' : 'nativeReceived';
  }

  if (detectKind(event, 'erc721')) {
    return directed ? 'nftSent' : 'nftReceived';
  }
  if (detectKind(event, 'erc20')) {
    return directed ? 'tokenSent' : 'tokenReceived';
  }
  return directed ? 'transactionSent' : 'activityDetected';
};

const hasPositiveValue = (value: string | undefined): boolean => {
  if (typeof value !== 'string' || !/^[0-9]+$/.test(value)) return false;
  return BigInt(value) > 0n;
};

const detectKind = (event: WebhookEvent, kind: 'erc20' | 'erc721'): boolean =>
  (event.effects ?? []).some((effect) => effect.kind === kind);
