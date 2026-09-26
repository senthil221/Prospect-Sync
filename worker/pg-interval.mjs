// A timeout that is about to be written into SQL, checked rather than trusted.
//
// The unit is not optional, and that is the whole point: PostgreSQL reads a
// bare `120` as 120 MILLISECONDS. A compose file that says
// IMPORT_BATCH_TIMEOUT=120 meaning "two minutes" would cancel every batch
// instantly, and it would present as a database fault rather than as the typo
// it is. Refusing at startup turns a confusing outage into a clear message.
//
// It also keeps the value safe to interpolate: these are set with
// `set statement_timeout = '<value>'`, which no parameter placeholder can fill.
export function pgInterval(value, fallback, name) {
  if (value === undefined || value === "") return fallback;
  if (typeof value !== "string" || !/^[0-9]+(ms|s|min|h)$/.test(value.trim())) {
    throw new Error(`${name} must be a number with a unit, like '120s' or '5min'; got '${value}'.`);
  }
  return value.trim();
}

export function pgIntervalMilliseconds(value) {
  const match = /^(\d+)(ms|s|min|h)$/.exec(value);
  if (!match) throw new Error(`Invalid PostgreSQL interval '${value}'.`);
  const multiplier = { ms: 1, s: 1000, min: 60_000, h: 3_600_000 }[match[2]];
  const milliseconds = Number(match[1]) * multiplier;
  if (!Number.isSafeInteger(milliseconds)) throw new Error(`PostgreSQL interval '${value}' is too large.`);
  return milliseconds;
}
