import { Suspense } from "react";
import { notFound } from "next/navigation";
import DashboardApp from "../../DashboardApp";

export default function Page() {
  if (process.env.E2E_FIXTURES_ENABLED !== "1") notFound();
  return <Suspense fallback={<div role="status">Restoring fixture…</div>}>
    <DashboardApp currentUserEmail="fixture@example.test" isAdmin={false}/>
  </Suspense>;
}
