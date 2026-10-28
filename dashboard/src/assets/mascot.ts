/**
 * Shared brand mark (served from ``dashboard/public``).
 * Prefer ``OctopEmptyMascot`` / ``EmptyState variant="mascot"`` over hardcoding.
 * Dark theme inverts it via ``theme-vars.css``.
 */
export const BRAND_MARK_SRC = `${import.meta.env.BASE_URL}brand-mark.png`;
export const OCTOP_EMPTY_MASCOT_SRC = BRAND_MARK_SRC;
