import { useTranslation } from "react-i18next";
import { useNavigate } from "react-router-dom";
import { Tooltip } from "antd";
import { ArrowUpCircle } from "lucide-react";
import { useUpdateStatus } from "../../hooks/useUpdateStatus";
import { useCurrentUser } from "../../hooks/useCurrentUser";
import { userCan } from "../../utils/permissions";
import styles from "./index.module.less";

interface AppVersionBadgeProps {
  isMobile?: boolean;
  interactive?: boolean;
}

export default function AppVersionBadge({
  isMobile,
  interactive = true,
}: AppVersionBadgeProps) {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const user = useCurrentUser();
  const { status, hasUpdate } = useUpdateStatus();

  const canUpdate = userCan(user, "update");
  if (!status?.current_version || !hasUpdate || !canUpdate) return null;

  const tooltip = t("header.versionUpdateAvailable", {
    current: status.current_version,
    latest: status.latest_version,
    defaultValue: `当前 v${status.current_version}，新版本 v${status.latest_version} 可用，点击前往更新`,
  });

  const className = `${styles.headerVersion} ${
    isMobile ? styles.headerVersionMobile : ""
  } ${interactive ? styles.headerVersionClickable : ""}`;

  return (
    <Tooltip title={tooltip} mouseEnterDelay={0.35}>
      {interactive ? (
        <button
          type="button"
          className={className}
          onClick={() => navigate("/admin/advanced?tab=updates")}
          aria-label={tooltip}
        >
          <ArrowUpCircle size={isMobile ? 14 : 15} strokeWidth={2} />
        </button>
      ) : (
        <span className={className} aria-label={tooltip}>
          <ArrowUpCircle size={isMobile ? 14 : 15} strokeWidth={2} />
        </span>
      )}
    </Tooltip>
  );
}
