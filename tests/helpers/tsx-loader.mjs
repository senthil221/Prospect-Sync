// Test-only loader for rendering the real TSX components without a running
// database or an authentication bypass. Never imported by the application.
import { register } from "node:module";

// Async loader registration also works on the project's minimum Node 22.13.
register("./tsx-hooks.mjs", import.meta.url);
