import { createEnv } from "@t3-oss/env-nextjs";
import { z } from "zod";

export const env = createEnv({
  server: {},
  runtimeEnv: {},
  skipValidation:
    process.env.SKIP_ENV_VALIDATION === "1" ||
    process.env.VERCEL_ENV === "preview",
});
