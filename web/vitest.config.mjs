// Separate from the existing Node test runner; the pinned Vitest runner is optional tooling.
export default {
  test: { include: ["tests/*.test.mjs"], environment: "node" },
};
