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

/**
 * Bounded, guess-free classification. Reorg and failed-execution states take
 * precedence. When direction or asset type is ambiguous we return the generic kind.
 */
export const classifyEvent = (event: WebhookEvent): EventKind => {
  if (event.eventType === 'activity.reverted') return 'activityReverted';
  if (event.transactionStatus === 'reverted') return 'transactionFailed';

  const directed = event.initiatedByTrackedAddress === true;
  const hasNativeValue = boolValueHasPresence(event.transactionValue);

  if (hasNativeValue) {
    return directed ? 'nativeSent' : 'nativeReceived';
  }

  if (detectKind(event, 'nft')) {
    return directed ? 'nftSent' : 'nftReceived';
  }
  if (detectKind(event, 'token')) {
    return directed ? 'tokenSent' : 'tokenReceived';
  }
  return directed ? 'transactionSent' : 'activityDetected';
};

const boolValueHasPresence = (value: string | undefined): boolean =>
  typeof value === 'string' && /^[0-9]+$/.test(value);

const detectKind = (event: WebhookEvent, asset: 'nft' | 'token'): boolean => {
  const effects = JSON.stringify(event.effects ?? {});
  const term = asset === 'nft' ? 'nft' : 'token';
  return effects.toLowerCase().includes(term);
};
