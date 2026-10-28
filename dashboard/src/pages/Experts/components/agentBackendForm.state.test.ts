import { describe, expect, it } from "vitest";
import {
  BUILTIN_BACKENDS,
  DEFAULT_BACKEND,
  parseBackendSpec,
} from "./agentBackendForm";

describe("expert backend choices", () => {
  it("offers only PC-disk backends", () => {
    expect(BUILTIN_BACKENDS).toEqual(["local_shell", "filesystem"]);
    expect(DEFAULT_BACKEND).toBe("local_shell");
    expect(BUILTIN_BACKENDS).not.toContain("state");
    expect(BUILTIN_BACKENDS).not.toContain("desktop_worker");
  });

  it("maps the old desktop Worker type to files-only", () => {
    expect(parseBackendSpec({ type: "desktop_worker" }).backendChoice).toBe(
      "filesystem",
    );
  });

  it("keeps an already saved state backend visible in the editor", () => {
    expect(parseBackendSpec({ type: "state" }).backendChoice).toBe("state");
  });

  it("does not keep composite or docker as picker values", () => {
    expect(
      parseBackendSpec({
        type: "composite",
        default: { type: "filesystem", virtual_mode: true, root_dir: "/" },
      }).backendChoice,
    ).toBe("local_shell");
    expect(parseBackendSpec({ type: "docker" }).backendChoice).toBe(
      "local_shell",
    );
  });
});
