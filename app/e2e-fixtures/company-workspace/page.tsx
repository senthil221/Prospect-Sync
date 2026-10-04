import { notFound } from "next/navigation";
import CompanyWorkspaceFixture from "./CompanyWorkspaceFixture";

export default function Page() {
  if (process.env.E2E_FIXTURES_ENABLED !== "1") notFound();
  return <CompanyWorkspaceFixture/>;
}
