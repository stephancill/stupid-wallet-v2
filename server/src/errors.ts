/** Typed HTTP error carrying a stable public error code and HTTP status. */
export class HttpError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export const badRequest = (message: string) => new HttpError(400, 'bad_request', message);
export const unauthorized = (message: string) => new HttpError(401, 'unauthorized', message);
export const notFound = (message: string) => new HttpError(404, 'not_found', message);
export const forbidden = (message: string) => new HttpError(403, 'forbidden', message);
export const conflict = (message: string) => new HttpError(409, 'conflict', message);
export const rateLimited = (message: string) => new HttpError(429, 'rate_limited', message);
export const gone = (message: string) => new HttpError(410, 'gone', message);
