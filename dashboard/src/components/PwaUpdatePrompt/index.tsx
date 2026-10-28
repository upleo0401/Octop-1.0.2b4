import { useEffect } from "react";
import { applyUpdate } from "../../pwa";

/**
 * Listens for the "pwa:update-ready" event (dispatched by sw-register.ts) and
 * silently activates the waiting Service Worker, reloading once so the page
 * picks up the new frontend bundle. No banner is shown.
 * Designed to be mounted once in MainLayout.
 */
export default function PwaUpdatePrompt() {
  useEffect(() => {
    const handler = () => {
      void applyUpdate();
    };
    window.addEventListener("pwa:update-ready", handler);
    return () => window.removeEventListener("pwa:update-ready", handler);
  }, []);

  return null;
}
