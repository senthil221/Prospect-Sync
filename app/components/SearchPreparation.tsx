import type { PreparationProgress } from '../../lib/prepared-search';

export default function SearchPreparation({ progress, error, onRetry, onClear, clearLabel }: {
  progress: PreparationProgress | null; error: string; onRetry: () => void; onClear: () => void; clearLabel: string;
}) {
  if (!progress && !error) return null;
  return <div className="panel" role={error ? 'alert' : 'status'} style={{ padding: 'var(--space-6)' }}>
    <h3>{error ? 'Company search could not finish' : 'Preparing your company search'}</h3>
    <p>{error || progress?.message}</p>
    {error ? <button className="primary" onClick={onRetry}>Retry search</button> : null}
    <button className="secondary" onClick={onClear}>{clearLabel}</button>
  </div>;
}
