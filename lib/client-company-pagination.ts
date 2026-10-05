export const clientCompanyRpcPageLimit = 100;

export function clientCompanyPageRequest(pageSize: number) {
  const canLookAhead = pageSize < clientCompanyRpcPageLimit;
  return {
    canLookAhead,
    rpcLimit: pageSize + (canLookAhead ? 1 : 0),
  };
}

export function clientCompanyHasMore(
  rowCount: number,
  pageSize: number,
  canLookAhead: boolean,
): boolean | undefined {
  return canLookAhead ? rowCount > pageSize : undefined;
}

export function canAdvanceClientCompanyPage({
  hasMore,
  totalCapped,
  rowCount,
  pageSize,
  page,
  total,
}: {
  hasMore?: boolean;
  totalCapped: boolean;
  rowCount: number;
  pageSize: number;
  page: number;
  total: number;
}) {
  if (hasMore !== undefined) return hasMore;
  if (totalCapped) return rowCount === pageSize;
  return page < Math.max(1, Math.ceil(total / pageSize));
}
