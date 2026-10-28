import { beforeEach, describe, expect, it } from "vitest";

import { readLastUsername, writeLastUsername } from "./rememberedUsername";

describe("remembered username", () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it("round-trips a username when remember is on", () => {
    writeLastUsername(" alice ", true);
    expect(readLastUsername()).toBe("alice");
  });

  it("clears the saved username when remember is off", () => {
    writeLastUsername("alice", true);
    writeLastUsername("alice", false);
    expect(readLastUsername()).toBe("");
  });
});
