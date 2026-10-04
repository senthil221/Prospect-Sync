import { notFound } from "next/navigation";
import MobileNavFixture from "./MobileNavFixture";

export default function Page() {
  // Fixture routes are not an alternate authentication path. They do not exist
  // unless a local test process opts in before Next starts.
  if (process.env.E2E_FIXTURES_ENABLED !== "1") notFound();
  return <MobileNavFixture/>;
}
