import { useTranslation } from "react-i18next";
import { Tooltip } from "antd";
import { useUpdateStatus } from "../../hooks/useUpdateStatus";
import styles from "./index.module.less";

interface CurrentVersionBadgeProps {
  isMobile?: boolean;
  /** When false, always render a non-button (e.g. inside another clickable row). */
  interactive?: boolean;
}

export default function CurrentVersionBadge({
  isMobile,
}: CurrentVersionBadgeProps) {
  const { t } = useTranslation();
  const { status } = useUpdateStatus();

  const version = status?.current_version;
  if (!version) return null;

  const tooltip = t("header.currentVersion", { version });
  const label = `v${version}`;

  return (
    <Tooltip title={tooltip} mouseEnterDelay={0.35}>
      <span
        className={`${styles.versionBadge} ${
          isMobile ? styles.versionBadgeMobile : ""
        }`}
        aria-label={tooltip}
      >
        {label}
      </span>
    </Tooltip>
  );
}
