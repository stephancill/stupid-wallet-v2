import { z } from 'zod';

/** Canonical EVM address: 0x + 40 lowercase or uppercase hex. */
export const evmAddress = z.string().regex(/^0x[0-9a-fA-F]{40}$/, 'invalid EVM address');

export const decimalChainId = z.string().regex(/^[1-9][0-9]{0,18}$/, 'invalid decimal chain id');

export const apnsEnvironment = z.enum(['development', 'production']);

export const notificationAuthorization = z.enum([
  'authorized',
  'denied',
  'notDetermined',
  'provisional',
  'ephemeral',
]);

export const notificationAlertSetting = z.enum(['enabled', 'disabled', 'unsupported']);

const challengeCreateBodySchema = z.object({
  publicKey: z.string().min(44).max(180),
  packageName: z.string().min(1).max(128),
});
export type ChallengeCreateBody = z.infer<typeof challengeCreateBodySchema>;

const installationCreateBodySchema = z.object({
  challengeId: z.string().min(8).max(64),
  publicKey: z.string().min(44).max(180),
  popupLivenessPublicKey: z.string().min(44).max(180).optional(),
  apnsEnvironment: apnsEnvironment.optional(),
  apnsToken: z.string().min(16).max(512).optional(),
  appVersion: z.string().max(64).optional(),
  appBuild: z.string().max(64).optional(),
  notificationAuthorization: notificationAuthorization.optional(),
  notificationAlertSetting: notificationAlertSetting.optional(),
});
export type InstallationCreateBody = z.infer<typeof installationCreateBodySchema>;

const pushTokenBodySchema = z.object({
  environment: apnsEnvironment.refine(
    (value) => value === 'production' || value === 'development',
    {
      message: 'unsupported APNs environment',
    },
  ),
  token: z.string().min(16).max(512),
});
export type PushTokenBody = z.infer<typeof pushTokenBodySchema>;

const notificationStatusBodySchema = z.object({
  authorization: notificationAuthorization,
  alertSetting: notificationAlertSetting,
  observeUnixMilliseconds: z.number().int().min(0),
});
export type NotificationStatusBody = z.infer<typeof notificationStatusBodySchema>;

const chainsBodySchema = z.object({
  revision: z.number().int().min(0),
  chainIds: z.array(decimalChainId).max(25),
});
export type ChainsBody = z.infer<typeof chainsBodySchema>;

const addressesBodySchema = z.object({
  addresses: z.array(evmAddress).min(1).max(25),
});
export type AddressesBody = z.infer<typeof addressesBodySchema>;

/** Exact upstream webhook payload (Stupid Wallet Webhooks shape). */
export const webhookEventSchema = z.object({
  eventId: z.string().min(1).max(128),
  eventType: z.enum(['activity.observed', 'activity.reverted']),
  chainId: decimalChainId,
  address: evmAddress,
  blockNumber: z.string().optional(),
  blockHash: z
    .string()
    .regex(/^0x[0-9a-fA-F]{64}$/)
    .optional(),
  blockTimestamp: z.number().int().optional(),
  transactionHash: z
    .string()
    .regex(/^0x[0-9a-fA-F]{64}$/)
    .optional(),
  transactionFrom: evmAddress.optional(),
  transactionTo: evmAddress.nullable().optional(),
  transactionStatus: z.enum(['success', 'reverted']).optional(),
  transactionNonce: z
    .string()
    .regex(/^[0-9]+$/)
    .optional(),
  transactionValue: z
    .string()
    .regex(/^[0-9]+$/)
    .optional(),
  initiatedByTrackedAddress: z.boolean().optional(),
  effects: z.array(z.record(z.string(), z.unknown())).optional(),
  observationId: z.string().min(1).max(160),
});
export type WebhookEvent = z.infer<typeof webhookEventSchema>;

const upstreamTransactionSchema = z
  .object({
    hash: z.string().regex(/^0x[0-9a-fA-F]{64}$/),
    index: z.number().int().min(0),
    from: evmAddress,
    to: evmAddress.nullable(),
    status: z.enum(['success', 'reverted']),
    nonce: z.string().regex(/^[0-9]+$/),
    value: z.string().regex(/^[0-9]+$/),
  })
  .passthrough();

const upstreamBaseActivityDataSchema = z
  .object({
    chainId: z.number().int().positive(),
    trackedAddress: evmAddress,
    blockNumber: z.string().regex(/^[0-9]+$/),
    blockHash: z.string().regex(/^0x[0-9a-fA-F]{64}$/),
  })
  .passthrough();

/** Exact outer delivery envelope emitted by Stupid Webhooks. */
export const upstreamWebhookEnvelopeSchema = z.discriminatedUnion('type', [
  z.object({
    id: z.string().min(1).max(160),
    type: z.literal('activity.observed'),
    createdAt: z.string().datetime(),
    data: upstreamBaseActivityDataSchema.extend({
      initiatedByTrackedAddress: z.boolean(),
      blockTimestamp: z.string().regex(/^[0-9]+$/),
      transaction: upstreamTransactionSchema,
      effects: z.array(z.record(z.string(), z.unknown())),
    }),
  }),
  z.object({
    id: z.string().min(1).max(160),
    type: z.literal('activity.reverted'),
    createdAt: z.string().datetime(),
    data: upstreamBaseActivityDataSchema,
  }),
  z.object({
    id: z.string().min(1).max(160),
    type: z.literal('webhook.test'),
    createdAt: z.string().datetime(),
    data: z.object({ webhookId: z.string().min(1).max(64) }),
  }),
]);
export type UpstreamWebhookEnvelope = z.infer<typeof upstreamWebhookEnvelopeSchema>;

const renewBodySchema = z.object({
  addresses: z.array(evmAddress).max(25),
  chains: chainsBodySchema,
});
export type RenewBody = z.infer<typeof renewBodySchema>;

export const schemas = {
  challengeCreate: challengeCreateBodySchema,
  installationCreate: installationCreateBodySchema,
  pushToken: pushTokenBodySchema,
  notificationStatus: notificationStatusBodySchema,
  chains: chainsBodySchema,
  addresses: addressesBodySchema,
  renew: renewBodySchema,
  webhookEvent: webhookEventSchema,
  upstreamWebhookEnvelope: upstreamWebhookEnvelopeSchema,
};
