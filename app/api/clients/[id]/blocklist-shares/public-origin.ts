export function blocklistShareOrigin(configuredUrl: string | undefined, requestUrl: string, production: boolean) {
  if (configuredUrl) {
    try {
      const url = new URL(configuredUrl);
      if ((url.protocol === "https:" || (!production && url.protocol === "http:")) && !url.username && !url.password && url.hostname && url.pathname === "/" && !url.search && !url.hash) return url.origin;
    } catch { /* Invalid deployment URL is reported below. */ }
    throw new Error("APP_PUBLIC_URL must be a valid public origin.");
  }
  if (!production) return new URL(requestUrl).origin;
  throw new Error("APP_PUBLIC_URL must be configured to create client links.");
}
