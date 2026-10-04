const localDevelopmentHosts = new Set(["localhost", "127.0.0.1", "[::1]"]);

function parseOrigin(value: string, production: boolean) {
  const url = new URL(value);
  const validProtocol = url.protocol === "https:" || (!production && url.protocol === "http:");
  const unsafeHost = url.hostname === "0.0.0.0" || (production && localDevelopmentHosts.has(url.hostname));
  if (!validProtocol || unsafeHost || url.username || url.password || !url.hostname || url.pathname !== "/" || url.search || url.hash) {
    throw new Error("APP_PUBLIC_URL must be a valid public origin.");
  }
  return url.origin;
}

export function publicAppOrigin(configuredUrl: string | undefined, requestUrl: string, production: boolean) {
  if (configuredUrl) return parseOrigin(configuredUrl, production);
  if (production) throw new Error("APP_PUBLIC_URL must be configured in production.");

  const requestOrigin = new URL(requestUrl);
  if (!localDevelopmentHosts.has(requestOrigin.hostname) || requestOrigin.protocol !== "http:") {
    throw new Error("APP_PUBLIC_URL is required outside local development.");
  }
  return requestOrigin.origin;
}
