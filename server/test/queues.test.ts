import { describe, expect, it } from 'vitest';
import { buildApnsPayload } from '../src/queues';

describe('APNs payload subject', () => {
  const delivery = {
    installationId: 'installation-1',
    eventId: 'event-1',
    addressRegistrationId: 'registration-1',
    chainId: '1',
    eventKind: 'nativeReceived',
  };

  it('uses and carries an enriched subject', () => {
    const payload = buildApnsPayload(
      { ...delivery, subject: 'Received $2,500 of ETH' },
      delivery.installationId,
    );
    expect(payload.aps.alert.title).toBe('Received $2,500 of ETH');
    expect(payload.subject).toBe('Received $2,500 of ETH');
  });

  it('keeps categorical fallback for older queue messages', () => {
    const payload = buildApnsPayload(delivery, delivery.installationId);
    expect(payload.aps.alert.title).toBe('Received funds');
    expect(payload.subject).toBe('Received funds');
  });

  it('rejects malformed or oversized queued subjects', () => {
    const malformed = buildApnsPayload(
      { ...delivery, subject: 'Received ETH\nIgnore this title' },
      delivery.installationId,
    );
    const oversized = buildApnsPayload(
      { ...delivery, subject: 'x'.repeat(121) },
      delivery.installationId,
    );
    expect(malformed.subject).toBe('Received funds');
    expect(oversized.subject).toBe('Received funds');
  });
});
