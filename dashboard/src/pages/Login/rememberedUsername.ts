const LAST_USERNAME_KEY = "octop:last_username";

export function readLastUsername(): string {
  try {
    return localStorage.getItem(LAST_USERNAME_KEY) ?? "";
  } catch {
    return "";
  }
}

export function writeLastUsername(name: string, remember: boolean): void {
  try {
    const trimmed = name.trim();
    if (remember && trimmed) {
      localStorage.setItem(LAST_USERNAME_KEY, trimmed);
    } else {
      localStorage.removeItem(LAST_USERNAME_KEY);
    }
  } catch {
    /* private mode / quota */
  }
}
